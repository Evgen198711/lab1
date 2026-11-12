defmodule DistributedPrint.Demo do
  @moduledoc "Run a simulation on a single BEAM for a quick sanity check."
  alias DistributedPrint.{Server, Printer}

  def run do
    {:ok, p1} = Printer.start_link(id: :p1, delay_ms: 20)
    {:ok, p2} = Printer.start_link(id: :p2, delay_ms: 20)
    {:ok, p3} = Printer.start_link(id: :p3, delay_ms: 20)
    printers = %{p1: p1, p2: p2, p3: p3}

    {:ok, _s1} = Server.start_link(id: :s1, name: :demo_s1,
                                    peer: :demo_s2, printers: printers,
                                    initial_token: true)
    {:ok, _s2} = Server.start_link(id: :s2, name: :demo_s2,
                                    peer: :demo_s1, printers: printers)

    for n <- 1..9 do
      server = if rem(n, 2) == 0, do: :demo_s2, else: :demo_s1
      printer = Enum.at([:p1, :p2, :p3], rem(n - 1, 3))
      IO.inspect(Server.submit(server, %{id: "job-#{n}", printer: printer,
                                         payload: "document #{n}"}), label: "submit")
    end

    Process.sleep(700)
    IO.inspect(Server.status(:demo_s1), label: "server 1")
    IO.inspect(Server.status(:demo_s2), label: "server 2")
    for p <- [p1, p2, p3], do: IO.inspect(Printer.status(p), label: "printer")
  end
end
