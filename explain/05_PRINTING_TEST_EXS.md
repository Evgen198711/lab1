# `test/printing_test.exs` explained for a Java developer

**Actual source:** 87 lines; four basic tests. These test multiple GenServer processes inside one BEAM; **not** five remote Erlang VMs. Think JUnit unit/integration tests with assertions and actor futures.

- **1–3**: `use ExUnit.Case, async: false` is analogous to JUnit; `alias` imports shorter module names.
- **5–15, test initial token**: start one printer and two linked servers, with `initial_token: true` only on S1. Assert S1 `has_token`, S2 does not. `assert` and `refute` correspond to JUnit `assertTrue` / `assertFalse`.
- **17–56, test concurrent submissions**: start three printer actors (comprehension `for ... into: %{}` builds map), two server actors, create 18 jobs, asynchronously submit them with `Task.async`, wait via `Task.await_many(5_000)`. Poll until all printed. Verify 18 completed IDs and each print count == 1. Java: `CompletableFuture`, collections and `assertEquals`.
- **58–67, test repeat submission**: submit job ID `repeat-1` twice to same server; first queued, second yields duplicate ID error; printer count remains exactly one.
- **69–75, test duplicate printer delivery**: send two identical `{:print, job, self()}` messages to a printer actor. Printer should suppress repeat physical printing. `self()` is test-process PID, used as originating recipient in test.
- **77–86, `eventually` helper**: bounded retry-based polling: if predicate true return true, else sleep 15 ms and recursively check until attempts exhausted. `defp` means private; multiple function clauses implement base case and recursive case. Java counterpart: Awaitility or a loop with deadline.

**Important precision**: These tests check *specific* scenarios, not every possible interleaving. They do not demonstrate machine-checked correctness; that's the purpose of the separate TLA+ models. The original source defines four tests, but they were not rerun here.
