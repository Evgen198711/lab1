defmodule DistributedPrint.Server do
  @moduledoc """
  Token-passing print server with retries for *temporary* message loss.

  Guarantees under no crashes, unique global job IDs, and eventual delivery
  of retransmitted messages:
    * a server dispatches only while holding the unique token;
    * token handoff uses an immutable transfer ID, receiver-side deduplication,
      and acknowledgement; losing an acknowledgement never recreates a token;
    * token requests and print deliveries are retried;
    * print completion serves as an end-to-end acknowledgement of delivery.

  This is not crash recovery: actor restarts, permanent partitions and durable
  physical exactly-once printing require a different protocol.

  To simulate loss deterministically, pass e.g. drop_first: %{token: 1}.
  Supported outgoing message kinds: :token_request, :token, :token_ack,
  :print. Counts apply to *outgoing* sends by this server actor.
  """
  use GenServer

  @default_retry_ms 60

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name_opts(opts))

  # Remote :rpc.call/4 workers are short-lived: do NOT link their children.
  def start(opts), do: GenServer.start(__MODULE__, opts, name_opts(opts))

  defp name_opts(opts), do: Keyword.take(opts, [:name])

  @doc "Submit %{id: globally_unique_id, printer: printer_id, payload: content}."
  def submit(server, job), do: GenServer.call(server, {:submit, job})
  def status(server), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    retry_ms = Keyword.get(opts, :retry_ms, @default_retry_ms)
    Process.send_after(self(), :retry, retry_ms)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       peer: Keyword.fetch!(opts, :peer),
       printers: Keyword.fetch!(opts, :printers),
       has_token: Keyword.get(opts, :initial_token, false),
       requested_token: false,
       peer_waiting: false,
       queue: :queue.new(),
       seen: MapSet.new(),
       dispatched: MapSet.new(),
       completed: MapSet.new(),
       # Jobs not yet confirmed *printed*: resend until completion arrives.
       in_flight: %{},
       # A handoff awaiting ACK: token is no longer locally usable.
       outgoing_transfer: nil,
       next_transfer_number: 1,
       received_transfers: MapSet.new(),
       retry_ms: retry_ms,
       drop_remaining: Keyword.get(opts, :drop_first, %{}),
       dropped: %{}
     }}
  end

  @impl true
  def handle_call({:submit, %{id: id, printer: printer} = job}, _from, state) do
    cond do
      not Map.has_key?(state.printers, printer) ->
        {:reply, {:error, :unknown_printer}, state}

      MapSet.member?(state.seen, id) ->
        {:reply, {:error, :duplicate_job_id}, state}

      true ->
        next = %{
          state
          | queue: :queue.in(job, state.queue),
            seen: MapSet.put(state.seen, id)
        }

        send(self(), :drive)
        {:reply, {:queued, id}, next}
    end
  end

  def handle_call({:submit, _invalid}, _from, state),
    do: {:reply, {:error, :invalid_job}, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       server: state.id,
       has_token: state.has_token,
       waiting_for_token: state.requested_token,
       pending: :queue.to_list(state.queue) |> Enum.map(& &1.id),
       dispatched: state.dispatched,
       completed: state.completed,
       awaiting_completion: Map.keys(state.in_flight),
       outgoing_transfer: state.outgoing_transfer,
       dropped: state.dropped
     }, state}
  end

  @impl true
  def handle_cast({:token_request, _sender}, state) do
    # Duplicate requests are harmless. Serve at most one queued local job
    # before passing the token, so a busy peer gets a turn.
    send(self(), :drive)
    {:noreply, %{state | peer_waiting: true}}
  end

  def handle_cast({:token, sender, transfer_id}, state) do
    if MapSet.member?(state.received_transfers, transfer_id) do
      # A retransmission is NOT a new token. ACK it again without changing
      # token ownership, even if we have already passed the token onward.
      {:noreply, emit(state, :token_ack, sender, {:token_ack, self(), transfer_id})}
    else
      # A legitimate new transfer, including a return to a server whose
      # previous outgoing ACK was lost. A return proves that handoff occurred.
      next = %{
        state
        | has_token: true,
          requested_token: false,
          outgoing_transfer: nil,
          received_transfers: MapSet.put(state.received_transfers, transfer_id)
      }

      next = emit(next, :token_ack, sender, {:token_ack, self(), transfer_id})
      send(self(), :drive)
      {:noreply, next}
    end
  end

  def handle_cast({:token_ack, _sender, transfer_id}, state) do
    case state.outgoing_transfer do
      %{id: ^transfer_id} ->
        {:noreply, %{state | outgoing_transfer: nil}}

      _ ->
        # Late ACK for an already completed handoff: harmless.
        {:noreply, state}
    end
  end

  def handle_cast({:printed, id, printer_id}, state) do
    case Map.get(state.in_flight, id) do
      %{printer: ^printer_id} ->
        {:noreply,
         %{
           state
           | completed: MapSet.put(state.completed, id),
             in_flight: Map.delete(state.in_flight, id)
         }}

      _ ->
        # Duplicate / unexpected completion cannot create phantom jobs.
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:drive, state), do: {:noreply, drive(state)}

  def handle_info(:retry, state) do
    # Each actor runs its own periodic retry loop. The drop_first injection
    # can drop a finite number of attempts; later attempts get delivered.
    next =
      state
      |> retry_transfer()
      |> retry_token_request()
      |> retry_print_jobs()
      |> drive()

    Process.send_after(self(), :retry, next.retry_ms)
    {:noreply, next}
  end

  defp drive(state) do
    cond do
      state.has_token and not :queue.is_empty(state.queue) ->
        {{:value, job}, rest} = :queue.out(state.queue)
        target = Map.fetch!(state.printers, job.printer)

        next = %{
          state
          | queue: rest,
            dispatched: MapSet.put(state.dispatched, job.id),
            in_flight: Map.put(state.in_flight, job.id, job)
        }

        next = emit(next, :print, target, {:print, job, self()})

        if next.peer_waiting do
          give_token(next)
        else
          # One job per mailbox turn: a peer's token request may interleave.
          send(self(), :drive)
          next
        end

      state.has_token and state.peer_waiting ->
        give_token(state)

      not state.has_token and not :queue.is_empty(state.queue) and
          not state.requested_token ->
        request_token(state)

      true ->
        state
    end
  end

  defp give_token(state) do
    # Sender becomes unable to dispatch *before* sending the grant. If the
    # grant or ACK is dropped, ONLY the same transfer is retransmitted.
    transfer_id = {state.id, state.next_transfer_number}

    next = %{
      state
      | has_token: false,
        peer_waiting: false,
        requested_token: false,
        outgoing_transfer: %{id: transfer_id},
        next_transfer_number: state.next_transfer_number + 1
    }

    next = emit(next, :token, next.peer, {:token, self(), transfer_id})

    if :queue.is_empty(next.queue), do: next, else: request_token(next)
  end

  defp request_token(state) do
    next = emit(state, :token_request, state.peer, {:token_request, self()})
    %{next | requested_token: true}
  end

  defp retry_transfer(%{outgoing_transfer: nil} = state), do: state

  defp retry_transfer(state) do
    emit(state, :token, state.peer, {:token, self(), state.outgoing_transfer.id})
  end

  defp retry_token_request(state) do
    if not state.has_token and not :queue.is_empty(state.queue) do
      request_token(state)
    else
      state
    end
  end

  defp retry_print_jobs(state) do
    Enum.reduce(state.in_flight, state, fn {_id, job}, acc ->
      emit(acc, :print, Map.fetch!(acc.printers, job.printer), {:print, job, self()})
    end)
  end

  defp emit(state, kind, destination, message) do
    remaining = Map.get(state.drop_remaining, kind, 0)

    if remaining > 0 do
      %{
        state
        | drop_remaining: Map.put(state.drop_remaining, kind, remaining - 1),
          dropped: Map.update(state.dropped, kind, 1, &(&1 + 1))
      }
    else
      GenServer.cast(destination, message)
      state
    end
  end
end
