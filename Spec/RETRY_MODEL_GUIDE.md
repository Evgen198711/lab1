# TLA+ bounded-message-loss recovery model

File: `PrintTokenRetry.tla`  |  Configuration: `PrintTokenRetry.cfg`

## Scope (important for honest claims)

This is a **small recovery abstraction** with two servers, **one** printer,
and **two** jobs already submitted (one per server). It models **a single
handoff from S1 to S2**. It does **not** represent every interleaving of the
full Elixir implementation, which supports returning the token, three
printers and arbitrary new submissions. The older `PrintToken.tla` models
three printers but assumes reliable message delivery.

The point here is to verify safety and conditional progress while the network
is allowed to drop messages a finite number of times.

## State and protocol

- `owner`: server currently allowed to dispatch, or `None` during handoff.
- `transferPending`: the sender has relinquished ownership but can retry.
- `grantSeen`: the receiver has **already accepted this grant ID**.
- `grantWire`: a copy of the token message is in transit.
- `ackWire` / `ackSeen`: token-transfer acknowledgment in transit / received.
- `requestWire` / `requestSeen`: retransmitted request and its receipt.
- `printWire`: outstanding deliveries to the printer.
- `printerSeen`: deduplication memory.
- `printerQueue` / `active`: enforce one physical print at a time.
- `completed` / `completionWire` / `confirmed`: printed jobs, completion
  notices and server confirmations.
- `dropRequest`, `dropGrant`, `dropTokenAck`, `dropPrint`, `dropCompletion`:
  each begins at 1 and decreases when the corresponding message is dropped.
  Thus the model allows **up to one loss of each class of message**, and no
  message can be dropped an unlimited number of times.

## Example trace to draw

1. `S2` requests the token. The first request is lost (`DropRequest`).
2. `SendRequest` repeats; `ReceiveRequest` succeeds.
3. `S1` dispatches its own `J1`, relinquishes the token and sends a grant.
4. The first token grant is lost (`DropGrant`); `RetryGrant` sends another.
5. `S2` receives the token, and sends an acknowledgment. If the ACK is
   dropped, `S1` resends the **same** grant; `S2` re-ACKs without accepting
   another token.
6. `S2` dispatches `J2`. `SendPrint` retries if `DropPrint` occurs.
7. The printer remembers `J2`, prints it once, then sends a completion.
   After `DropCompletion`, a duplicate print delivery causes a *new ACK*,
   not a second print.

## Invariants

- `ExactlyOneLogicalToken`: exactly one logical token exists, either held by
  a server or **in escrow** during a not-yet-received handoff. In contrast,
  the older permanent-drop model loses the token entirely.
- `SenderNeverUsesPendingToken`: S1 cannot dispatch while its transfer is
  still waiting for acknowledgment.
- `AtMostOnce`: every physical `printCount[j] <= 1`.
- `NoPhantomCompletion`: completed jobs were actually dispatched.
- `NoDuplicateQueue`: the private printer queue does not contain duplicates.

## Liveness properties

- `EveryJobFinishes`: both jobs eventually finish printing.
- `EveryCompletionAcknowledged`: their originating servers eventually
  receive confirmation.

Liveness relies on weak fairness for retry, delivery and processing actions,
plus **finite** message-loss budgets. A permanent partition is deliberately
outside the model and cannot be hidden by timeout retries.

## TLC in VS Code

1. Open `PrintTokenRetry.tla`.
2. Run **TLA+: Check model with TLC**. It should select
   `PrintTokenRetry.cfg` automatically.
3. Accept the default options (`-workers 1 -coverage 1`).
4. Confirm both safety and liveness properties complete **without errors**.
5. Capture the final state counts and result for your defense.

Alternatively from `spec/`:

```powershell
java -cp "C:\path\to\tla2tools.jar" tlc2.TLC -config PrintTokenRetry.cfg PrintTokenRetry.tla
```

**Status:** This new model was not run through TLC in the authoring
container. The state counts and outcome must be established by an actual
TLC run before being reported as verified.
