# Lab 1: Controlled token-message loss (TLA+)

This is an **optional, isolated failure experiment**. Do not replace the original `PrintToken.tla` or `PrintToken.cfg`. The original model is the reliable-channel scenario that you already verified successfully.

## What changes?

The new `PrintTokenLoss.tla` is a copy of the original specification with three changes:
1. `Lost == "lost"` is an additional token location.
2. `DropToken` can replace `ReceiveToken` when a granted token is in transit. The sender has already given it up, and the receiver never receives it.
3. The type invariant permits `Lost`. We check **at most one** token owner / token rather than **exactly one** physical token, because after loss there are zero.

All other business actions (submission, token request/grant, dispatch, print receive/start/finish) are preserved from the original model. The same weak fairness assumptions apply to the ordinary actions.

## Run scenario A: safety survives loss (expected PASS)

1. Copy the three files in this folder into your project's `spec/` directory, next to `PrintToken.tla`.
2. Open `PrintTokenLoss.tla` in VS Code.
3. Run `TLA+: Check model with TLC` (default config `PrintTokenLoss.cfg`), with `-workers 1 -coverage 1`.
4. Expected: **no invariant violation**. The model allows a lost token, but can never create two token holders or print a job twice.

The checked invariants are `TypeOK`, `AtMostOneOwner`, `AtMostOneToken`, `AtMostOnce`, `CompletedWasSubmitted`, `CorrectTarget`.

## Run scenario B: progress breaks after loss (expected FAIL)

1. Keep `PrintTokenLoss.tla` open.
2. Run `TLA+: Check model with non-default config...` and select `PrintTokenLoss_liveness.cfg`.
3. This config checks the same safety invariants **and** the temporal property `EverySubmittedFinishes`.
4. Expected: TLC reports a **temporal property violation**, with a counterexample. This is the **intended experimental result**; it is not a syntax error.

If your VS Code extension does not offer non-default config selection, temporarily rename the default `PrintTokenLoss.cfg` to another filename and copy `PrintTokenLoss_liveness.cfg` to `PrintTokenLoss.cfg`; restore the original default afterward.

## Black-board counterexample (possible execution)

1. Client submits job `J2` to `S2`; `S1` initially owns the token.
2. `S2` sends `RequestToken(S2)`.
3. `S1` executes `GrantToken(S1)`: sender loses local ownership; token enters the network (`tokenAt = Wire`).
4. Network executes **`DropToken`** instead of `ReceiveToken(S2)`; `tokenAt = Lost`.
5. `S2` can request again, but there is no token holder to grant it; it can never `Dispatch(S2)`.
6. Infinite stuttering is possible: `J2` remains submitted but never completed.

This violates `EverySubmittedFinishes`. But `AtMostOneOwner`, `AtMostOneToken`, `AtMostOnce`, and `CorrectTarget` still hold. The old property `ExactlyOneToken` is **supposed** to fail: its existence requirement assumes reliable token delivery.

**Safety:** no two servers may dispatch under the same token; no job completes twice. **Liveness:** every submitted job eventually completes; this is not guaranteed after token loss.

## Scope and limits

- The absorbing `DropToken` action is specific to **this older counterexample model**. The new Elixir implementation DOES implement temporary loss injection and retries; see `PrintTokenRetry.tla` for a smaller model of that recovery protocol.
- This is a counterexample to progress, **not** a solution for recovering lost messages.
- It does not model server crashes, printer crashes, acknowledgements, or retries.
- TLC model checking is finite-state model analysis, not a proof that the production system tolerates arbitrary faults.
- The provided model was prepared from your previously passing TLA+ model. TLC execution must be performed on your PC; it was not available in the authoring environment.

## Comparison with retry recovery model

`PrintTokenRetry.tla` and `PrintTokenRetry.cfg` check a different scenario:
message drops are finite (one opportunity per message category), a retry can
be delivered eventually, and token transfers have acknowledgments. In this
model the token is logically held in escrow until accepted; a lost grant
cannot destroy it. The recipient deduplicates the grant if the ACK is lost.
A printer retries completion acknowledgments when it receives a duplicate
print delivery. This new model is intentionally limited to **one token
handoff, two jobs, and one printer** so TLC can explore the full state space.
It does not replace the original three-printer specification.
