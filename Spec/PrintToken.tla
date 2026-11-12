------------------------------- MODULE PrintToken -------------------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC

\* A finite model of 2 servers, 3 printers, and 3 different print jobs.
\* The variables are the GLOBAL state of the model checker; the real
\* Elixir actors do not have access to this combined view.
Servers == {"S1", "S2"}
Printers == {"P1", "P2", "P3"}
Jobs == {"J1", "J2", "J3"}
None == "none"
Wire == "in_transit"

Other(s) == IF s = "S1" THEN "S2" ELSE "S1"
Target(j) == CASE j = "J1" -> "P1"
                 [] j = "J2" -> "P2"
                 [] OTHER    -> "P3"
SeqSet(s) == {s[i] : i \in 1..Len(s)}

VARIABLES
  tokenAt,          \* S1, S2 or in transit (never duplicated)
  tokenTo,          \* destination while token is in transit
  requests,         \* token requests sent across the network
  serverQueue,      \* jobs pending locally at each server
  served,           \* token holder has dispatched a local job in this turn
  submitted,        \* IDs of jobs submitted by clients
  dispatched,       \* IDs already dispatched by a server
  printMessages,    \* jobs sent but not yet delivered to printers
  printerQueue,     \* private FIFO queue of each printer
  printerSeen,      \* IDs remembered by printer for deduplication
  active,           \* at most one active job per printer
  completed,        \* completed print job IDs
  printCount        \* used to check that no ID is ever printed twice

vars == <<tokenAt, tokenTo, requests, serverQueue, served, submitted,
          dispatched, printMessages, printerQueue, printerSeen, active,
          completed, printCount>>

Init ==
  /\ tokenAt = "S1"
  /\ tokenTo = None
  /\ requests = {}
  /\ serverQueue = [s \in Servers |-> <<>>]
  /\ served = [s \in Servers |-> FALSE]
  /\ submitted = {}
  /\ dispatched = {}
  /\ printMessages = {}
  /\ printerQueue = [p \in Printers |-> <<>>]
  /\ printerSeen = [p \in Printers |-> {}]
  /\ active = [p \in Printers |-> None]
  /\ completed = {}
  /\ printCount = [j \in Jobs |-> 0]

\* The client chooses which of the two servers receives its job.
Submit(s, j) ==
  /\ s \in Servers
  /\ j \in Jobs \ submitted
  /\ serverQueue' = [serverQueue EXCEPT ![s] = Append(@, j)]
  /\ submitted' = submitted \cup {j}
  /\ UNCHANGED <<tokenAt, tokenTo, requests, served, dispatched,
                  printMessages, printerQueue, printerSeen, active,
                  completed, printCount>>

\* The non-holder requests the token. Here requests is an abstract
\* network mailbox; this is NOT shared memory accessible by the actors.
RequestToken(s) ==
  /\ s \in Servers
  /\ tokenAt # s
  /\ ~(tokenAt = Wire /\ tokenTo = s)
  /\ Len(serverQueue[s]) > 0
  /\ s \notin requests
  /\ requests' = requests \cup {s}
  /\ UNCHANGED <<tokenAt, tokenTo, serverQueue, served, submitted,
                  dispatched, printMessages, printerQueue, printerSeen,
                  active, completed, printCount>>

\* Send exactly ONE token; the sender ceases owning it.
\* If the holder has work, it must dispatch at least one job before
\* granting the token to its waiting peer (simple anti-starvation rule).
GrantToken(s) ==
  /\ s \in Servers
  /\ tokenAt = s
  /\ Other(s) \in requests
  /\ (Len(serverQueue[s]) = 0 \/ served[s])
  /\ tokenAt' = Wire
  /\ tokenTo' = Other(s)
  /\ requests' = requests \ {Other(s)}
  /\ served' = [served EXCEPT ![s] = FALSE]
  /\ UNCHANGED <<serverQueue, submitted, dispatched, printMessages,
                  printerQueue, printerSeen, active, completed, printCount>>

\* Reliable delivery moves token from wire to its recipient.
ReceiveToken(s) ==
  /\ s \in Servers
  /\ tokenAt = Wire
  /\ tokenTo = s
  /\ tokenAt' = s
  /\ tokenTo' = None
  /\ served' = [served EXCEPT ![s] = FALSE]
  /\ requests' = requests \ {s}
  /\ UNCHANGED <<serverQueue, submitted, dispatched,
                  printMessages, printerQueue, printerSeen, active,
                  completed, printCount>>

