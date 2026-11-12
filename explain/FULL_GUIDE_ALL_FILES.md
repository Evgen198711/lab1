# Complete Distributed Printing Lab 1 — explanations for a Java developer

Generated from the supplied ZIP. Elixir and TLC tests were not rerun while preparing these notes.


---

<!-- FILE: 00_START_HERE.md -->

# Distributed Printing Lab 1 — complete study guide for a Java developer

**Source**: `distributed_print_lab1_message_loss_recovery.zip` supplied in this conversation. These guides explain *that exact archive*, not an older `server.ex`. Line numbers refer to that version. The original implementation is **Elixir/OTP**; formal specifications are **TLA+**.

## Reading order

1. `01_SERVER_EX.md` — how a server starts, holds the token, dispatches jobs, retransmits messages.
2. `02_PRINTER_EX.md` — how a printer queues, prints, deduplicates, reports completion.
3. `03_DEMO_EX.md` — walk through the end-to-end working example.
4. `04_DISTRIBUTED_TEST_EXS.md` and `05_PRINTING_TEST_EXS.md` — integration and unit tests.
5. `06_MIX_AND_TEST_HELPER.md` — Elixir project and test configuration.
6. `07_PRINTTOKEN_TLA.md`, `08_PRINTTOKENLOSS_TLA.md`, `09_PRINTTOKENRETRY_TLA.md`, `10_TLC_CONFIGS.md` — formal models and checks.
7. `11_README_AND_DEFENSE.md` — how to run the system and present it.
8. `12_DEFENSE_QUESTIONS.md` — short examiner-ready answers.

## Key Java-to-Elixir dictionary

| Elixir | Closest Java mental model | Important difference |
|---|---|---|
| `defmodule X do ... end` | class / namespace | Module is not a Java instance. |
| `use GenServer` | actor framework + callbacks | Expands module behavior at compile time; not `import`. |
| `def` / `defp` | public / private method | Functions are in modules, not objects. |
| `def f(x), do: expr` | one-line method returning `expr` | Last expression is returned automatically. |
| `opts` | config map or `Map<String,Object>` | In this project it is an Elixir keyword list: list of `{atom,value}` pairs. |
| `[id: :s1, retry_ms: 50]` | `Map.of("id", "s1", "retryMs", 50)` | Values can be different types; keys are atoms. |
| `%{id: id}` | map / Java record-like data | Elixir maps are immutable. |
| `:s1` or `:printed` | enum constant / symbolic identifier | An **atom**, not a Java String. |
| `{:ok, pid}` | tagged result (`Success(pid)`) | A tuple; matched by patterns. |
| `MapSet.new()` | `new HashSet<>()` | Immutable set returned by updates. |
| `:queue.new()` | `ArrayDeque` | Functional FIFO queue; returns updated queue. |
| `GenServer.call(pid, msg)` | request-response actor call | Waits for reply; synchronous. |
| `GenServer.cast(pid, msg)` | send-to-mailbox | Does **not** wait for reply; asynchronous. |
| `send(self(), :drive)` | enqueue a message to own worker | Drives a later mailbox turn. |
| `handle_call` / `handle_cast` / `handle_info` | actor's request handler / event handler | Callback returns new state, not field mutation. |
| `%{state | queue: newQ}` | Java `state.withQueue(newQ)` | Constructs a new map with an updated value. |
| `case` / `cond` | pattern-matching switch / if-else chain | Guards and patterns select branches. |
| `|>` | chaining intermediate method results | Left result becomes first argument of next call. |
| `_from` / `_unused` | ignored argument | Underscore denotes ignored binding; `^id` instead pins a prior value. |
| `@default_retry_ms 60` | `static final int RETRY_MS = 60` | Module attribute, normally compile-time replacement. |
| `__MODULE__` | `Server.class` (roughly) | Refers to current Elixir module. |

**Crucial**: one **Erlang node** is a BEAM virtual-machine instance; one **GenServer process** is a lightweight actor running within a node. In the distributed test, the server actors are placed on `s1` and `s2`, printer actors on `p1`, `p2`, `p3`; a sixth node runs the test controller. This can be on one physical computer and still involves separate VM instances and message passing.

## Overall runtime flow

1. Client calls `Server.submit(server, %{id: ..., printer: ..., payload: ...})`.
2. Server checks printer exists and ID has not been submitted to **that server**, then puts job in its FIFO `queue`.
3. Only a token holder may remove a queued job and send `{:print, job, server_pid}` to the target printer.
4. A non-holder requests token from the other server; token handoff is acknowledged, and retries carry the **same transfer ID**.
5. Printer ignores wrong destinations and duplicate job IDs; otherwise enqueues the job and processes one job at a time. Different printers operate independently.
6. On completion, printer sends `{:printed, id, printer_id}` to originating server. The server deletes its `in_flight` entry and marks completed.
7. If a print message OR its completion notification is lost, server retries the `:print` delivery. The printer does **not** reprint completed IDs, but responds again with `:printed`.

## Very important correction to our earlier spoken discussion

This exact version does **not** send a separate `COMPLETION_ACK` from server to printer. Instead, `:printed` is the printer-to-server **completion notification**, which also implicitly acknowledges successful completion of the original `:print` message. The server keeps retrying `:print` until it hears `:printed`. Token handoff **does** use a distinct `:token_ack` message. Do not mix the two ACK mechanisms in your defense.

## Failure guarantees and limitations

- **Assumed**: no actor crashes or reboots; globally unique job IDs; target printer for a job never changes; retryable messages eventually get through.
- **Simulated loss**: deterministic `drop_first` maps suppress a finite number of **outgoing** sends. This is not random packet loss, a network outage or a durable failure system.
- **Not guaranteed**: operation across permanent partitions, crash recovery, durable queues, surviving a reboot, physical exactly-once printing after a printer crash. Job IDs and state are only in memory.
- Different jobs must have different IDs; resending the **same** ID means retry, not a request for another copy.
- The `mix test` **default excludes** `@moduletag :distributed`. Run the special distributed test command to exercise the five nodes.
- I inspected the supplied source archive. **I did not execute Elixir tests or TLC in this environment**. Source code and intended tests are described, but no new passing result is asserted.

## A complete message sequence (S2 initially lacks token)

`Client → S2: submit(job-8, P3)` → `S2 → S1: :token_request` → `S1 → S2: {:token, sender, transfer_id}` → `S2 → S1: {:token_ack, sender, transfer_id}` → `S2 → P3: {:print, job, S2}` → `P3 → S2: {:printed, job_id, :p3}`.

Only S2 may dispatch while it owns the token. P3 may still be printing after S2 sends the token back; the token coordinates **dispatch**, not the whole duration of a print job.


---

<!-- FILE: 01_SERVER_EX.md -->

# `lib/distributed_print/server.ex` explained for a Java developer

