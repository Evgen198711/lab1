# Lecturer questions and short prepared answers

**1. Why is this distributed?** Two server actors on distinct BEAM nodes and three printer actors on three other nodes communicate with messages, without shared application memory. Test controller is a sixth node.

**2. Why two servers?** Both accept jobs independently; a unique token coordinates which may dispatch. This is a design demonstration of distributed mutual exclusion, not a requirement that physical printers share a global lock.

**3. Does the token prevent printers from printing in parallel?** No. It protects **dispatch** only. Printers have separate FIFOs and can be simultaneously active.

**4. Who selects the destination printer?** The client sends a job map with globally unique `id` and selected `printer` ID. The server uses that map to find destination. There is no load balancing algorithm.

**5. What is a GenServer in Java language?** Think of an actor with a mailbox, private state, and message handlers. It's not a Java `Map` or ordinary instance; `GenServer.call` waits for a reply, `cast` does not.

**6. What does `start_link` do compared with `start`?** Both start a GenServer process. `start_link` links it to caller for failure propagation; `start` doesn't. Remote RPC test uses `start` since its worker is temporary.

**7. What does `do:` mean?** Single-expression function body. `defp` is private function. No Java-style return statement is required for last expression.

**8. Is `__MODULE__` equal to Java `this`?** No. It's current **module**, roughly like `Server.class`, not a current object instance.

**9. How do you ensure only one server dispatches?** `drive` checks `has_token` before dispatch; `give_token` sets `has_token=false` **before** sending token. Receiver accepts a transfer ID only once.

**10. What if token request is dropped?** Server without token and with queued work retries its `:token_request` in periodic `:retry` handler.

**11. What if token grant is dropped?** Sender becomes unable to dispatch, records pending transfer and retransmits **same** transfer ID until matching `:token_ack` arrives.

**12. What if token ACK is dropped?** Sender retries same grant; receiver detects remembered transfer ID and ACKs again without taking an extra token.

**13. What if `:print` is dropped?** Job stays in server `in_flight` map. Retry loop resends it with same job ID until `:printed` confirmation.

**14. What if printer's `:printed` is dropped?** Server retries `:print`; printer's `print_counts` says ID was completed, so it **re-sends `:printed` without reprinting**. No separate server-to-printer completion ACK exists.

**15. How is duplicate job ID handled?** A server rejects repeat submissions of IDs it has already seen; each printer suppresses duplicate deliveries of IDs it knows. Global uniqueness is an assumption—not a distributed ID allocator.

**16. What is local vs distributed testing?** `printing_test.exs` uses actors in one VM; `distributed_test.exs` starts actors remotely on 5 other Erlang nodes using `:rpc.call` and checks 9 scenarios.

**17. What do TLA+ and TLC do?** TLA+ specifies possible abstract states/transitions and correctness properties. TLC enumerates reachable states and checks invariants and temporal properties for chosen finite model.

**18. Difference between safety and liveness?** Safety = something bad never happens (two token owners, duplicate print). Liveness = something good eventually happens (every pending job finishes) under delivery/fairness assumptions.

**19. What does `PrintTokenLoss.tla` demonstrate?** Permanent loss of unique token can preserve mutual exclusion while destroying progress. Its liveness counterexample is intentional.

**20. What does `PrintTokenRetry.tla` prove?** It *aims to check* a smaller bounded finite-loss recovery scenario: 2 servers, 1 printer, 2 jobs and 1 token transfer. Do **not** claim TLC passed until an actual run succeeds.

**21. Are exactly-once physical prints guaranteed under crashes?** No. With live actors and remembered job IDs, repeated messages don't cause duplicate simulated printing. A reboot erases deduplication state and the system lacks durable spool/transactions.

**22. Why use `@default_retry_ms`?** Module attribute holding default 60 ms delay; akin to a Java compile-time constant. `Process.send_after` schedules recurring retry messages, not automatic Java-style method callbacks.
