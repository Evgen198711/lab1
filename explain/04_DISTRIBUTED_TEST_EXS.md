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
