# `spec/PrintTokenLoss.tla` explained for a Java developer

**Actual source:** 229 lines. This is the **failure experiment**, not the retry-recovery solution. It extends the reliable 2-server / 3-printer / 3-job model with a permanently **lost token-transfer message**.

## What is reused from `PrintToken.tla`?

The same `Submit`, `RequestToken`, `GrantToken`, `ReceiveToken`, `Dispatch`, `ReceivePrint`, `StartPrint`, `FinishPrint`, as well as fixed `Target` map and normal state fields. Read `07_PRINTTOKEN_TLA.md` for every common function. The important changes are:

- New symbolic state `Lost == "lost"` (line 12). In Java, imagine an enum `TokenLocation {S1,S2,IN_TRANSIT,LOST}`.
- `tokenAt` may become `Lost` and never recover without a new recovery action.
- **`DropToken` (lines 108–115)**: if `tokenAt = Wire`, transition to `Lost`, clear destination, and leave everything else unchanged. This simulates irrecoverable loss of the unique token.
- `Next` now includes `DropToken` as one possible action (lines 165–176).
- `TypeOK` includes `Lost` in the legal locations (lines 187–201).

## What properties mean under permanent loss

- `AtMostOneOwner`: no more than one server claims ownership (safety).
- `AtMostOneToken`: no more than one token exists, including in transit (safety).
- `AtMostOnce`, `CompletedWasSubmitted`, `CorrectTarget`: printing safety conditions may remain valid.
- **`ExactlyOneToken` is intentionally NOT invariant here**: after loss there are **zero** tokens. Do not claim the token survives permanent loss.
- **`EverySubmittedFinishes` can fail**: jobs waiting for a token may be stuck forever. Fairness cannot cause a disabled dispatch to execute.

## Two configuration files / experiments

1. `PrintTokenLoss.cfg`: check **safety only**, expected to pass if the model is correct.
2. `PrintTokenLoss_liveness.cfg`: adds `PROPERTY EverySubmittedFinishes`; intended to show a liveness counterexample where the token is lost and pending work never finishes.

The expected liveness violation is not a code bug; it's the **purpose of the experiment**. A liveness failure is not evidence of mutual-exclusion failure.

## Link to the real Elixir project

This abstract loss model is *not* the newest retry-enabled runtime. Your Elixir `server.ex` retries the same transfer ID on a timer, and `PrintTokenRetry.tla` is the separate small recovery abstraction. Explain all three models as a progression: reliable protocol → permanent-drop weakness → finite-drop recovery design.
