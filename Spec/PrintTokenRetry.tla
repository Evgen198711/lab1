----------------------------- MODULE PrintTokenRetry -----------------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC

\* FINITE RECOVERY SCENARIO (a deliberately smaller abstraction):
\* Two servers S1/S2, one printer P1, and one job at EACH server.
\* Both jobs exist at the start; S1 dispatches its job before handing the
\* token to S2. This checks ONE token handoff, including dropped requests,
\* grants, ACKs, print messages, and completion notifications.
\* The original PrintToken.tla separately checks arbitrary submissions,
\* transfers and 3 printers under reliable communication.
\* A finite drop budget represents TEMPORARY losses (not a partition).
\* A transfer remains logically escrowed at its sender until received;
\* sender cannot use it or recreate it while ACK is pending.
Servers == {"S1", "S2"}
Jobs == {"J1", "J2"}
None == "none"
Target(j) == "P1"
JobServer(j) == IF j = "J1" THEN "S1" ELSE "S2"

VARIABLES
  owner, requestWire, requestSeen,
  transferPending, grantWire, grantSeen, ackWire, ackSeen,
  dispatched, printWire, printerSeen, printerQueue, active,
  completed, completionWire, confirmed, printCount,
  dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion

vars == <<owner, requestWire, requestSeen, transferPending,
          grantWire, grantSeen, ackWire, ackSeen, dispatched,
          printWire, printerSeen, printerQueue, active,
          completed, completionWire, confirmed, printCount,
          dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

Init ==
  /\ owner = "S1"
  /\ requestWire = FALSE
  /\ requestSeen = FALSE
  /\ transferPending = FALSE
  /\ grantWire = FALSE
  /\ grantSeen = FALSE
  /\ ackWire = FALSE
  /\ ackSeen = FALSE
  /\ dispatched = {}
  /\ printWire = {}
  /\ printerSeen = {}
  /\ printerQueue = <<>>
  /\ active = None
  /\ completed = {}
  /\ completionWire = {}
  /\ confirmed = {}
  /\ printCount = [j \in Jobs |-> 0]
  /\ dropRequest = 1
  /\ dropGrant = 1
  /\ dropTokenAck = 1
  /\ dropPrint = 1
  /\ dropCompletion = 1

\* A dropped token request is retried, and S1 remembers receipt.
SendRequest ==
  /\ ~requestSeen
  /\ ~requestWire
  /\ requestWire' = TRUE
  /\ UNCHANGED <<owner, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

DropRequest ==
  /\ requestWire
  /\ dropRequest > 0
  /\ requestWire' = FALSE
  /\ dropRequest' = dropRequest - 1
  /\ UNCHANGED <<owner, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

ReceiveRequest ==
  /\ requestWire
  /\ requestWire' = FALSE
  /\ requestSeen' = TRUE
  /\ UNCHANGED <<owner, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

Dispatch(j) ==
  /\ j \in Jobs
  /\ owner = JobServer(j)
  /\ j \notin dispatched
  /\ dispatched' = dispatched \cup {j}
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

GrantToken ==
  /\ requestSeen
  /\ owner = "S1"
  /\ "J1" \in dispatched
  /\ ~transferPending
  /\ owner' = None
  /\ transferPending' = TRUE
  /\ grantWire' = TRUE
  /\ UNCHANGED <<requestWire, requestSeen, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

DropGrant ==
  /\ grantWire
  /\ dropGrant > 0
  /\ grantWire' = FALSE
  /\ dropGrant' = dropGrant - 1
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropTokenAck, dropPrint, dropCompletion>>

RetryGrant ==
  /\ transferPending
  /\ ~grantWire
  /\ ~ackSeen
  /\ grantWire' = TRUE
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

ReceiveGrant ==
  /\ grantWire
  /\ grantWire' = FALSE
  /\ grantSeen' = TRUE
  /\ owner' = IF grantSeen THEN owner ELSE "S2"
  /\ ackWire' = TRUE
  /\ UNCHANGED <<requestWire, requestSeen, transferPending, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

DropAck ==
  /\ ackWire
  /\ dropTokenAck > 0
  /\ ackWire' = FALSE
  /\ dropTokenAck' = dropTokenAck - 1
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropPrint, dropCompletion>>

ReceiveAck ==
  /\ ackWire
  /\ ackWire' = FALSE
  /\ ackSeen' = TRUE
  /\ transferPending' = FALSE
  /\ UNCHANGED <<owner, requestWire, requestSeen, grantWire, grantSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

SendPrint(j) ==
  /\ j \in Jobs
  /\ j \in dispatched
  /\ j \notin confirmed
  /\ j \notin printWire
  /\ printWire' = printWire \cup {j}
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

DropPrint(j) ==
  /\ j \in printWire
  /\ dropPrint > 0
  /\ printWire' = printWire \ {j}
  /\ dropPrint' = dropPrint - 1
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printerSeen, printerQueue, active, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropCompletion>>