**Actual file:** 270 lines. **Role:** one GenServer actor per print server. Maintains local queue, token ownership, retry state and job completion state. All line numbers are from the ZIP supplied in the chat.

## Module, constant, start functions — lines 1–33

- **1–20 `defmodule ...; use GenServer`**: defines the module and loads GenServer callback machinery. `@moduledoc` is documentation, not executable code. Think *actor class with a mailbox*, not a static Java variable.
- **22 `@default_retry_ms 60`**: compile-time module attribute used as 60 ms retry interval unless overridden. Closest Java analogy: `private static final int DEFAULT_RETRY_MS = 60;`.
- **24 `start_link(opts)`**: calls `GenServer.start_link(__MODULE__, opts, name_opts(opts))`. Starts an actor **linked** to its caller. If linked processes fail abnormally, failure signals can propagate.
- **27 `start(opts)`**: `GenServer.start(...)` starts an **unlinked** actor. The distributed test uses this via a short-lived `:rpc.call` worker, which should not own a child link.
- **29 `defp name_opts(opts)`**: `Keyword.take(opts, [:name])`. `defp` = private method; extracts only the optional `:name` startup setting. Java analogy: `Map<String,Object> registration = take(config, "name")`. If absent, returns an empty keyword list.
- **32 `submit(server, job)`**: synchronous `GenServer.call(server, {:submit, job})`. Java analogy: `serverActor.ask(new Submit(job))`.
- **33 `status(server)`**: synchronous read request. Java analogy: `serverActor.ask(new GetStatus())`.

The two-underscore spelling `__MODULE__` is *this module* (`DistributedPrint.Server`), not `this` Java object. `name_opts(opts)` invokes a different private function; `GenServer.start_link` does not recursively call our `start_link` function.

## `init(opts)` — lines 35–62

GenServer calls `init` once as the process starts. It sets a periodic retry timer and returns `{:ok, state}`. Think `State state = new State(...)` plus a scheduler.

- `Keyword.get(opts, :retry_ms, @default_retry_ms)` returns provided retry milliseconds or 60.
- `Process.send_after(self(), :retry, retry_ms)` schedules a **message** `:retry` to this process, not a Java scheduled callback directly.
- `Keyword.fetch!(opts, :id)`, `:peer`, `:printers`: **required** options; `fetch!` raises if missing. `Keyword.get(opts, :initial_token, false)` is optional.
- `has_token`: whether this server currently may dispatch jobs.
- `requested_token`: whether it has requested the token.
- `peer_waiting`: whether the other server requested a turn.
- `queue`: local pending jobs, a functional FIFO `:queue`.
- `seen`: job IDs submitted to **this** server; rejects repeat local submission.
- `dispatched` / `completed`: sets of job IDs dispatched / confirmed complete.
- `in_flight`: map job ID → dispatched job still awaiting `:printed`; source of print retries.
- `outgoing_transfer`: a transfer awaiting token ACK, or `nil`. Sender has already set `has_token: false`.
- `next_transfer_number`: monotonically increasing sequence used in transfer IDs.
- `received_transfers`: receiver-side set of already accepted transfer IDs; prevents re-creating a token from replayed grants.
- `drop_remaining`: finite test loss counters, e.g. `%{token: 1}`; `dropped`: observability counters.

**Java comparison:** Most fields are analogous to fields of a `ServerState` record with `Queue<Job>`, `Set<String>`, `Map<String,Job>`, flags and counters. Crucially, Elixir state is *replaced*, not modified in place: `%{state | has_token: true}` returns a new map.

## Submission handlers `handle_call` — lines 64–101

**65–83**: pattern matches `{:submit, %{id: id, printer: printer} = job}`. The `=` binds the entire matched job as `job`; `%{id: id, printer: printer}` extracts required map keys. `cond` is an if–else chain:

1. Printer absent from `state.printers` → `{:reply, {:error, :unknown_printer}, state}`.
2. ID already in `state.seen` → duplicate error.
3. Else add job to FIFO and ID to `seen`, enqueue `send(self(), :drive)`, reply `{:queued, id}`.

**85–86**: fallback clause for a submission whose shape is not right, returning `:invalid_job`. Pattern matching, like an overloaded Java handler with an additional case.

**88–101**: `handle_call(:status, _from, state)` returns a **snapshot** (`server`, token flag, pending job IDs, dispatched/completed sets, in-flight IDs, pending transfer, dropped counters). `:queue.to_list(...) |> Enum.map(& &1.id)` = convert queue to list, then map each job to its ID. `{:reply, snapshot, state}` replies without changing state.

**GenServer return tuples:** `{:reply, response, new_state}` for synchronous calls; `{:noreply, new_state}` for asynchronous messages.

## Token and completion `handle_cast` — lines 103–158

**104–109 `{:token_request, _sender}`**: marks `peer_waiting = true` and schedules `:drive`. It doesn't immediately create a token. Duplicate requests are harmless.

**111–131 `{:token, sender, transfer_id}`**:

- If ID already in `received_transfers`, do **not** set `has_token = true`; just retransmit `:token_ack`. This is why a lost ACK cannot duplicate token ownership.
- Otherwise record transfer ID, set `has_token = true`, clear `requested_token` and obsolete `outgoing_transfer`, send ACK, and schedule `:drive`.
- The receiver can recognize an old token grant **even after it returned the token**, because it remembers the accepted transfer IDs.

**133–142 `{:token_ack, _sender, transfer_id}`**: `case state.outgoing_transfer` checks matching ID. `%{id: ^transfer_id}` uses the **pin operator** `^`: require equality with previously bound `transfer_id`, not a new binding. On match clear pending transfer; ignore late/unexpected ACKs.

**144–158 `{:printed, id, printer_id}`**: look up `state.in_flight[id]`. If the in-flight job's `:printer` equals the message's printer ID, add ID to `completed` and delete from `in_flight`. Otherwise ignore duplicate/spurious completion. **There is no server-to-printer `COMPLETION_ACK` in this version.**

## Timers and dispatch — lines 160–210

**161 `handle_info(:drive, state)`**: receives regular mailbox message `:drive` and runs `drive`. `handle_info` differs from `handle_cast`: ordinary `send` or timers land here.

**163–175 `handle_info(:retry, state)`**: the periodic retry cycle:

```elixir
state
|> retry_transfer()
|> retry_token_request()
|> retry_print_jobs()
|> drive()
```

Imagine Java:

```java
State next = drive(retryPrintJobs(retryTokenRequest(retryTransfer(state))));
scheduleRetry(next.retryMs());
```

Elixir's `|>` passes the expression on the left as the **first argument** of the next function. It schedules the next `:retry` message, so retries continue while actor runs.

**177–210 `drive(state)`** chooses one of four cases:

1. **Has token and queued jobs**: take head of FIFO; look up target from `printers` map; move job to `dispatched` and `in_flight`; call `emit(:print, target, ...)`. If peer is waiting, **give token after this one job**. Otherwise enqueue another `:drive` message for later.
2. **Has token and peer waiting but no local queued jobs**: give token immediately.
3. **No token and queued jobs and request not yet sent**: request token.
4. Otherwise: no change.

