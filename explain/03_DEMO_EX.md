# `lib/distributed_print/demo.ex` explained for a Java developer

**Actual source:** 29 lines. This is a quick local **single-BEAM** demonstration, not the five-node distributed test.

- **1–3**: declares `DistributedPrint.Demo`, describes its purpose, and uses `alias DistributedPrint.{Server, Printer}`. An Elixir `alias` gives shorter module names; think Java `import DistributedPrint.Server; import DistributedPrint.Printer;`.
- **5 `def run do`**: zero-argument public function. `do` begins function body, `end` closes it.
- **6–8**: `{:ok, p1} = Printer.start_link(...)` starts three printer actors with `delay_ms: 20`. `{:ok,p1}` is tuple pattern matching (success result and printer PID), roughly `Result<PrinterRef>` unpacking in Java.
- **9 `printers = %{p1: p1, p2: p2, p3: p3}`**: map printer symbolic IDs → process references. Java `Map<PrinterId, ActorRef>`.
- **11–15**: start S1 with `initial_token: true` and S2 without (so false). Both point to each other by registered names `:demo_s1` and `:demo_s2`, and share mappings of available printer actor addresses. They are separate GenServers within one BEAM, not separate Erlang VM nodes.
- **17–22 `for n <- 1..9 do`**: loop nine times (Java `for(int n=1; n<=9; n++)`). `rem(n,2)` chooses alternating server; `Enum.at([...], rem(n-1,3))` cycles P1/P2/P3. A job map contains unique string `id`, chosen `printer` and simulated `payload`. `"job-#{n}"` is string interpolation, like Java `"job-"+n`. `IO.inspect` prints submission result.
- **24 `Process.sleep(700)`**: pauses demo controller 700 ms so printing can proceed; **not** a correctness mechanism.
- **25–27**: query two server status snapshots and all three printer snapshots; print with labels.

**Java equivalent sketch**:

```java
var p1 = startPrinter("p1", 20);
var p2 = startPrinter("p2", 20);
var p3 = startPrinter("p3", 20);
var printers = Map.of("p1", p1, "p2", p2, "p3", p3);
var s1 = startServer("s1", /* peer = s2 */, printers, true);
var s2 = startServer("s2", /* peer = s1 */, printers, false);
for (int n = 1; n <= 9; n++) {
  var server = n % 2 == 0 ? s2 : s1;
  var printer = List.of("p1", "p2", "p3").get((n-1)%3);
  System.out.println(submit(server, new Job("job-"+n, printer, "document "+n)));
}
Thread.sleep(700);
System.out.println(status(s1));
```

**Defense point**: Demo validates the *message-handling logic locally* and is quick for screenshots. To demonstrate five separate Erlang VMs, run `test/distributed_test.exs`, described separately.
