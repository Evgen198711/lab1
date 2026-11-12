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
