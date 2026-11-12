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