\* A job may be dispatched only by the current holder.
Dispatch(s) ==
  /\ s \in Servers
  /\ tokenAt = s
  /\ Len(serverQueue[s]) > 0
  /\ LET j == Head(serverQueue[s]) IN
      /\ serverQueue' = [serverQueue EXCEPT ![s] = Tail(@)]
      /\ dispatched' = dispatched \cup {j}
      /\ printMessages' = printMessages \cup {j}
  /\ served' = [served EXCEPT ![s] = TRUE]
  /\ UNCHANGED <<tokenAt, tokenTo, requests, submitted, printerQueue,
                  printerSeen, active, completed, printCount>>

\* Message reaches exactly the destination indicated by Target.
ReceivePrint(p, j) ==
  /\ p \in Printers
  /\ j \in printMessages
  /\ Target(j) = p
  /\ printMessages' = printMessages \ {j}
  /\ IF j \in printerSeen[p]
       THEN /\ UNCHANGED printerQueue
            /\ UNCHANGED printerSeen
       ELSE /\ printerQueue' = [printerQueue EXCEPT ![p] = Append(@, j)]
            /\ printerSeen' = [printerSeen EXCEPT ![p] = @ \cup {j}]
  /\ UNCHANGED <<tokenAt, tokenTo, requests, serverQueue, served,
                  submitted, dispatched, active, completed, printCount>>

\* The printer can start a job only if it is idle.
StartPrint(p) ==
  /\ p \in Printers
  /\ active[p] = None
  /\ Len(printerQueue[p]) > 0
  /\ active' = [active EXCEPT ![p] = Head(printerQueue[p])]
  /\ printerQueue' = [printerQueue EXCEPT ![p] = Tail(@)]
  /\ UNCHANGED <<tokenAt, tokenTo, requests, serverQueue, served,
                  submitted, dispatched, printMessages, printerSeen,
                  completed, printCount>>

FinishPrint(p) ==
  /\ p \in Printers
  /\ active[p] # None
  /\ LET j == active[p] IN
      /\ completed' = completed \cup {j}
      /\ printCount' = [printCount EXCEPT ![j] = @ + 1]
  /\ active' = [active EXCEPT ![p] = None]
  /\ UNCHANGED <<tokenAt, tokenTo, requests, serverQueue, served,
                  submitted, dispatched, printMessages, printerQueue,
                  printerSeen>>

Next ==
  \/ \E s \in Servers, j \in Jobs : Submit(s, j)
  \/ \E s \in Servers : RequestToken(s)
  \/ \E s \in Servers : GrantToken(s)
  \/ \E s \in Servers : ReceiveToken(s)
  \/ \E s \in Servers : Dispatch(s)
  \/ \E p \in Printers, j \in Jobs : ReceivePrint(p, j)
  \/ \E p \in Printers : StartPrint(p)
  \/ \E p \in Printers : FinishPrint(p)

\* Weak fairness excludes executions that forever ignore a continuously
\* enabled request, token transfer, message delivery, or print step.
Spec == Init /\ [][Next]_vars
  /\ (\A s \in Servers : WF_vars(RequestToken(s)))
  /\ (\A s \in Servers : WF_vars(GrantToken(s)))
  /\ (\A s \in Servers : WF_vars(ReceiveToken(s)))
  /\ (\A s \in Servers : WF_vars(Dispatch(s)))
  /\ (\A j \in Jobs : WF_vars(ReceivePrint(Target(j), j)))
  /\ (\A p \in Printers : WF_vars(StartPrint(p)))
  /\ (\A p \in Printers : WF_vars(FinishPrint(p)))

TypeOK ==
  /\ tokenAt \in Servers \cup {Wire}
  /\ tokenTo \in Servers \cup {None}
  /\ requests \subseteq Servers
  /\ serverQueue \in [Servers -> Seq(Jobs)]
  /\ served \in [Servers -> BOOLEAN]
  /\ submitted \subseteq Jobs
  /\ dispatched \subseteq Jobs
  /\ printMessages \subseteq Jobs
  /\ printerQueue \in [Printers -> Seq(Jobs)]
  /\ printerSeen \in [Printers -> SUBSET Jobs]
  /\ active \in [Printers -> (Jobs \cup {None})]
  /\ completed \subseteq Jobs
  /\ printCount \in [Jobs -> Nat]

\* Token can be at one server or in transit, never at both.
ExactlyOneToken ==
  Cardinality({s \in Servers : tokenAt = s}) +
    (IF tokenAt = Wire THEN 1 ELSE 0) = 1

AtMostOnce == \A j \in Jobs : printCount[j] <= 1
CompletedWasSubmitted == completed \subseteq submitted

CorrectTarget ==
  \A p \in Printers :
    /\ \A j \in SeqSet(printerQueue[p]) : Target(j) = p
    /\ (active[p] = None \/ Target(active[p]) = p)

\* Liveness, conditional on reliable communication and weak fairness.
EverySubmittedFinishes ==
  \A j \in Jobs : (j \in submitted) ~> (j \in completed)

================================================================================