The dispatch check is the mutual-exclusion gate: **`state.has_token`**. Releasing the token does **not** wait for printer completion. Sending `:drive` to self between jobs allows token requests to be handled between dispatches.

## Token handoff and retransmission — lines 212–254

**212–229 `give_token(state)`**:

- Creates ID `{state.id, state.next_transfer_number}` (e.g. `{:s1, 1}`). This is a two-element tuple, comparable to a Java record `TransferId(serverId, sequence)`.
- **Before** emitting grant: sets `has_token: false`, clears peer waiting, records `outgoing_transfer: %{id: transfer_id}`, increments counter.
- Sends `{:token, self(), transfer_id}` to peer through `emit`.
- If this server still has queued work, requests token back; otherwise stops.

**231–234 `request_token`**: `emit` sends `{:token_request, self()}` to peer and sets `requested_token = true`.

**236–240 `retry_transfer`**: if no pending transfer, do nothing; otherwise send **same** transfer ID again. It does not mint a new token. This is essential if grant or ACK was lost.

**242–248 `retry_token_request`**: when missing token and local queue not empty, periodically resend request. No separate per-request ACK is used.

**250–254 `retry_print_jobs`**: iterate over `in_flight`, sending each job again with **same job ID**. `Enum.reduce` is comparable to Java stream reduction/fold; accumulator carries updated state (including dropped-message counters).

## Message loss injector `emit` — lines 256–269

`emit(state, kind, destination, message)` is a single outgoing-send wrapper:

- Read `drop_remaining[kind]`; if greater than zero, **do not send**, decrement count, increment `dropped[kind]`, return updated state.
- Otherwise call `GenServer.cast(destination, message)` (asynchronous) and return unchanged state.
- `kind` can be `:token_request`, `:token`, `:token_ack`, `:print`. The printer has a separate suppression mechanism for its outgoing `:printed` notifications.

**Java analogy:** a test `MessageTransport.send` wrapper that discards the first N messages of a specified category before delivering normally.

## Three indispensable defense statements

1. *Only the token holder dispatches, but printers may execute in parallel.*
2. *If token grant or acknowledgment is lost, the same transfer ID is retransmitted and recognized as a duplicate.*
3. *The server treats `:printed` as end-to-end completion confirmation; while it is missing, the server retries `:print` with the same ID.*

**Limitation:** These guarantees assume no crashes and eventual message delivery; state and deduplication records are in memory. The project is not a durable production spooler.


---

<!-- FILE: 02_PRINTER_EX.md -->

# `lib/distributed_print/printer.ex` explained for a Java developer

**Actual source:** 106 lines. **Purpose:** a GenServer for each printer: FIFO queue, at most one active job, duplicate suppression, optional simulated loss of `:printed` notification.

## Lines 1–16: declaration and public API

- `defmodule DistributedPrint.Printer do`: module definition; `use GenServer` starts framework callback support.
- `start_link(opts)` / `start(opts)` (12–13): start linked / unlinked printer actor, just as in the server module.
- `defp name_opts(opts), do: Keyword.take(opts, [:name])` (14): keep only optional `:name`, used for registration; keyword list is analogous to a Java config map.
- `status(printer)` (16): `GenServer.call(printer, :status)`: synchronous status query, like `printerActor.ask(GetStatus)`.

## `init(opts)` — lines 18–31

Creates the printer's state map. Java mental model:

```java
record PrinterState(String id, int delayMs, Queue<JobWithOrigin> queue,
                    JobWithOrigin active, Set<String> seen,
                    Map<String,Integer> printCounts,
                    Map<String,Integer> dropRemaining,
                    Map<String,Integer> dropped) {}
```

- `id`: mandatory symbolic printer ID (`:p1`, `:p2` or `:p3`).
- `delay_ms`: simulated printing time; defaults to 30 ms.
- `queue`: FIFO pending jobs, as `:queue.new()`.
- `active: nil`: no job printing initially.
- `seen`: IDs already received, whether queued, active or finished; prevents duplicate queue entries.
- `print_counts`: map from completed job ID to number of simulated physical prints; used in tests.
- `drop_remaining`: injectable finite outgoing `:printed` losses, e.g. `%{printed: 1}`.
- `dropped`: actual drops recorded for test assertions.

These are *local process state*, not a database. The printer loses them on restart.

## `handle_cast({:print, job, origin}, state)` — lines 33–57

This asynchronous callback receives a message sent by the server. Pattern `%{id: id, printer: target} = job` extracts ID and target printer from the job map. `origin` is the server process identifier / remote name where completion will go.

`cond` is an if / else-if chain:

1. **Wrong printer target** (`target != state.id`): return unchanged; do not queue.
2. **Already physically printed** (`Map.has_key?(state.print_counts, id)`): call `notify_completed` again; do **not** start another print. This handles lost completion notification after a successful print.
3. **Already seen but not finished** (`MapSet.member?(state.seen, id)`): ignore redelivery; original queued or running job will eventually send the completion notification.
4. **First delivery**: add ID to `seen`; append `{job, origin}` to FIFO; call `start_next_if_idle` to start now if possible.

**Java analogy**: `onMessage(PrintMessage msg)` with guards against wrong destination and duplicate IDs, then `queue.add(msg); if (active == null) startNext();`.

## `handle_info({:finish, id}, state)` — lines 59–66

This handles a timer-generated completion event. Header matches `active: {%{id: id}, origin}` with the same `id` as the timer message, so only the current active job may finish.

- Increment `print_counts[id]` using `Map.update` (Java `counts.merge(id, 1, Integer::sum)`).
- Mark active job `nil` (printer becomes idle).
- Run `notify_completed(origin,id)`, then `start_next_if_idle` to begin next queued job.
- Return `{:noreply, new_state}`.
- A stale `{:finish, old_id}` goes to the fallback handler on line 66, which leaves state unchanged.

This is simulated printing: waiting for `Process.send_after` event, not transmitting a real PDF to printer hardware.

## `handle_call(:status,...)` — lines 68–79

Replies with printer ID, active job ID (if any), waiting IDs, `print_counts`, `seen` and `dropped`. This is comparable to a Java `PrinterStatus` DTO. Notice `Enum.map(fn {job, _} -> job.id end)` extracts the queued job ID and ignores its origin.

## `notify_completed(state, origin, id)` — lines 81–92

The printer's outgoing completion-message wrapper:

- If `drop_remaining[:printed] > 0`, decrement the configured drop counter and increment `dropped[:printed]`, **without delivering** the notification.
- Otherwise `GenServer.cast(origin, {:printed, id, state.id})`, asynchronous printer → server notification.

