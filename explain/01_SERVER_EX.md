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
