# Defense guide: Distributed Print Server (Lab 1)

This guide is intended for a **15-minute BLACKBOARD explanation**. The first
lecture specifically asks you to explain the **algorithm and implementation
(how)** and **correctness (why)**, with **no slides and no code shown** during
the blackboard defense (Lecture 1, PDF page 12, slide 10). Use a drawing,
message trace, invariants and concise notes instead.

## 0. What to say first (about 1 minute)

> My topic is a Distributed Print Server. There are two independent server
> nodes, and both can communicate with three printer nodes. Clients submit
> jobs to either server. The problem is how to coordinate the two servers
> without shared memory so that they do not independently dispatch jobs
> as if they each had exclusive access to the shared printer pool. I use a
> single token-passing mutual exclusion algorithm. Only the token holder
> may dispatch, and each printer independently prints one job at a time.

Important: The system is distributed even on one physical computer **if**
servers/printers run as separate Erlang nodes, communicating over distributed
Erlang. Separate GenServer processes within one Erlang node are actor-based,
but alone do not prove separate machine/node distribution.

## 1. Draw the architecture (about 2 minutes)

On the board:

```
CLIENTS:  C1              C2
           |               |
SERVER:   S1 <--token-->  S2
           | \   |     /   |
           |  \  |    /    |
PRINTERS: P1    P2        P3
```

More precisely draw arrows from **both servers to all three printers**.
Label every node as a distinct Erlang node: `s1@host`, `s2@host`,
`p1@host`, `p2@host`, and `p3@host`.

Each server owns a local pending job queue and two local token flags:
`has_token` and `peer_waiting`, plus `outgoing_transfer`,
`received_transfers`, and `in_flight`. Each printer owns a FIFO queue, `active`
job, and a set of `seen` IDs.

A printer is a real state machine:

```
IDLE --receive job--> PRINTING --finish--> IDLE
        |                |
        +-- queue next --+
```

For **one global token**, dispatch decisions are serialized. This is not
necessary for different printers, but deliberately makes Lab 1 simple.

## 2. Explain the algorithm precisely (about 3 minutes)

Initial state:
- S1 owns the only token.
- S2 does not own the token.
- All queues are empty and all printers idle.

Messages between servers:
- `{:token_request, sender}` — I have work and need the token.
- `{:token, sender, transfer_id}` — I am relinquishing the token and transferring it.
- `{:token_ack, sender, transfer_id}` — I received that transfer ID.
- A timer retransmits unacknowledged requests and transfers.

Messages from server to printer:
- `{:print, job, origin}` — put this job into the printer's private queue.

Printer to server:
- `{:printed, job_id, printer_id}` — physical printing finished.

State transitions:
1. Client submits job `j` to server `s`.
2. Server queues the job in its own memory.
3. If it holds the token, it dispatches a job to the target printer.
4. Otherwise it sends a token request to the peer.
5. Peer that owns token eventually sends it, after dispatching at most
   one queued local job if its own queue is nonempty.
6. Sender relinquishes ownership; the token is then in transit.
7. Receiver becomes holder **only after** receiving token.
8. The receiver can now dispatch work and can later return the token.
9. Printer enqueues a new job ID once and starts when idle.
10. Printer completes the job and tells the origin server.
11. The server retries print delivery until completion is acknowledged.
12. The printer deduplicates repeat deliveries and re-ACKs finished jobs.

The token can be transferred while the first printer is still physically
printing. This is safe because each printer has its own queue and single
`active` slot. Multiple printers can print at once.

## 3. Draw a real example trace (about 2 minutes)

```
time ->
S1:  has TOKEN    dispatch J1 ------> P1
S2:  queue J2     TOKEN_REQUEST ---> S1
S1:  relinquish   TOKEN ------------> S2
S2:  receives TOKEN, dispatch J2 ---> P2
P1:  J1 printing .......... J1 completed
P2:                  J2 printing ...... J2 completed
```

Explain that `TOKEN_REQUEST` and `TOKEN_GRANT` are **messages**, not direct
changes to another server's memory. Network delivery may be delayed, so
there can be a period when neither server has the token locally because it
is in transit. That is not a safety violation.

Follow-up example: if Server 1 still has local jobs after sending the token,
it requests the token back; the protocol gives the peer its turn.

## 4. TLA+ formal model (about 3 minutes)

TLA+ models the state and all possible relevant transitions.

**State variables:** `tokenAt`, `tokenTo`, `requests`, `serverQueue`, `served`,
`submitted`, `dispatched`, `printMessages`, `printerQueue`, `printerSeen`,
`active`, `completed`, `printCount`.

