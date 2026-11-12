# Distributed Print Server — Laboratory Work 1

**Topic:** Distributed print scheduling by token-passing mutual exclusion  
**Language:** Elixir/OTP  
**Formal language:** TLA+  
**Runtime topology:** Two print-server Erlang nodes and three printer Erlang nodes.

## Problem

Both servers can access any of three printers. Independent client requests can
arrive at either server concurrently. We must coordinate dispatching, without
shared memory, and ensure that one printer never starts two jobs at once.

The first lab uses **one global logical token**:

- Server `s1` initially holds the token.
- A server may dispatch print jobs **only** when it holds the token.
- A server without the token sends a `TOKEN_REQUEST` to its peer.
- When the token holder receives that request, it dispatches at most one queued
  local job before sending `TOKEN_GRANT` to the peer.
- The sender relinquishes the token as part of the transfer; the peer can use
  it only after receipt.
- Each printer manages its own FIFO queue, prints at most one job at a time,
  and records seen IDs to ignore duplicate deliveries.
- Different printers may print concurrently. The token protects **dispatch**,
  not the entire physical print duration.

## Architecture

```
 Client A                  Client B
    |                         |
    v                         v
 Server s1 <---TOKEN---> Server s2
      \                       /
       +-----> Printer p1 <--+
       +-----> Printer p2 <--+
       +-----> Printer p3 <--+
```

Network communication is asynchronous actor-message passing. No shared-memory
lock is used across server nodes.

## Assumptions and guarantees (including temporary message loss)

1. Exactly one server initially owns the token; servers and printers do **not crash**.
2. Each job ID is globally unique and permanently associated with one printer.
3. Messages may be **dropped a finite number of times**, delayed and duplicated.
   The retry-based progress guarantee assumes that when a message is repeatedly
   sent, a copy is **eventually delivered**, and the nodes and printers keep
   executing (fair scheduling). Permanent partitions are not supported.
4. A sender that transfers a token becomes unable to dispatch immediately.
   It retries the **same transfer ID** until the recipient acknowledges it.
   The recipient deduplicates grants, including retransmissions after it has
   returned the token. Lost acknowledgments never authorize token recreation.
5. Token requests are periodically retried while jobs remain queued.
6. A server keeps each dispatched job in `in_flight` and retries its print
   message until the printer notifies completion. The printer remembers printed
   IDs and can repeat completion notifications without physically reprinting.
7. Job and token state live **only in memory**: restarting a process, a real
   network split, and exactly-once *physical* output after printer failure
   are outside this lab's guarantee.

The fault injector `drop_first: %{message_kind: count}` deterministically
suppresses the first *count* sends of that message type by a specific actor.
It models temporary omission failures, not packet-level corruption or a
complete distributed Erlang network partition.

## Project files

- `lib/distributed_print/server.ex` — server actor, job queue, token protocol.
- `lib/distributed_print/printer.ex` — printer actor, FIFO processing, dedup.
- `lib/distributed_print/demo.ex` — single-VM demonstration.
- `test/printing_test.exs` — automated basic/concurrency/idempotency tests.
- `test/distributed_test.exs` — **nine automated five-node distributed** tests.
- `spec/PrintToken.tla` — abstract TLA+ specification.
- `spec/PrintToken.cfg` — TLC configuration (safety + liveness properties).
- `DEFENSE_GUIDE.md` — 15-minute blackboard defense and detailed explanation.

## 1. Install

Install Elixir 1.15+ and Erlang/OTP (prefer a recent supported release).
Install a Java runtime and the official `tla2tools.jar` package to run TLC.
No third-party Mix dependencies are required.

From the project directory:

```bash
mix compile
mix test
```

## 2. Run the fast single-VM simulation

```bash
mix run -e 'DistributedPrint.Demo.run()'
```

This is useful for debugging but **does not prove distribution**: all actors
are running on one BEAM virtual machine. Use the 5-node test for the defense.

## 3. Start the true 5-node distributed simulation

Open **five terminals** on the same physical computer, in the project folder.
Use the same Erlang cookie on all nodes:

```bash
elixir --sname s1 --cookie printlab -S mix run --no-halt
elixir --sname s2 --cookie printlab -S mix run --no-halt
elixir --sname p1 --cookie printlab -S mix run --no-halt
elixir --sname p2 --cookie printlab -S mix run --no-halt
elixir --sname p3 --cookie printlab -S mix run --no-halt
```

**Run each line in a separate terminal.** The five instances must use the
same hostname resolution and cookie. The app only boots; the automated
integration test below remotely starts a server/printer process on each node.

**Important after updating the code:** stop all five old Erlang nodes
(`Ctrl+C` twice in each PowerShell terminal), then restart them. Otherwise
remote nodes keep the OLD modules in memory and your new tests will call
old server/printer code. Once restarted, open a **sixth terminal** for the
controller:

```bash
elixir --sname test --cookie printlab -S mix test --include distributed test/distributed_test.exs
```

