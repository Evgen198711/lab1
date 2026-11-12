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