`Init` defines the initial state. `Next` is a disjunction (OR) of possible
atomic actions: `Submit`, `RequestToken`, `GrantToken`, `ReceiveToken`,
`Dispatch`, `ReceivePrint`, `StartPrint`, `FinishPrint`.

`Spec == Init /\ [][Next]_vars /\ Fairness` says: start in `Init`, execute
zero or more permitted steps, and assume weak fairness for critical actions.

**Safety invariant #1 — one token:**

```
ExactlyOneToken:
    token location is S1, S2, or IN_TRANSIT, exactly one of these.
```

**Safety invariant #2 — at-most-once printing:**

```
AtMostOnce == FOR EVERY job j: printCount[j] <= 1
```

**Safety invariant #3 — no phantom print:**

```
CompletedWasSubmitted == completed SUBSET_OF submitted
```

**Safety invariant #4 — target integrity:**

```
CorrectTarget: a job is queued/printed only at its target printer.
```

**Liveness property — conditional progress:**

```
EverySubmittedFinishes:
    for every j, 'j was submitted' LEADS_TO 'j completed'.
```

TLA temporal symbols to explain:
- `[] P`: **always** P.
- `<> P`: **eventually** P.
- `P ~> Q`: whenever P becomes true, Q eventually becomes true.
- `P'`: a variable/value in the **next** state.
- `/\`: logical AND.
- `\/`: logical OR.
- `UNCHANGED x`: the action does not modify `x`.
- `WF_vars(Action)`: an action that remains enabled cannot be ignored forever.

TLC **model checking** explores a bounded state space (in this project, 2
servers, 3 printers, 3 jobs) and searches for counterexamples. It is **not** a
mathematical proof for unbounded numbers of servers, jobs, or arbitrary
network failures. Report actual successful TLC output only after executing it.

## 5. Why does it work? A clear correctness argument (about 2 minutes)

### Token safety by induction

1. Base case: `Init` creates exactly one token, initially at S1.
2. `Submit`, `RequestToken`, `Dispatch`, and printer actions never create
   or delete a token.
3. `GrantToken` atomically moves the token from S1/S2 to `in_transit`.
4. `ReceiveToken` atomically moves the token from `in_transit` to S1/S2.
5. Therefore no reachable state has two simultaneous token holders.
6. `Dispatch` requires the server to hold the token. Therefore dispatch
   operations by the two servers cannot overlap as critical sections.

This is an *inductive argument*. It explains WHY the invariant holds.

### Printer exclusivity

Each printer is a single GenServer process with a single `active` slot. When
`active != nil`, further jobs are queued but not started. Only after finishing
the active job can it start another one. Hence a printer never prints two
jobs at once, even if multiple messages arrive quickly.

### At-most-once IDs

For every printer, `seen` remembers IDs. An arriving job is accepted only if
its ID has not been seen before. It is added to `seen` **before** queuing.
Consequently, duplicate delivery of that ID to the same printer does not
cause a second print. Global unique-ID and immutable-target assumptions
prevent a user from deliberately reusing the same ID on another printer.

### Liveness with assumptions

If a server has pending jobs and lacks a token, it requests one. The holder
will pass it after serving at most one local job. If temporarily dropped messages are retried and eventually delivered,
and both nodes continue taking steps, the requester receives a turn.
The server similarly retries print messages until completion is confirmed.
Permanent partitions, node crashes, and lack of scheduling fairness can
still prevent progress.

## 6. Implementation: map Elixir to Java (about 1 minute)

| Elixir/OTP | Comparable Java concept | Crucial difference |
|---|---|---|
| `GenServer` | Stateful service / single-threaded actor | Processes have private state and mailboxes |
| `GenServer.call` | Request-response call, e.g. `CompletableFuture` waiting | It sends a message and waits for a reply |
| `GenServer.cast` | Asynchronous command | No application-level reply is guaranteed |
| `handle_call` | Request handler | Replies with `{:reply, result, new_state}` |
| `handle_cast` | Fire-and-forget message handler | Returns `{:noreply, new_state}` |
| `handle_info` | Timer/event handler | Handles ordinary VM/process messages |
| `:queue` | `ArrayDeque` | Immutable/persistent queue representation |
| `MapSet` | `HashSet` | Immutable value returned after each update |
| Erlang node | Separate JVM/OS process over a network (roughly) | Hosts many lightweight actors |
| `self()` | Current actor's PID | PID is not a Java `Thread` object |

`GenServer` processes one incoming message at a time. A callback returns an
updated **immutable** state; it does not mutate shared fields. Actors on
separate Erlang nodes communicate via distribution messages.

## 7. Conclude (about 1 minute)

> I implemented a small distributed print scheduler with two print-server
> nodes and three printer nodes. The coordination algorithm is token passing.
> I modelled its state transitions and safety/liveness properties in TLA+,
> and prepared nine five-node distributed Elixir tests, including
> deterministic temporary message-loss cases. The improved version retries
> messages with acknowledgments and deduplication while assuming no process
> crashes and eventual delivery of retries. Durable crash recovery,
> replication, or failure detection remain future extensions.

---

# Likely lecturer questions and answers

**Q1. Why is this a distributed system and not just parallel threads?**

A: The servers and printers run as distinct Erlang nodes and exchange
messages. They share no application memory. Each has only its local state;
it cannot immediately read the peer's queue or token variable.

**Q2. Why does token passing prevent simultaneous dispatch?**

A: Only the holder may enter the dispatch critical section. A transfer moves
ownership from the sender to the network, then to the receiver. Because
there is exactly one token, both cannot hold permission simultaneously.

**Q3. Why not use Java `synchronized`, a mutex, or a database lock?**

A: `synchronized` protects memory in a JVM, not memory on a different
machine. The exercise is about coordination over message passing. A shared
database/lock service would move coordination into another component and
obscure the distributed algorithm being studied.

**Q4. Can both printers work concurrently if only one token exists?**

A: Yes. The token controls *dispatch*, not printing. After P1 receives its
job, it works independently. Meanwhile the token can move and another
server can dispatch to P2.

**Q5. What if both clients submit at the same instant?**

A: Both server queues can receive work concurrently. But only the token
holder dispatches. The non-holder sends a token request; eventually both
get turns. Each printer serializes its own queue.

**Q6. What if the token message is delayed?**

A: Neither server can use the token while it is in transit. Progress waits,
but safety holds under the model's assumption that the message eventually
arrives.

**Q7. What if the token message is permanently lost?**

A: The **improved version handles temporary loss**: the sender keeps a
pending transfer and repeatedly sends the same transfer ID until an ACK
arrives. It cannot dispatch while the transfer is outstanding. The receiver
accepts each transfer ID only once and ACKs duplicates without generating
another token. If all future messages are lost (permanent partition),
progress cannot be guaranteed. A timeout must NEVER create a new token.

**Q8. What if Server 1 crashes?**

A: Crash/recovery is explicitly outside Lab 1. A server holding the token
could halt the whole scheduler. A later lab could introduce failure
detection, replicated state, and carefully designed token recovery or a
quorum-based leader. With exactly two servers, a network partition creates
a fundamental safety-versus-availability trade-off.

**Q9. Does `Supervisor` solve lost token or restore job queues?**

A: No. It can restart a crashed local process, but an in-memory queue and
token state are not automatically restored across a crash. Persistence and
state-recovery protocols would still be required. Do not confuse process
restart with full distributed fault tolerance.

**Q10. What exactly does TLC prove?**

A: It exhaustively checks finite configurations against declared invariants
and temporal properties, under the model's assumptions. It cannot prove
that my Elixir source has no implementation bugs, nor can a finite model
by itself establish a general unbounded theorem.

**Q11. How can jobs be printed twice?**

A: Without deduplication, a repeated `:print` message could enter the same
printer queue twice. We keep a `seen` set of job IDs. The guarantee is
conditional on stable in-memory state and a globally unique immutable job
identity. Restart/persistence and cross-target duplicate IDs are outside
the current model.

**Q12. Why not simply let both servers access any printer concurrently?**

A: The printer actor itself could serialize its own queue, and that would
indeed be a simpler design without server mutual exclusion. However, the
assignment explicitly requires a meaningful inter-server coordination
algorithm. Using a token deliberately demonstrates mutual exclusion and
message passing, although it does serialize dispatch unnecessarily.

**Q13. Is there a bottleneck?**

A: Yes: only one token means one server can dispatch at a time. For this
small teaching example, that is intentional. Later it could be improved
with one token per printer so independent devices are scheduled in parallel.

**Q14. Why call this a token protocol rather than consensus?**

A: It is distributed mutual exclusion, not distributed consensus. The two
servers coordinate possession of a unique permission. They do not agree
on an arbitrary replicated value under crash failures.

**Q15. How do you know every submitted job finishes?**

A: This is a liveness property, not a safety invariant. The improved
algorithm permits some lost messages, but needs **eventual delivery of retries**,
non-crashing nodes, eventual processing, and weak scheduling fairness.
If all retries are lost forever, safety may still hold while liveness fails.

---

# Relation to your uploaded course sources

- **Lecture 1, pages 3–4:** core learning outcomes and the formal-methods
  topics; Lab 1 scope (PDF page 8).
- **Lecture 1, PDF page 12:** blackboard defense: explain the algorithm,
  implementation, and correctness; no slides/code.
- **Lecture 1, pages 20–26:** distributed entities communicate through
  messages, concurrency, missing global clock, independent failures.
- **Lecture 1, pages 41–53:** failure models; we exclude crashes and permanent partitions, but test temporary loss.
- **Lecture 2, PDF pages 3–5:** `receive`, request/reply correlation,
  `GenServer.call`, `GenServer.cast`, state in an actor.
- **Lecture 2, page 7:** supervision and the distinction between process
  restart and state recovery.
- **Gilbert & Lynch (2012), pages 1–3:** safety/liveness and CAP; relevant
  mainly to explaining why a network partition cannot be ignored.
- **Michel Raynal (2018), preface and Chapter 1:** asynchronous message
  passing, partial knowledge, uncertainty, formal algorithmic reasoning.
- **Lecture 3:** clocks, causal order and distributed snapshots are reserved
  for the next lab; our first design **does not require logical clocks**.
- **The example locker defense:** useful for how to discuss message traces,
  state transitions, assumptions, and the implications of missing replies.
  Its specific locker-recovery logic is not copied into this design.

# Before submission

- [ ] Compile the Elixir project and correct any environment-specific issues.
- [ ] Run `mix test` for basic and concurrent tests.
- [ ] Run the 5-node test and capture real results.
- [ ] Run TLC with `PrintToken.cfg` and capture actual model-checker output.
- [ ] Draw the architecture and one token-transfer trace from memory.
- [ ] Explain safety vs liveness, finite omission failures, and crash limits.
- [ ] Explain why no token can be duplicated and why no printer prints two
      jobs simultaneously.
- [ ] Describe the limitations of the finite TLC model and the runtime.


# Message-loss recovery: 3-minute extension for defense

## Five failure scenarios

| Lost outgoing message | Recovery | Duplicate safety |
|---|---|---|
| `:token_request` | Waiting server resends on its timer | Repeated requests only set `peer_waiting` |
| `:token` | Sender resends the *same* transfer ID | Receiver's `received_transfers` prevents accepting a duplicate token |
| `:token_ack` | Grant retransmission causes a fresh ACK | Sender does not reclaim the token from a timeout |
| `:print` | Server keeps `in_flight` and resends job ID | Printer's `seen` set prevents duplicate physical print |
| `:printed` | Server resends `:print`; finished printer replies again | `print_counts` remains 1 for that ID |

## Blackboard counterexample and repaired trace

Without recovery: `S1 --TOKEN--> X (lost)`; S1 relinquishes ownership,
S2 has no token, so S2's job may never finish.

With recovery:

```
S2 -> S1 : TOKEN_REQUEST              (first one lost)
S2 -> S1 : TOKEN_REQUEST [retry]      (delivered)
S1 -> S2 : TOKEN(transfer_id={s1,1}) (first one lost)
S1 -> S2 : TOKEN(transfer_id={s1,1}) [retry]
S2 accepts token ONCE
S2 -> S1 : TOKEN_ACK({s1,1})         (lost)
S1 -> S2 : TOKEN({s1,1}) [retry]
S2 detects duplicate; resends ACK, does not create a new token
S2 -> P1 : PRINT(job_id=J2)          (first one lost)
S2 -> P1 : PRINT(J2) [retry]
P1 prints J2 exactly once
P1 -> S2 : PRINTED(J2)                (lost)
S2 -> P1 : PRINT(J2) [retry]
P1 -> S2 : PRINTED(J2) [repeat ACK, no second print]
```

**Safety argument:** S1 clears `has_token` before its first grant; it
never reclaims ownership because an ACK is missing. Receiving the same
transfer ID again cannot increase the number of logical token owners.
The printer marks a job ID as seen before queuing; after finishing, it
acknowledges duplicates without printing them again.

**Liveness argument:** as long as every outstanding message is retried,
each required message is eventually delivered, the nodes stay alive,
and processing is fair, the job can make progress. There is **no
liveness guarantee** under a permanent partition or server crash.

## Formal verification clarification

`PrintToken.tla` is the original reliable communication, 2-server / 3-printer
model. `PrintTokenLoss.tla` intentionally breaks liveness when a token is
permanently dropped. `PrintTokenRetry.tla` is a narrower model proving
properties about one token handoff, bounded loss, retransmission and printer
acknowledgments. TLC success for any of these does NOT prove the Elixir
implementation exactly matches the formal model.
