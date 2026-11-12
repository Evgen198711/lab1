# `spec/PrintToken.tla` explained for a Java developer

**Actual source:** 206 lines. **Purpose:** finite formal model of *reliable* message delivery with 2 servers, 3 printers and 3 jobs. It is not executable Elixir; TLC enumerates possible abstract system states/transitions.

## Fundamental syntax vs Java

| TLA+ | Meaning | Closest Java way to think |
|---|---|---|
| `X == expression` | define operator, not variable assignment | named predicate/function |
| `VARIABLES a,b` | state variables | fields of `ModelState` |
| `Init == ...` | valid initial states | constructor/precondition |
| `Next == A \/ B` | any allowed next action | nondeterministic switch among transitions |
| `x'` | value of `x` in **next** state | `next.x` vs `current.x` |
| `/\` and `\/` | AND / OR | `&&`, `||` |
| `\in`, `\cup`, `\` | belongs-to, union, set difference | `contains`, union, subtraction |
| `\A`, `\E` | for all / exists | `allMatch`, `anyMatch` |
| `UNCHANGED <<x,y>>` | fields don't change | copy those fields into next state |
| `[]P`, `<>P` | always P, eventually P | temporal properties, not normal Java `if` |
| `P ~> Q` | whenever P, eventually Q | leads-to liveness property |
| `WF_vars(Action)` | weak fairness of action | assume continuously enabled action eventually occurs |

The model checker has a *global view* of all variables so it can verify the abstract protocol. That **does not** mean the Elixir actors share memory.

## Declarations — lines 1–37

`EXTENDS Naturals, FiniteSets, Sequences, TLC` imports basic math/sequence operators for the formal language. `Servers`, `Printers`, and `Jobs` are explicitly small finite sets. `Target(j)` fixes the assigned printer for each job: J1→P1, J2→P2, J3→P3. **This is a verification simplification**; runtime client requests supply a destination in their job maps. `Other(s)` returns peer server. `SeqSet` converts a sequence to a set.

Global state variables include `tokenAt`, `tokenTo`, `requests`, server queues, `served` (per-server turn bookkeeping), `submitted`, `dispatched`, in-flight `printMessages`, per-printer queues and seen sets, `active` and `printCount`.

## `Init` — lines 38–52

S1 has token, S2 none; all queues, message sets and completed lists empty; printer slots idle; print counts zero. Java analogy: instantiate a model state with default values.

## Every transition, function by function

- **`Submit(s,j)` (54–63)**: an as-yet-unsubmitted job can be appended to either server's pending queue, and job enters global `submitted` set. Models independent client submissions.
- **`RequestToken(s)` (65–77)**: a server without token and with queued work adds its request to abstract network mailbox `requests`, if not already requested and if token isn't already heading its way.
- **`GrantToken(s)` (79–90)**: current holder sends token toward waiting peer and stops owning it. If holder also has pending work, it must have dispatched at least one this turn (anti-starvation design).
- **`ReceiveToken(s)` (92–103)**: reliable delivery transfers token from `Wire` to destination server and resets served flags.
- **`Dispatch(s)` (105–116)**: only server with token may take FIFO head of queue and add job to dispatched set and `printMessages`.
- **`ReceivePrint(p,j)` (118–130)**: only correct target receives job; if ID already seen, ignore duplicate; otherwise add to printer-local FIFO and seen set.
- **`StartPrint(p)` (132–140)**: if printer is idle and its FIFO nonempty, pop head into active slot. No printer has two active jobs.
- **`FinishPrint(p)` (142–151)**: finish active job, increment its `printCount`, add to completed set, clear active slot.
- **`Next` (153–163)**: nondeterministic OR of all the above transitions for possible servers/printers/jobs. TLC explores permitted interleavings.
- **`Spec` (165–172)**: `Init /\ [][Next]_vars` says begin in Init and then repeatedly take permitted transitions (or stuttering). Fairness clauses rule out certain indefinitely postponed continuously enabled actions.

## Safety invariants — lines 174–201

- `TypeOK`: state values stay in defined finite type domains.
- `ExactlyOneToken`: exactly one logical token exists, either at one server or in transit; hence no two server holders.
- `AtMostOnce`: `printCount[j] <= 1` for every modeled job.
- `CompletedWasSubmitted`: no phantom completed job.
- `CorrectTarget`: pending/active job always at its fixed assigned printer.

## Liveness — lines 203–204

`EverySubmittedFinishes`: whenever a job is in `submitted`, it will **eventually** be in `completed` (`~>`). This conclusion depends on reliable delivery and fairness; it is not guaranteed under permanent message loss.

## TLC configuration

`PrintToken.cfg` names `Spec`, disables deadlock checking for this transition system, includes the five invariants and `EverySubmittedFinishes` as PROPERTY. `README.md` records 1,680 distinct states from an earlier TLC run, but I have **not rerun** it here.

## Lecturer-ready summary

“This TLA+ model abstracts the same protocol into finite sets of servers, printers and jobs. TLC explores all transitions it can generate, checking that the token is never duplicated, jobs cannot be printed twice, and—with fairness and reliable delivery—submitted jobs eventually finish.”
