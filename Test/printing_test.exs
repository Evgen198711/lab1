defmodule DistributedPrint.PrintingTest do
  use ExUnit.Case, async: false
  alias DistributedPrint.{Printer, Server}

  test "initial token exists at exactly one server" do
    {:ok, printer} = Printer.start_link(id: :p1)
    {:ok, s1} = Server.start_link(id: :s1, peer: :token_s2,
                                   name: :token_s1, printers: %{p1: printer},
                                   initial_token: true)
    {:ok, s2} = Server.start_link(id: :s2, peer: :token_s1,
                                   name: :token_s2, printers: %{p1: printer},
                                   initial_token: false)
    assert Server.status(s1).has_token
    refute Server.status(s2).has_token
  end

  test "concurrent submissions across servers complete exactly once" do
    printers = for id <- [:p1, :p2, :p3], into: %{} do
      {:ok, pid} = Printer.start_link(id: id, delay_ms: 1)
      {id, pid}
    end

    {:ok, _s1} = Server.start_link(id: :s1, name: :unit_s1,
                                    peer: :unit_s2, printers: printers,
                                    initial_token: true)
    {:ok, _s2} = Server.start_link(id: :s2, name: :unit_s2,
                                    peer: :unit_s1, printers: printers)

    jobs = for n <- 1..18 do
      %{id: "j#{n}", printer: Enum.at([:p1, :p2, :p3], rem(n, 3))}
    end

    results = jobs
    |> Enum.map(fn job ->
      Task.async(fn ->
        name = if rem(String.to_integer(String.trim_leading(job.id, "j")), 2) == 0,
                  do: :unit_s2, else: :unit_s1
        Server.submit(name, job)
      end)
    end)
    |> Task.await_many(5_000)

    assert Enum.all?(results, &match?({:queued, _}, &1))
    assert eventually(fn ->
      Enum.reduce(printers, 0, fn {_, pid}, count ->
        count + map_size(Printer.status(pid).print_counts)
      end) == 18
    end)

    counts = printers
    |> Map.values()
    |> Enum.flat_map(fn p -> Map.values(Printer.status(p).print_counts) end)

    assert length(counts) == 18
    assert Enum.all?(counts, &(&1 == 1))
  end

  test "one server rejects repeated submissions with the same ID" do
    {:ok, printer} = Printer.start_link(id: :p1, delay_ms: 1)
    {:ok, server} = Server.start_link(id: :s1, initial_token: true,
                                      peer: :unused_peer,
                                      printers: %{p1: printer})
    job = %{id: "repeat-1", printer: :p1}
    assert {:queued, "repeat-1"} = Server.submit(server, job)
    assert {:error, :duplicate_job_id} = Server.submit(server, job)
    assert eventually(fn -> Printer.status(printer).print_counts["repeat-1"] == 1 end)
  end

  test "printer discards duplicate delivery of the same job" do
    {:ok, printer} = Printer.start_link(id: :p1, delay_ms: 1)
    job = %{id: "unique", printer: :p1}
    GenServer.cast(printer, {:print, job, self()})
    GenServer.cast(printer, {:print, job, self()})
    assert eventually(fn -> Printer.status(printer).print_counts["unique"] == 1 end)
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(_predicate, 0), do: false
  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(15)
      eventually(predicate, attempts - 1)
    end
  end
end