**Critical distinction:** `:printed` is NOT followed by a separate completion ACK from server to printer in this implementation. If `:printed` gets lost, the server's `in_flight` entry remains, it retransmits `:print`, and this printer's *already printed* branch responds with `:printed` again **without physical reprint**.

## `start_next_if_idle` — lines 94–105

There are **two clauses** of the same private function:

- **94–103** matches `%{active: nil}`: if queue empty, return state. If nonempty, pop FIFO head, schedule `{:finish, job.id}` with `Process.send_after(self(), ..., state.delay_ms)`, update `active: {job, origin}` and queue tail.
- **105** catch-all: if already busy, return state unchanged.

This gives **at most one active job on each printer**, though three separate printer processes can operate simultaneously. Java analogue: `if (active != null) return; Job job = queue.poll(); active = job; scheduledExecutor.schedule(() -> finish(job), delayMs, MILLISECONDS);`.

## Example with a lost notification

1. Server sends `{:print, %{id: "X", printer: :p1}, server}`.
2. P1 enqueues, starts, finishes; `print_counts["X"] == 1`.
3. First `:printed` notification is intentionally dropped.
4. Server still has `"X"` in its `in_flight` map; retry timer resends `:print` with ID `"X"`.
5. P1 recognizes ID in `print_counts`, skips printing, and sends another `:printed`.
6. Server marks job complete. Total print count stays **1**.

## Limits

Printer deduplication is memory-only. A crash/restart could erase `seen` and `print_counts`; there is no durable spool or transactional integration with real printer hardware.


---

<!-- FILE: 03_DEMO_EX.md -->

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


---

<!-- FILE: 04_DISTRIBUTED_TEST_EXS.md -->

# `test/distributed_test.exs` explained for a Java developer

**Actual source:** 304 lines; nine distributed tests. Think **JUnit integration tests** using remote actors instead of Spring beans. The test controller is a sixth Erlang node that connects to five already-running nodes.

## Test class and configuration — lines 1–10

- `defmodule DistributedPrint.DistributedTest` = test class.
- `use ExUnit.Case, async: false` = JUnit-like test framework, tests execute non-concurrently to avoid interference.
- `@moduletag :distributed` = category/tag; excluded by default in `test_helper.exs`.
- `@moduletag timeout: 30_000` = test timeout 30 s. Underscore in numeric literal is like Java `30_000`.
- `alias` shortens module names.

## `setup tags do` — lines 11–98

**JUnit analogue**: `@BeforeEach void setUp(TestInfo tags)` plus `@AfterEach cleanup`.

1. Require distributed Erlang with `Node.alive?()`.
2. Compute hostname from `Node.self()` and construct atom node names `s1@host`, `s2@host`, `p1@host`, `p2@host`, `p3@host`.
3. `Node.connect(node)` for all five; fail test if unreachable.
4. Generate unique registered process names with current microsecond timestamp and unique integer. Same logical name can be used on different nodes because registration is local to that node.
5. `on_exit(fn -> ... end)` registers cleanup: query each remote name with `:rpc.call(node, :erlang, :whereis, [name])`, stop only test-created actors. Think JUnit `@AfterEach`.
6. Read test tags (`printer_delay_ms`, drop configs), remotely start printer actors by `:rpc.call(node, Printer, :start, [[options]])`.
7. Build `printer_refs` as map of `:p1` → `{printer_name, p1_node}`, etc. A `{name,node}` tuple is an Erlang destination address; **not** Java shared-object memory.
8. Remotely start server actors on S1/S2 with `Server.start` (unlinked), peers set to `{server_name, remote_node}`, initial token held only by S1, `retry_ms: 50` and optional `drop_first` maps.
9. Verify all remote processes exist, return context `%{s1: ..., s2: ..., printers: ...}` to test bodies.

Why `Server.start`, not `start_link`? RPC workers are short-lived and linked child processes could die when those workers exit; the unlinked start avoids this for tests. A production design would use supervisors on each node.

## Nine tests, function by function

### Test 1 — lines 100–129: 12 concurrent submissions

Create twelve job maps with distinct IDs and rotating printer destinations. `Enum.with_index` associates each with index; `Task.async` submits alternate jobs to S1 and S2 concurrently, and `Task.await_many(5_000)` collects results. Assert each submission is `{:queued, _}` and *eventually* twelve distinct IDs show up in printer `print_counts`, each with value 1. Java analogy: `CompletableFuture.supplyAsync(...); allOf(...).join(); assertEquals(1, count)`.

### Test 2 — lines 131–156: token S1 → S2 → S1

Initially S1 holds token, S2 not. Submit first job to S2, wait until S2 has token and dispatches; then submit second to S1 and wait for return. Check the opposite server lacks token at each stable checkpoint. Verifies token can circulate in both directions.

### Test 3 — lines 158–192: printer serializes two jobs

`@tag printer_delay_ms: 800` makes printing visibly slow. Submit first job to P1 from S1, await P1 active. Submit second to P1 from S2. Assert printer is still active on first while second is waiting. Eventually verify each printed once and queue drains. This is **printer-local serial execution**, not the global token blocking completion.

### Test 4 — lines 194–209: duplicate protection

Submit job twice to same server; second returns `{:error, :duplicate_job_id}`. Then manually redeliver `{:print, job, origin}` using `GenServer.cast` to remote P3 and verify its print count remains 1. Reinforces distinct layers: server submission dedup and printer delivery dedup.

### Test 5 — lines 212–223: first `:token_request` lost

`@tag s2_drop: %{token_request: 1}` makes S2 suppress first outgoing request. Wait for eventual completion, check it printed once and `dropped[:token_request] == 1`. The server's retry timer makes progress.

### Test 6 — lines 225–238: first `:token` grant lost

`@tag s1_drop: %{token: 1}` discards S1's first grant. S1 records transfer ID, relinquishes ability to dispatch, retransmits same transfer. Assert S2 eventually owns token; print count 1; one grant drop recorded.

### Test 7 — lines 240–257: first token ACK lost

`@tag s2_drop: %{token_ack: 1}`. Have S2 receive token and finish first job. S1 may retry grant while waiting for ACK. Then request token back by submitting job at S1. Verify both jobs printed once, final S1 token holder, S2 not. The receiver remembers grant IDs and does not turn a repeated grant into a new token.

### Test 8 — lines 259–270: first `:print` lost

`@tag s1_drop: %{print: 1}`. S1 sends first job; `emit` discards message; `retry_print_jobs` later sends again. Assert completion and one printed copy; drop count 1.

### Test 9 — lines 272–285: first `:printed` lost

`@tag printer_drop: %{p1: %{printed: 1}}`. P1 prints job once but first completion notification is suppressed. S1 resends original `:print`; P1 recognizes already-finished ID and re-notifies without reprinting. Assert `print_counts[id] == 1`, one drop recorded, and server `awaiting_completion == []`.

## Helpers — lines 287–303