ReceivePrint(j) ==
  /\ j \in printWire
  /\ printWire' = printWire \ {j}
  /\ printerSeen' = printerSeen \cup {j}
  /\ printerQueue' = IF j \in printerSeen THEN printerQueue ELSE Append(printerQueue, j)
  /\ completionWire' = IF j \in completed THEN completionWire \cup {j} ELSE completionWire
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, active, completed, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

StartPrint ==
  /\ active = None
  /\ Len(printerQueue) > 0
  /\ active' = Head(printerQueue)
  /\ printerQueue' = Tail(printerQueue)
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, completed, completionWire, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

FinishPrint ==
  /\ active # None
  /\ completed' = completed \cup {active}
  /\ printCount' = [printCount EXCEPT ![active] = @ + 1]
  /\ completionWire' = completionWire \cup {active}
  /\ active' = None
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, confirmed, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>

DropCompletion(j) ==
  /\ j \in completionWire
  /\ dropCompletion > 0
  /\ completionWire' = completionWire \ {j}
  /\ dropCompletion' = dropCompletion - 1
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, confirmed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint>>

ReceiveCompletion(j) ==
  /\ j \in completionWire
  /\ completionWire' = completionWire \ {j}
  /\ confirmed' = confirmed \cup {j}
  /\ UNCHANGED <<owner, requestWire, requestSeen, transferPending, grantWire, grantSeen, ackWire, ackSeen, dispatched, printWire, printerSeen, printerQueue, active, completed, printCount, dropRequest, dropGrant, dropTokenAck, dropPrint, dropCompletion>>
Next ==
  \/ SendRequest
  \/ DropRequest
  \/ ReceiveRequest
  \/ \E j \in Jobs : Dispatch(j)
  \/ GrantToken
  \/ DropGrant
  \/ RetryGrant
  \/ ReceiveGrant
  \/ DropAck
  \/ ReceiveAck
  \/ \E j \in Jobs : SendPrint(j)
  \/ \E j \in Jobs : DropPrint(j)
  \/ \E j \in Jobs : ReceivePrint(j)
  \/ StartPrint
  \/ FinishPrint
  \/ \E j \in Jobs : DropCompletion(j)
  \/ \E j \in Jobs : ReceiveCompletion(j)

\* WEAK FAIRNESS: an action that stays enabled eventually executes.
\* Drop actions are NOT required. They can occur only a bounded number of
\* times because each decreases a finite budget. Retries are fair.
Spec == Init /\ [][Next]_vars
  /\ WF_vars(SendRequest)
  /\ WF_vars(ReceiveRequest)
  /\ (\A j \in Jobs : WF_vars(Dispatch(j)))
  /\ WF_vars(GrantToken)
  /\ WF_vars(RetryGrant)
  /\ WF_vars(ReceiveGrant)
  /\ WF_vars(ReceiveAck)
  /\ (\A j \in Jobs : WF_vars(SendPrint(j)))
  /\ (\A j \in Jobs : WF_vars(ReceivePrint(j)))
  /\ WF_vars(StartPrint)
  /\ WF_vars(FinishPrint)
  /\ (\A j \in Jobs : WF_vars(ReceiveCompletion(j)))

TypeOK ==
  /\ owner \in Servers \cup {None}
  /\ requestWire \in BOOLEAN
  /\ requestSeen \in BOOLEAN
  /\ transferPending \in BOOLEAN
  /\ grantWire \in BOOLEAN
  /\ grantSeen \in BOOLEAN
  /\ ackWire \in BOOLEAN
  /\ ackSeen \in BOOLEAN
  /\ dispatched \subseteq Jobs
  /\ printWire \subseteq Jobs
  /\ printerSeen \subseteq Jobs
  /\ printerQueue \in Seq(Jobs)
  /\ active \in Jobs \cup {None}
  /\ completed \subseteq Jobs
  /\ completionWire \subseteq Jobs
  /\ confirmed \subseteq Jobs
  /\ printCount \in [Jobs -> Nat]
  /\ dropRequest \in 0..1
  /\ dropGrant \in 0..1
  /\ dropTokenAck \in 0..1
  /\ dropPrint \in 0..1
  /\ dropCompletion \in 0..1

\* While handoff is pending, either the token is escrowed by the sender
\* (before first receipt), or S2 is its sole logical owner (after receipt).
ExactlyOneLogicalToken ==
  (IF owner \in Servers THEN 1 ELSE 0) +
    (IF transferPending /\ ~grantSeen THEN 1 ELSE 0) = 1

SenderNeverUsesPendingToken == transferPending => owner # "S1"
AtMostOnce == \A j \in Jobs : printCount[j] <= 1
NoPhantomCompletion == completed \subseteq dispatched
NoDuplicateQueue == Len(printerQueue) = Cardinality({printerQueue[i] : i \in 1..Len(printerQueue)})
SingleActivePrinter == active \in Jobs \cup {None}

\* Both jobs have been submitted in Init. Under fairness and finitely many
\* message drops, the two jobs eventually finish and are acknowledged.
EveryJobFinishes == \A j \in Jobs : <> (j \in completed)
EveryCompletionAcknowledged == \A j \in Jobs : <> (j \in confirmed)

================================================================================