The suite connects to all 5 Erlang nodes, starts fresh remote actors per test
using `:rpc.call`, and checks nine behaviors:

1. **Concurrent submissions:** 12 jobs across both servers, all printed once.
2. **Token handover:** the token passes from Server 1 to Server 2 and back.
3. **Printer serialization:** a second job waits while the same printer is busy.
4. **Duplicate suppression:** a server rejects a repeated ID and a printer ignores
   a duplicate delivery of the same job.

5. **Lost request:** server resends token requests.
6. **Lost grant:** sender retries an immutable transfer ID.
7. **Lost grant ACK:** receiver deduplicates old grants while token returns.
8. **Lost print message:** server retries pending dispatches.
9. **Lost completion:** printer repeats completion upon duplicate print.

Tests use unique registered process names and stop their own actors after
completion to prevent state leakage between tests. Run all nine with the
`--include distributed` command above. The standard `mix test` command
continues to skip distributed tests.

**Remote startup detail:** The remote RPC worker is temporary. The test uses
`Printer.start/1` and `Server.start/1` (unlinked `GenServer.start`) instead of
`start_link/1`, which is linked to the caller and can terminate when the RPC
worker exits. Regular local tests continue to use `start_link/1`. For a
production-style application, remote actors should instead be children of
long-lived supervisors on their respective nodes.

If node discovery fails, check local DNS/hostname resolution, firewall,
Erlang distribution ports, and the cookie. Windows PowerShell can launch
separate terminal sessions with equivalent commands.

## 4. Run the TLA+ model checker

From the `spec/` directory (with `tla2tools.jar` available):

```bash
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintToken.cfg PrintToken.tla
```

The finite model contains exactly **two servers**, **three printers**, and
**three jobs**. TLA+ can choose which server receives each job and explore
asynchronous interleavings of token requests, grants, printer delivery,
printing starts and finishes.

Safety invariants to check:

- `TypeOK`: values stay within intended types.
- `ExactlyOneToken`: token is at one server or in flight, not duplicated.
- `AtMostOnce`: no job ID is printed twice.
- `CompletedWasSubmitted`: printers do not complete nonexistent jobs.
- `CorrectTarget`: each job is handled only by its designated printer.

Liveness property (conditional on fairness and reliable delivery):

- `EverySubmittedFinishes`: every submitted job eventually completes.

### TLC models and configurations

Use VS Code TLA+ extension or run these from `spec/`:

```bash
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintToken.cfg PrintToken.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenLoss.cfg PrintTokenLoss.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenLoss_liveness.cfg PrintTokenLoss.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenRetry.cfg PrintTokenRetry.tla
```

- `PrintToken`: original reliable-message model, 2 servers, 3 printers,
  3 jobs. You already verified it with TLC (1,680 distinct states).
- `PrintTokenLoss`: models a permanently lost token, no retry; safety should
  pass but liveness should produce an **intentional counterexample**.
- `PrintTokenRetry`: a **smaller finite recovery scenario**, 2 servers, **1
  printer**, 2 jobs, **one** token handoff. It models drops, retries,
  acknowledgments and print deduplication. Safety and liveness are to be
  checked under its finite-drop and weak-fairness assumptions. This is an
  abstraction for reasoning, **not** a machine-checked refinement proof of
  the complete Elixir implementation.

**Execution status:** Your prior project passed four local and four
five-node distributed tests, and the original and lossy-safety TLC checks.
The newly changed Elixir code, five extra tests, and new `PrintTokenRetry`
model have NOT been run in the authoring environment. Verify them on your
computer and retain the actual results.

## 5. Tests to demonstrate on the blackboard

1. Server 1 has the token, Server 2 does not.
2. Both servers receive jobs concurrently.
3. Server 2 sends a token request.
4. Server 1 relinquishes its token and Server 2 receives it.
5. Both servers can dispatch jobs over time, but never simultaneously.
6. Multiple printers can be printing at the same time.
7. A repeated message with the same job ID is ignored by the printer.
8. A dropped token grant is retransmitted under the same transfer ID.
9. A dropped print notification triggers another print-message retry, not reprinting.
10. A crashed node or permanently disconnected peer is still **not** supported.

## Why this solution has a realistic limitation

The token is a single coordination resource: this deliberately serializes
**job dispatch** even when jobs target different printers. It makes the
algorithm easy to reason about, but limits throughput. Later you can replace
one global token with **three independent per-printer tokens**, or pursue
fault-tolerant coordination with epochs/quorums. Do not add crash recovery or replication until the first lab is defended.


## Optional: original TLA+ message-loss counterexample

See [`spec/MESSAGE_LOSS_GUIDE.md`](spec/MESSAGE_LOSS_GUIDE.md). This is a separate lossy-token model, with a safety config expected to pass and a liveness config expected to produce an intentional counterexample. The original `PrintToken.tla` and `PrintToken.cfg` remain unchanged.