- **`total_completed(printers)`**: `Enum.reduce` sums the *number of distinct completed job IDs* on all printers. It's like `printers.stream().mapToInt(p -> p.status().printCounts().size()).sum()`.
- **`eventually(predicate, attempts \ 200, sleep_ms \ 30)`** declares default parameters; note the doubled backslash in Elixir source, unlike Java method overloading.
- **`eventually(_predicate, 0, _sleep_ms)`** returns false when attempts exhausted (pattern-match base case).
- **`eventually(predicate, attempts, sleep_ms)`** calls the zero-argument predicate function `predicate.()`. If false, sleeps and recursively retries with attempts minus one. Java analogue: a bounded Awaitility-style polling helper.

## Defense warning: test execution status

This source **defines** 9 distributed tests, but reading source alone does **not** prove they passed. Run all with five active nodes plus controller:

```bash
elixir --sname test --cookie printlab -S mix test --include distributed test/distributed_test.exs
```

A default `mix test` without `--include distributed` does not run these tagged tests.


---

<!-- FILE: 05_PRINTING_TEST_EXS.md -->

# `test/printing_test.exs` explained for a Java developer

**Actual source:** 87 lines; four basic tests. These test multiple GenServer processes inside one BEAM; **not** five remote Erlang VMs. Think JUnit unit/integration tests with assertions and actor futures.

- **1–3**: `use ExUnit.Case, async: false` is analogous to JUnit; `alias` imports shorter module names.
- **5–15, test initial token**: start one printer and two linked servers, with `initial_token: true` only on S1. Assert S1 `has_token`, S2 does not. `assert` and `refute` correspond to JUnit `assertTrue` / `assertFalse`.
- **17–56, test concurrent submissions**: start three printer actors (comprehension `for ... into: %{}` builds map), two server actors, create 18 jobs, asynchronously submit them with `Task.async`, wait via `Task.await_many(5_000)`. Poll until all printed. Verify 18 completed IDs and each print count == 1. Java: `CompletableFuture`, collections and `assertEquals`.
- **58–67, test repeat submission**: submit job ID `repeat-1` twice to same server; first queued, second yields duplicate ID error; printer count remains exactly one.
- **69–75, test duplicate printer delivery**: send two identical `{:print, job, self()}` messages to a printer actor. Printer should suppress repeat physical printing. `self()` is test-process PID, used as originating recipient in test.
- **77–86, `eventually` helper**: bounded retry-based polling: if predicate true return true, else sleep 15 ms and recursively check until attempts exhausted. `defp` means private; multiple function clauses implement base case and recursive case. Java counterpart: Awaitility or a loop with deadline.

**Important precision**: These tests check *specific* scenarios, not every possible interleaving. They do not demonstrate machine-checked correctness; that's the purpose of the separate TLA+ models. The original source defines four tests, but they were not rerun here.


---

<!-- FILE: 06_MIX_AND_TEST_HELPER.md -->

# `mix.exs` and `test/test_helper.exs` explained for a Java developer

## `mix.exs` — 14 lines

`Mix` is Elixir's project/build tool, somewhat like **Maven or Gradle**. `defmodule DistributedPrint.MixProject do` defines build configuration; `use Mix.Project` sets up project DSL/callbacks.

- `def project do ... end`: returns a keyword list of project settings, similar to `build.gradle` metadata.
- `app: :distributed_print`: OTP application name (an atom).
- `version: "0.1.0"`: version string.
- `elixir: "~> 1.15"`: compatible Elixir version requirement, not a Java language level.
- `start_permanent: Mix.env() == :prod`: production mode setting.
- `deps: []`: no external Mix dependencies; standard libraries still used.
- `def application, do: [extra_applications: [:logger]]`: starts the standard logger OTP application.

Java analogy: Gradle project metadata, dependency list, application setup. `mix compile` compiles code; `mix test` runs ExUnit; `mix run` executes the app.

## `test/test_helper.exs` — line 1

`ExUnit.start(exclude: [:distributed])`

Like a JUnit tag filter: starts the test framework and **excludes distributed-tagged tests from the default suite**. Therefore ordinary `mix test` runs the four local tests only. To run the separate five-node suite, explicitly include its tag and start the prerequisite nodes.

## `.ex` vs `.exs`

`.ex` = usual compiled source files; `.exs` = Elixir script files, often tests and Mix configuration. There is no Java `public static void main` required for every file.


---

<!-- FILE: 07_PRINTTOKEN_TLA.md -->

# `spec/PrintToken.tla` explained for a Java developer

**Actual source:** 206 lines. **Purpose:** finite formal model of *reliable* message delivery with 2 servers, 3 printers and 3 jobs. It is not executable Elixir; TLC enumerates possible abstract system states/transitions.

## Fundamental syntax vs Java

