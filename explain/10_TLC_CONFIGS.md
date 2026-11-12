# All `spec/*.cfg` files explained for a Java developer

A TLA+ `.tla` file contains state definitions, transitions and properties. A TLC `.cfg` file says **which specification and assertions TLC should check**. Think a *test run configuration* rather than Java program logic.

`SPECIFICATION Spec` = use the `Spec` operator as the system behavior. `INVARIANT Name` = a safety predicate that must hold in every reachable state. `PROPERTY Name` = temporal property (e.g. eventual completion) that must hold over behaviors. `CHECK_DEADLOCK FALSE` = do not report the system's intentional stuttering/terminal behavior as a deadlock; it **does not** disable invariant/property checking.

## `PrintToken.cfg`

- `SPECIFICATION Spec`.
- Five safety checks: `TypeOK`, `ExactlyOneToken`, `AtMostOnce`, `CompletedWasSubmitted`, `CorrectTarget`.
- One liveness check: `EverySubmittedFinishes`.

## `PrintTokenLoss.cfg`

- `SPECIFICATION Spec`.
- Six safety checks: `TypeOK`, `AtMostOneOwner`, `AtMostOneToken`, `AtMostOnce`, `CompletedWasSubmitted`, `CorrectTarget`.
- **No liveness property**; intended safety experiment with permanently lost token.

## `PrintTokenLoss_liveness.cfg`

- Same six safety invariants as `PrintTokenLoss.cfg`.
- Adds `PROPERTY EverySubmittedFinishes`. Counterexample is intentional: permanent loss can block pending jobs.

## `PrintTokenRetry.cfg`

- Invariants: `TypeOK`, `ExactlyOneLogicalToken`, `SenderNeverUsesPendingToken`, `AtMostOnce`, `NoPhantomCompletion`, `NoDuplicateQueue`.
- Properties: `EveryJobFinishes`, `EveryCompletionAcknowledged`.
- Bounded recovery model with **one printer and two jobs**, not full implementation.

## Typical TLC invocation (from `spec/`)

```bash
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintToken.cfg PrintToken.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenLoss.cfg PrintTokenLoss.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenLoss_liveness.cfg PrintTokenLoss.tla
java -cp /path/to/tla2tools.jar tlc2.TLC -config PrintTokenRetry.cfg PrintTokenRetry.tla
```

For your defense distinguish *expected* results from actually run results. `README.md` reports an earlier successful `PrintToken` check; the new retry model was not verified in the authoring environment. No TLC run has been performed while preparing these guides.
