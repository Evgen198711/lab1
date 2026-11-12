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
