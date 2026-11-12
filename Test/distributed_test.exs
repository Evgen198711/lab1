defmodule DistributedPrint.DistributedTest do
  use ExUnit.Case, async: false
  @moduletag :distributed
  @moduletag timeout: 30_000

  alias DistributedPrint.{Printer, Server}

  # Each test uses fresh registered names on the same five remote Erlang nodes.
  # That prevents an old queue, token or delayed message from contaminating
  # another test (or a later run of this test suite).
  setup tags do
    assert Node.alive?(),
           "start the test with: elixir --sname test --cookie printlab -S mix test --include distributed test/distributed_test.exs"

    host = Node.self() |> Atom.to_string() |> String.split("@") |> List.last()
    node_name = fn short -> String.to_atom("#{short}@#{host}") end

    s1 = node_name.("s1")
    s2 = node_name.("s2")
    printer_nodes = %{p1: node_name.("p1"), p2: node_name.("p2"), p3: node_name.("p3")}

    Enum.each([s1, s2] ++ Map.values(printer_nodes), fn node ->
      assert Node.connect(node), "could not connect to #{inspect(node)}"
    end)

    # The suffix is unique even across separate `mix test` invocations.
    suffix = "#{System.system_time(:microsecond)}_#{System.unique_integer([:positive])}"
    server_name = String.to_atom("lab1_server_#{suffix}")
    printer_name = String.to_atom("lab1_printer_#{suffix}")

    remote_processes =
      [{s1, server_name}, {s2, server_name}] ++
        Enum.map(printer_nodes, fn {_id, node} -> {node, printer_name} end)

    # Stop only the actors created for this test. The callback also runs if
    # an assertion fails, and the next test always uses different names.
    on_exit(fn ->
      Enum.each(remote_processes, fn {node, name} ->
        case :rpc.call(node, :erlang, :whereis, [name]) do
          pid when is_pid(pid) ->
            _ = :rpc.call(node, GenServer, :stop, [name, :normal, 2_000])
            :ok

          _ ->
            :ok
        end
      end)
    end)

    delay_ms = Map.get(tags, :printer_delay_ms, 20)
    printer_drops = Map.get(tags, :printer_drop, %{})

    Enum.each(printer_nodes, fn {id, node} ->
      assert {:ok, pid} =
               :rpc.call(node, Printer, :start, [
                 [id: id, name: printer_name, delay_ms: delay_ms,
                  drop_first: Map.get(printer_drops, id, %{})]
               ])

      assert is_pid(pid)
    end)

    printer_refs =
      Map.new(printer_nodes, fn {id, node} -> {id, {printer_name, node}} end)

    assert {:ok, _pid} =
             :rpc.call(s1, Server, :start, [
               [
                 id: :s1,
                 name: server_name,
                 peer: {server_name, s2},
                 printers: printer_refs,
                 initial_token: true,
                 retry_ms: 50,
                 drop_first: Map.get(tags, :s1_drop, %{})
               ]
             ])

    assert {:ok, _pid} =
             :rpc.call(s2, Server, :start, [
               [
                 id: :s2,
                 name: server_name,
                 peer: {server_name, s1},
                 printers: printer_refs,
                 initial_token: false,
                 retry_ms: 50,
                 drop_first: Map.get(tags, :s2_drop, %{})
               ]
             ])

    Enum.each(remote_processes, fn {node, name} ->
      assert is_pid(:rpc.call(node, :erlang, :whereis, [name])),
             "remote process #{inspect(name)} did not remain alive on #{inspect(node)}"
    end)

    {:ok, s1: {server_name, s1}, s2: {server_name, s2}, printers: printer_refs}
  end

  test "1: concurrent submissions across two servers complete exactly once", ctx do
    jobs =
      for n <- 1..12 do
        %{id: "distributed-#{n}", printer: Enum.at([:p1, :p2, :p3], rem(n, 3))}
      end

    results =
      jobs
      |> Enum.with_index()
      |> Enum.map(fn {job, index} ->
        Task.async(fn ->
          server = if rem(index, 2) == 0, do: ctx.s1, else: ctx.s2
          Server.submit(server, job)
        end)
      end)
      |> Task.await_many(5_000)

    assert Enum.all?(results, &match?({:queued, _}, &1))

    assert eventually(fn -> total_completed(ctx.printers) == 12 end)

    counts =
      ctx.printers
      |> Map.values()
      |> Enum.flat_map(fn printer -> Map.to_list(Printer.status(printer).print_counts) end)

    assert length(counts) == 12
    assert Enum.all?(counts, fn {_id, count} -> count == 1 end)
    assert MapSet.new(Enum.map(counts, &elem(&1, 0))) == MapSet.new(Enum.map(jobs, & &1.id))
  end

  test "2: token passes from server 1 to server 2 and back", ctx do
    assert Server.status(ctx.s1).has_token
    refute Server.status(ctx.s2).has_token

    first = %{id: "handover-to-s2", printer: :p2}
    assert {:queued, "handover-to-s2"} = Server.submit(ctx.s2, first)

    assert eventually(fn ->
             state = Server.status(ctx.s2)
             state.has_token and MapSet.member?(state.dispatched, first.id)
           end)

    assert eventually(fn -> Printer.status(ctx.printers.p2).print_counts[first.id] == 1 end)
    refute Server.status(ctx.s1).has_token

    second = %{id: "handover-to-s1", printer: :p3}
    assert {:queued, "handover-to-s1"} = Server.submit(ctx.s1, second)

    assert eventually(fn ->
             state = Server.status(ctx.s1)
             state.has_token and MapSet.member?(state.dispatched, second.id)
           end)

    assert eventually(fn -> Printer.status(ctx.printers.p3).print_counts[second.id] == 1 end)
    refute Server.status(ctx.s2).has_token
  end

  @tag printer_delay_ms: 800
  test "3: one printer queues a second job while the first is active", ctx do
    first = %{id: "serial-first", printer: :p1}
    second = %{id: "serial-second", printer: :p1}

    assert {:queued, "serial-first"} = Server.submit(ctx.s1, first)
    assert eventually(fn -> Printer.status(ctx.printers.p1).active == first.id end)

    # Submitting from the other server also exercises token transfer.
    assert {:queued, "serial-second"} = Server.submit(ctx.s2, second)

    assert eventually(
             fn ->
               state = Printer.status(ctx.printers.p1)
               state.active == first.id and state.waiting == [second.id]
             end,
             150,
             10
           )

    assert eventually(
             fn ->
               Printer.status(ctx.printers.p1).print_counts == %{
                 first.id => 1,
                 second.id => 1
               }
             end,
             200,
             20
           )

    final = Printer.status(ctx.printers.p1)
    assert final.active == nil
    assert final.waiting == []
  end

  test "4: server rejects duplicate ID and remote printer ignores redelivery", ctx do
    job = %{id: "duplicate-on-s1", printer: :p3}

    assert {:queued, "duplicate-on-s1"} = Server.submit(ctx.s1, job)
    assert {:error, :duplicate_job_id} = Server.submit(ctx.s1, job)
    assert eventually(fn -> Printer.status(ctx.printers.p3).print_counts[job.id] == 1 end)

    # Simulate a duplicate copy of an already dispatched printer message.
    GenServer.cast(ctx.printers.p3, {:print, job, ctx.s1})

    # The status call comes from the same sender, after the cast. Erlang's
    # per-sender ordering means the printer has processed the redelivery.
    final = Printer.status(ctx.printers.p3)
    assert final.print_counts == %{job.id => 1}
    assert MapSet.member?(final.seen, job.id)
  end


  @tag s2_drop: %{token_request: 1}
  test "5: a lost token request is retransmitted", ctx do
    job = %{id: "lost-token-request", printer: :p1}
    assert Server.submit(ctx.s2, job) == {:queued, job.id}

    assert eventually(fn ->
             Printer.status(ctx.printers.p1).print_counts[job.id] == 1 and
               MapSet.member?(Server.status(ctx.s2).completed, job.id)
           end)

    assert Server.status(ctx.s2).dropped[:token_request] == 1
  end

  @tag s1_drop: %{token: 1}
  test "6: a lost token grant is retried without duplicating the token", ctx do
    job = %{id: "lost-token-grant", printer: :p2}
    assert Server.submit(ctx.s2, job) == {:queued, job.id}

    assert eventually(fn ->
             Printer.status(ctx.printers.p2).print_counts[job.id] == 1 and
               MapSet.member?(Server.status(ctx.s2).completed, job.id)
           end)

    assert Server.status(ctx.s1).dropped[:token] == 1
    refute Server.status(ctx.s1).has_token
    assert Server.status(ctx.s2).has_token
  end

  @tag s2_drop: %{token_ack: 1}
  test "7: a lost token acknowledgement does not create a second token", ctx do
    first = %{id: "lost-ack-forward", printer: :p1}
    second = %{id: "lost-ack-return", printer: :p3}

    assert Server.submit(ctx.s2, first) == {:queued, first.id}
    assert eventually(fn -> MapSet.member?(Server.status(ctx.s2).completed, first.id) end)
    assert Server.status(ctx.s2).dropped[:token_ack] == 1

    # Request the token back while S1 may still be retransmitting the old
    # grant. Its transfer IDs ensure retries are not interpreted as new tokens.
    assert Server.submit(ctx.s1, second) == {:queued, second.id}
    assert eventually(fn -> MapSet.member?(Server.status(ctx.s1).completed, second.id) end)
    assert Printer.status(ctx.printers.p1).print_counts[first.id] == 1
    assert Printer.status(ctx.printers.p3).print_counts[second.id] == 1
    assert Server.status(ctx.s1).has_token
    refute Server.status(ctx.s2).has_token
  end

  @tag s1_drop: %{print: 1}
  test "8: a lost print message is retransmitted", ctx do
    job = %{id: "lost-print", printer: :p3}
    assert Server.submit(ctx.s1, job) == {:queued, job.id}

    assert eventually(fn ->
             Printer.status(ctx.printers.p3).print_counts[job.id] == 1 and
               MapSet.member?(Server.status(ctx.s1).completed, job.id)
           end)

    assert Server.status(ctx.s1).dropped[:print] == 1
  end

  @tag printer_drop: %{p1: %{printed: 1}}
  test "9: a lost completion notification is recovered without reprinting", ctx do
    job = %{id: "lost-printed", printer: :p1}
    assert Server.submit(ctx.s1, job) == {:queued, job.id}

    assert eventually(fn ->
             Printer.status(ctx.printers.p1).print_counts[job.id] == 1 and
               MapSet.member?(Server.status(ctx.s1).completed, job.id)
           end)

    assert Printer.status(ctx.printers.p1).dropped[:printed] == 1
    assert Printer.status(ctx.printers.p1).print_counts == %{job.id => 1}
    assert Server.status(ctx.s1).awaiting_completion == []
  end

  defp total_completed(printers) do
    Enum.reduce(printers, 0, fn {_id, printer}, total ->
      total + map_size(Printer.status(printer).print_counts)
    end)
  end

  defp eventually(predicate, attempts \\ 200, sleep_ms \\ 30)
  defp eventually(_predicate, 0, _sleep_ms), do: false

  defp eventually(predicate, attempts, sleep_ms) do
    if predicate.() do
      true
    else
      Process.sleep(sleep_ms)
      eventually(predicate, attempts - 1, sleep_ms)
    end
  end
end