| TLA+ | Meaning | Closest Java way to think |
|---|---|---|
| `X == expression` | define operator, not variable assignment | named predicate/function |
| `VARIABLES a,b` | state variables | fields of `ModelState` |
| `Init == ...` | valid initial states | constructor/precondition |
| `Next == A \/ B` | any allowed next action | nondeterministic switch among transitions |
| `x'` | value of `x` in **next** state | `next.x` vs `current.x` |
| `/\` and `\/` | AND / OR | `&&`, `||` |
| `\in`, `\cup`, `\` | belongs-to, union, set difference | `contains`, union, subtraction |
| `\A`, `\E` | for all / exists | `allMatch`, `anyMatch` |
| `UNCHANGED <<x,y>>` | fields don't change | copy those fields into next state |
| `[]P`, `<>P` | always P, eventually P | temporal properties, not normal Java `if` |
| `P ~> Q` | whenever P, eventually Q | leads-to liveness property |
| `WF_vars(Action)` | weak fairness of action | assume continuously enabled action eventually occurs |

The model checker has a *global view* of all variables so it can verify the abstract protocol. That **does not** mean the Elixir actors share memory.

## Declarations — lines 1–37

`EXTENDS Naturals, FiniteSets, Sequences, TLC` imports basic math/sequence operators for the formal language. `Servers`, `Printers`, and `Jobs` are explicitly small finite sets. `Target(j)` fixes the assigned printer for each job: J1→P1, J2→P2, J3→P3. **This is a verification simplification**; runtime client requests supply a destination in their job maps. `Other(s)` returns peer server. `SeqSet` converts a sequence to a set.

Global state variables include `tokenAt`, `tokenTo`, `requests`, server queues, `served` (per-server turn bookkeeping), `submitted`, `dispatched`, in-flight `printMessages`, per-printer queues and seen sets, `active` and `printCount`.

## `Init` — lines 38–52

S1 has token, S2 none; all queues, message sets and completed lists empty; printer slots idle; print counts zero. Java analogy: instantiate a model state with default values.

## Every transition, function by function

- **`Submit(s,j)` (54–63)**: an as-yet-unsubmitted job can be appended to either server's pending queue, and job enters global `submitted` set. Models independent client submissions.
- **`RequestToken(s)` (65–77)**: a server without token and with queued work adds its request to abstract network mailbox `requests`, if not already requested and if token isn't already heading its way.
- **`GrantToken(s)` (79–90)**: current holder sends token toward waiting peer and stops owning it. If holder also has pending work, it must have dispatched at least one this turn (anti-starvation design).
- **`ReceiveToken(s)` (92–103)**: reliable delivery transfers token from `Wire` to destination server and resets served flags.
- **`Dispatch(s)` (105–116)**: only server with token may take FIFO head of queue and add job to dispatched set and `printMessages`.
- **`ReceivePrint(p,j)` (118–130)**: only correct target receives job; if ID already seen, ignore duplicate; otherwise add to printer-local FIFO and seen set.
- **`StartPrint(p)` (132–140)**: if printer is idle and its FIFO nonempty, pop head into active slot. No printer has two active jobs.
- **`FinishPrint(p)` (142–151)**: finish active job, increment its `printCount`, add to completed set, clear active slot.
- **`Next` (153–163)**: nondeterministic OR of all the above transitions for possible servers/printers/jobs. TLC explores permitted interleavings.
- **`Spec` (165–172)**: `Init /\ [][Next]_vars` says begin in Init and then repeatedly take permitted transitions (or stuttering). Fairness clauses rule out certain indefinitely postponed continuously enabled actions.

## Safety invariants — lines 174–201

- `TypeOK`: state values stay in defined finite type domains.
- `ExactlyOneToken`: exactly one logical token exists, either at one server or in transit; hence no two server holders.
- `AtMostOnce`: `printCount[j] <= 1` for every modeled job.
- `CompletedWasSubmitted`: no phantom completed job.
- `CorrectTarget`: pending/active job always at its fixed assigned printer.

## Liveness — lines 203–204

`EverySubmittedFinishes`: whenever a job is in `submitted`, it will **eventually** be in `completed` (`~>`). This conclusion depends on reliable delivery and fairness; it is not guaranteed under permanent message loss.

## TLC configuration

`PrintToken.cfg` names `Spec`, disables deadlock checking for this transition system, includes the five invariants and `EverySubmittedFinishes` as PROPERTY. `README.md` records 1,680 distinct states from an earlier TLC run, but I have **not rerun** it here.

## Lecturer-ready summary

“This TLA+ model abstracts the same protocol into finite sets of servers, printers and jobs. TLC explores all transitions it can generate, checking that the token is never duplicated, jobs cannot be printed twice, and—with fairness and reliable delivery—submitted jobs eventually finish.”


---

<!-- FILE: 08_PRINTTOKENLOSS_TLA.md -->

# `spec/PrintTokenLoss.tla` explained for a Java developer

**Actual source:** 229 lines. This is the **failure experiment**, not the retry-recovery solution. It extends the reliable 2-server / 3-printer / 3-job model with a permanently **lost token-transfer message**.

## What is reused from `PrintToken.tla`?

The same `Submit`, `RequestToken`, `GrantToken`, `ReceiveToken`, `Dispatch`, `ReceivePrint`, `StartPrint`, `FinishPrint`, as well as fixed `Target` map and normal state fields. Read `07_PRINTTOKEN_TLA.md` for every common function. The important changes are:

- New symbolic state `Lost == "lost"` (line 12). In Java, imagine an enum `TokenLocation {S1,S2,IN_TRANSIT,LOST}`.
- `tokenAt` may become `Lost` and never recover without a new recovery action.
- **`DropToken` (lines 108–115)**: if `tokenAt = Wire`, transition to `Lost`, clear destination, and leave everything else unchanged. This simulates irrecoverable loss of the unique token.
- `Next` now includes `DropToken` as one possible action (lines 165–176).
- `TypeOK` includes `Lost` in the legal locations (lines 187–201).

## What properties mean under permanent loss

- `AtMostOneOwner`: no more than one server claims ownership (safety).
- `AtMostOneToken`: no more than one token exists, including in transit (safety).
- `AtMostOnce`, `CompletedWasSubmitted`, `CorrectTarget`: printing safety conditions may remain valid.
- **`ExactlyOneToken` is intentionally NOT invariant here**: after loss there are **zero** tokens. Do not claim the token survives permanent loss.
- **`EverySubmittedFinishes` can fail**: jobs waiting for a token may be stuck forever. Fairness cannot cause a disabled dispatch to execute.

## Two configuration files / experiments

1. `PrintTokenLoss.cfg`: check **safety only**, expected to pass if the model is correct.
2. `PrintTokenLoss_liveness.cfg`: adds `PROPERTY EverySubmittedFinishes`; intended to show a liveness counterexample where the token is lost and pending work never finishes.

The expected liveness violation is not a code bug; it's the **purpose of the experiment**. A liveness failure is not evidence of mutual-exclusion failure.

## Link to the real Elixir project

This abstract loss model is *not* the newest retry-enabled runtime. Your Elixir `server.ex` retries the same transfer ID on a timer, and `PrintTokenRetry.tla` is the separate small recovery abstraction. Explain all three models as a progression: reliable protocol → permanent-drop weakness → finite-drop recovery design.


---

<!-- FILE: 09_PRINTTOKENRETRY_TLA.md -->

# `spec/PrintTokenRetry.tla` explained for a Java developer

**Actual source:** 257 lines. This is a *bounded recovery scenario*, not a line-by-line translation or complete refinement proof of the Elixir source.

**Very important scope**: **two servers, one printer, two jobs (J1 at S1 and J2 at S2), one token handoff S1→S2**. The original reliable model covers 3 printers and arbitrary client-submission ordering; this one concentrates on loss of request, grant, ACK, print and completion notifications. Each loss type has an initial budget of 1.

## State fields — lines 14–31

Think of a `ModelState` Java record with:

- `owner`: `"S1"`, `"S2"`, or `None` while sending token; S1 initially owns.
- `requestWire`, `requestSeen`: whether token request is in flight / delivered.
- `transferPending`, `grantWire`, `grantSeen`: sender waiting for token acknowledgment; grant in flight; grant already accepted.
- `ackWire`, `ackSeen`: token ACK in flight / received.
- `dispatched`: jobs dispatched by original server.
- `printWire`: job messages in flight to printer.
- `printerSeen`, `printerQueue`, `active`: printer dedup memory, pending FIFO and active print.
- `completed`: jobs physically printed; `completionWire`: printer notifications en route; `confirmed`: original server received notice.
- `printCount`: per-job number of times printer finished the job.
- `dropRequest`, `dropGrant`, `dropTokenAck`, `dropPrint`, `dropCompletion`: finite counters; each initially 1.

**Terminology mismatch to notice**: in *this formal model* `completed` means physically finished and `confirmed` means server received notice. In `server.ex` the `state.completed` set means the server received `:printed`. This is an abstraction, not identical fields.

## `Init` — lines 33–55

All message flags false, no dispatched/printed jobs, empty printer queue and no active job; S1 owns token; each loss budget = 1. Unlike the original model, both jobs are assumed submitted already.

## All transition actions — lines 58–179

1. **`SendRequest` (58–62)**: if request not delivered and no request currently in flight, place request on wire. Retry is represented by repeating this action after a drop.
2. **`DropRequest` (64–69)**: when request in flight and loss budget positive, remove it and consume one budget unit.
3. **`ReceiveRequest` (71–75)**: S1 receives request and records `requestSeen = TRUE`.
4. **`Dispatch(j)` (77–82)**: job may dispatch only when its originating server equals `owner`, and only once. This is dispatch authorization, not printer work.
5. **`GrantToken` (84–92)**: after S1 knows request and has dispatched J1, relinquish token to `None`, mark handoff pending, send grant.
6. **`DropGrant` (94–99)**: suppress one token-grant transmission.
7. **`RetryGrant` (101–106)**: pending handoff with no wire copy and no ACK allows retransmitting the same grant.
8. **`ReceiveGrant` (108–114)**: S2 accepts grant if first time (`grantSeen` false), otherwise only re-ACKs. This prevents replayed grants from creating another owner.
9. **`DropAck` (116–121)**: drop in-flight token ACK and consume finite budget.
10. **`ReceiveAck` (123–128)**: S1 records grant ACK, clears transferPending. It does **not** regain the token; S2 owns it.
11. **`SendPrint(j)` (130–136)**: for a dispatched but not server-confirmed job, make a print message in flight; may be repeated after loss.
12. **`DropPrint(j)` (138–143)**: suppress one print message.
13. **`ReceivePrint(j)` (145–151)**: printer remembers ID, appends only if new. If already in physically `completed`, it places another completion notification on wire, not a new queued print.
14. **`StartPrint` (153–158)**: if no active job and FIFO nonempty, move head to active slot.
15. **`FinishPrint` (160–166)**: mark active job physically completed, increment print count and create outgoing completion notice.
16. **`DropCompletion(j)` (168–173)**: drop a notification on wire, consume finite budget.
17. **`ReceiveCompletion(j)` (175–179)**: original server receives notification; add job to `confirmed`, so future resend is unnecessary.

Read `Next` (180–197) as a nondeterministic choice among **all** those operations. In Java, imagine a model checker repeatedly choosing any enabled `Transition` instead of executing one particular deterministic thread interleaving.

## Fairness and properties — lines 199–255

**`Spec` (202–214)**: initial state, temporal transition relation and weak-fairness assumptions for required retry/delivery/processing actions. Dropping messages is not obligatory; budget makes repeated loss finite.

**`TypeOK` (216–238)**: ensures fields remain within expected sets, booleans and integer ranges.

**`ExactlyOneLogicalToken` (242–244)**: either a server owns token, or the sender is holding an *unusable escrowed* transfer before receiver gets it. Total logical token remains 1.

**`SenderNeverUsesPendingToken` (246)**: S1 cannot dispatch while its token transfer is pending.

**`AtMostOnce` (247)**: printer may not complete one job twice.

**`NoPhantomCompletion` (248)**: `completed` is subset of `dispatched`.

**`NoDuplicateQueue` (249)**: printer FIFO contains no repeated IDs.

**`SingleActivePrinter` (250)**: `active` is either a valid job or `None`. Note this predicate is defined but **not separately listed** in `PrintTokenRetry.cfg`; `TypeOK` already checks this field's domain.

**`EveryJobFinishes` (254)**: each job eventually physically prints.

**`EveryCompletionAcknowledged` (255)**: each job's completion notice eventually reaches its origin server. Despite this property's name, it checks `confirmed`, **not** a separate completion-ACK message. Elixir doesn't implement a printer-directed completion ACK.

## Status, model fidelity, and limits

The archive's `spec/RETRY_MODEL_GUIDE.md` explicitly says this new recovery model was **not run through TLC in the authoring environment**. Do not claim it passed until you actually run `PrintTokenRetry.cfg` and save TLC result.

The simplified model does not cover three printer nodes, repeated token returns, new jobs after startup, crashes, persistent partitions, or refinement checking. Its purpose is to show a tractable recovery *scenario* under finite loss and fairness, complementary to the original 3-printer reliable TLA+ model.


---

<!-- FILE: 10_TLC_CONFIGS.md -->

# All `spec/*.cfg` files explained for a Java developer

A TLA+ `.tla` file contains state definitions, transitions and properties. A TLC `.cfg` file says **which specification and assertions TLC should check**. Think a *test run configuration* rather than Java program logic.

`SPECIFICATION Spec` = use the `Spec` operator as the system behavior. `INVARIANT Name` = a safety predicate that must hold in every reachable state. `PROPERTY Name` = temporal property (e.g. eventual completion) that must hold over behaviors. `CHECK_DEADLOCK FALSE` = do not report the system's intentional stuttering/terminal behavior as a deadlock; it **does not** disable invariant/property checking.

## `PrintToken.cfg`

- `SPECIFICATION Spec`.
- Five safety checks: `TypeOK`, `ExactlyOneToken`, `AtMostOnce`, `CompletedWasSubmitted`, `CorrectTarget`.
- One liveness check: `EverySubmittedFinishes`.

## `PrintTokenLoss.cfg`

- `SPECIFICATION Spec`.
- Six safety checks: `TypeOK`, `AtMostOneOwner`, `AtMostOneToken`, `AtMostOnce`, `CompletedWasSubmitted`, `CorrectTarget`.
- **No liveness property**; intended safety experiment with permanently lost token.

## `PrintTokenLoss_liveness.cfg`

- Same six safety invariants as `PrintTokenLoss.cfg`.
- Adds `PROPERTY EverySubmittedFinishes`. Counterexample is intentional: permanent loss can block pending jobs.

## `PrintTokenRetry.cfg`

- Invariants: `TypeOK`, `ExactlyOneLogicalToken`, `SenderNeverUsesPendingToken`, `AtMostOnce`, `NoPhantomCompletion`, `NoDuplicateQueue`.
- Properties: `EveryJobFinishes`, `EveryCompletionAcknowledged`.
- Bounded recovery model with **one printer and two jobs**, not full implementation.

## Typical TLC invocation (from `spec/`)

```bash
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintToken.cfg PrintToken.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenLoss.cfg PrintTokenLoss.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenLoss_liveness.cfg PrintTokenLoss.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenRetry.cfg PrintTokenRetry.tla
```

For your defense distinguish *expected* results from actually run results. `README.md` reports an earlier successful `PrintToken` check; the new retry model was not verified in the authoring environment. No TLC run has been performed while preparing these guides.


---

<!-- FILE: 11_README_AND_DEFENSE.md -->

# Project documentation files and run instructions explained

These markdown files are **documentation**, not executable modules: `README.md`, `DEFENSE_GUIDE.md`, `spec/MESSAGE_LOSS_GUIDE.md`, and `spec/RETRY_MODEL_GUIDE.md`.

## `README.md`

The project's setup guide. It explains architectural goals and constraints; five remote node terminal commands; tests; and TLC commands. Its 2-server + 3-printer diagram shows **both servers can address all three printers**. The token controls dispatch permission, not printer execution. It distinguishes finite temporary message loss from permanent partition/crash. The README's description of test and model outcomes should be verified against actual terminal logs before claiming successful runs.

## `DEFENSE_GUIDE.md`

An oral defense script and conceptual explanations. Use it to practice structure: problem statement, actor architecture, message sequence, token safety, FIFO printing, tests, formal properties and limitations. Match explanations to the actual `server.ex` and `printer.ex` in the ZIP. In particular, the completion path uses printer `:printed`, not a separate server `COMPLETION_ACK`.

## `spec/MESSAGE_LOSS_GUIDE.md`

A comparison of the reliable protocol against irrecoverable **lost-token** behavior: safety can survive but liveness fails. Corresponds primarily to `PrintTokenLoss.tla` and two loss `.cfg` files. This documents a *negative experiment*, not a proof of recovery.

## `spec/RETRY_MODEL_GUIDE.md`

Documentation of finite loss/timeout recovery modeled in `PrintTokenRetry.tla`. Scope is **one printer, two jobs and one token handoff**. Explicitly states that the new model was not executed through TLC in the author's container. You should run it and capture results if you want to claim verification.

## Run local demo / tests

From the project root:

```bash
mix compile
mix test
mix run -e 'DistributedPrint.Demo.run()'
```

The 4 local ExUnit tests run under `mix test` while the distributed tests are excluded by default.

## Run genuine distributed five-node experiment

Open five terminals, from the project root, all with the same cookie:

```bash
elixir --sname s1 --cookie printlab -S mix run --no-halt
elixir --sname s2 --cookie printlab -S mix run --no-halt
elixir --sname p1 --cookie printlab -S mix run --no-halt
elixir --sname p2 --cookie printlab -S mix run --no-halt
elixir --sname p3 --cookie printlab -S mix run --no-halt
```

Then from a **sixth** terminal:

```bash
elixir --sname test --cookie printlab -S mix test --include distributed test/distributed_test.exs
```

The test creates actors remotely using `:rpc.call`. After changing Elixir source, **restart all five nodes** so they do not retain old compiled modules in memory. The nodes' host names must resolve and the Erlang cookie must match.

## Key limitations to tell the lecturer

- Print content is simulated by a job map / completion timer; not a real PDF printer driver.
- Queues, seen ID sets, and token handoff state exist only in process memory. No persistence or restart recovery.
- Temporary *finite* outgoing-message drops are injected deliberately. No actual network partitions or randomized transport loss are needed for tests.
- Java comparison is a teaching aid, not proof of one-to-one runtime equivalence: Elixir actors are isolated processes, not Java objects sharing memory.


---

<!-- FILE: 12_DEFENSE_QUESTIONS.md -->

# Lecturer questions and short prepared answers

**1. Why is this distributed?** Two server actors on distinct BEAM nodes and three printer actors on three other nodes communicate with messages, without shared application memory. Test controller is a sixth node.

**2. Why two servers?** Both accept jobs independently; a unique token coordinates which may dispatch. This is a design demonstration of distributed mutual exclusion, not a requirement that physical printers share a global lock.

**3. Does the token prevent printers from printing in parallel?** No. It protects **dispatch** only. Printers have separate FIFOs and can be simultaneously active.

**4. Who selects the destination printer?** The client sends a job map with globally unique `id` and selected `printer` ID. The server uses that map to find destination. There is no load balancing algorithm.

**5. What is a GenServer in Java language?** Think of an actor with a mailbox, private state, and message handlers. It's not a Java `Map` or ordinary instance; `GenServer.call` waits for a reply, `cast` does not.

**6. What does `start_link` do compared with `start`?** Both start a GenServer process. `start_link` links it to caller for failure propagation; `start` doesn't. Remote RPC test uses `start` since its worker is temporary.

**7. What does `do:` mean?** Single-expression function body. `defp` is private function. No Java-style return statement is required for last expression.

**8. Is `__MODULE__` equal to Java `this`?** No. It's current **module**, roughly like `Server.class`, not a current object instance.

**9. How do you ensure only one server dispatches?** `drive` checks `has_token` before dispatch; `give_token` sets `has_token=false` **before** sending token. Receiver accepts a transfer ID only once.

**10. What if token request is dropped?** Server without token and with queued work retries its `:token_request` in periodic `:retry` handler.

**11. What if token grant is dropped?** Sender becomes unable to dispatch, records pending transfer and retransmits **same** transfer ID until matching `:token_ack` arrives.

**12. What if token ACK is dropped?** Sender retries same grant; receiver detects remembered transfer ID and ACKs again without taking an extra token.

**13. What if `:print` is dropped?** Job stays in server `in_flight` map. Retry loop resends it with same job ID until `:printed` confirmation.

**14. What if printer's `:printed` is dropped?** Server retries `:print`; printer's `print_counts` says ID was completed, so it **re-sends `:printed` without reprinting**. No separate server-to-printer completion ACK exists.

**15. How is duplicate job ID handled?** A server rejects repeat submissions of IDs it has already seen; each printer suppresses duplicate deliveries of IDs it knows. Global uniqueness is an assumption—not a distributed ID allocator.

**16. What is local vs distributed testing?** `printing_test.exs` uses actors in one VM; `distributed_test.exs` starts actors remotely on 5 other Erlang nodes using `:rpc.call` and checks 9 scenarios.

**17. What do TLA+ and TLC do?** TLA+ specifies possible abstract states/transitions and correctness properties. TLC enumerates reachable states and checks invariants and temporal properties for chosen finite model.

**18. Difference between safety and liveness?** Safety = something bad never happens (two token owners, duplicate print). Liveness = something good eventually happens (every pending job finishes) under delivery/fairness assumptions.

**19. What does `PrintTokenLoss.tla` demonstrate?** Permanent loss of unique token can preserve mutual exclusion while destroying progress. Its liveness counterexample is intentional.

**20. What does `PrintTokenRetry.tla` prove?** It *aims to check* a smaller bounded finite-loss recovery scenario: 2 servers, 1 printer, 2 jobs and 1 token transfer. Do **not** claim TLC passed until an actual run succeeds.

**21. Are exactly-once physical prints guaranteed under crashes?** No. With live actors and remembered job IDs, repeated messages don't cause duplicate simulated printing. A reboot erases deduplication state and the system lacks durable spool/transactions.

**22. Why use `@default_retry_ms`?** Module attribute holding default 60 ms delay; akin to a Java compile-time constant. `Process.send_after` schedules recurring retry messages, not automatic Java-style method callbacks.
