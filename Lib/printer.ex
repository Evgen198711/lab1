defmodule DistributedPrint.Printer do
  @moduledoc """
  Printer with a FIFO job queue and at most one active print.

  A completed job ID is remembered: retrying its PRINT message prompts a new
  completion notification rather than another physical print. The originating
  server retries until it receives completion. For reproducible loss injection,
  use drop_first: %{printed: 1} when starting the printer.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name_opts(opts))
  def start(opts), do: GenServer.start(__MODULE__, opts, name_opts(opts))
  defp name_opts(opts), do: Keyword.take(opts, [:name])

  def status(printer), do: GenServer.call(printer, :status)

  @impl true
  def init(opts) do
    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       delay_ms: Keyword.get(opts, :delay_ms, 30),
       queue: :queue.new(),
       active: nil,
       seen: MapSet.new(),
       print_counts: %{},
       drop_remaining: Keyword.get(opts, :drop_first, %{}),
       dropped: %{}
     }}
  end

  @impl true
  def handle_cast({:print, %{id: id, printer: target} = job, origin}, state) do
    cond do
      target != state.id ->
        {:noreply, state}

      Map.has_key?(state.print_counts, id) ->
        # A repeated delivery means the completion ACK may have been lost.
        # ACK again; the print itself must NOT run a second time.
        {:noreply, notify_completed(state, origin, id)}

      MapSet.member?(state.seen, id) ->
        # Job still queued or printing: its original completion will ACK it.
        {:noreply, state}

      true ->
        updated = %{
          state
          | seen: MapSet.put(state.seen, id),
            queue: :queue.in({job, origin}, state.queue)
        }

        {:noreply, start_next_if_idle(updated)}
    end
  end

  @impl true
  def handle_info({:finish, id}, %{active: {%{id: id}, origin}} = state) do
    counts = Map.update(state.print_counts, id, 1, &(&1 + 1))
    next = %{state | active: nil, print_counts: counts}
    {:noreply, next |> notify_completed(origin, id) |> start_next_if_idle()}
  end

  def handle_info({:finish, _stale_id}, state), do: {:noreply, state}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       printer: state.id,
       active: if(state.active, do: elem(state.active, 0).id, else: nil),
       waiting: :queue.to_list(state.queue) |> Enum.map(fn {job, _} -> job.id end),
       print_counts: state.print_counts,
       seen: state.seen,
       dropped: state.dropped
     }, state}
  end

  defp notify_completed(state, origin, id) do
    if Map.get(state.drop_remaining, :printed, 0) > 0 do
      %{
        state
        | drop_remaining: Map.update!(state.drop_remaining, :printed, &(&1 - 1)),
          dropped: Map.update(state.dropped, :printed, 1, &(&1 + 1))
      }
    else
      GenServer.cast(origin, {:printed, id, state.id})
      state
    end
  end

  defp start_next_if_idle(%{active: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {job, origin}}, rest} ->
        Process.send_after(self(), {:finish, job.id}, state.delay_ms)
        %{state | queue: rest, active: {job, origin}}
    end
  end

  defp start_next_if_idle(state), do: state
end
