# Design

This document captures open and resolved design decisions.

## Resolved: Shared or separate timestamp requests (shared)

Does each server commiting a transaction obtain its own TrueTime timestamp from infrastructure, or is there one party that obtains a shared timestamp? --> shared.

Timestamps are signed by infrastructure so can't be forged. A _happens after_ relation can be obtained by including a token \[chain\] in the timestamp request (at the cost of a roundtrip). Each server can thus validate that the timestamp came from infrastructure. Each server also validates that it is committing a transaction with a timestamp greater than all previous timestamps for those data elements.

## Open: preventing backdating attack

Can a server maliciously backdate a transaction? Not unlaterally. No one will commit a transaction before the timestamp of any existing data record.

What about disjoint sets of servers? Can an attacker use a few servers that are "behind" to backdate a transaction relative to a few servers that are "ahead"? Yes.

Proposal: servers in phase 1 can provide a salt to the client, client provides this salt to timeservers, which sign it along with the timestamp. Timestamp is sent back to servers.

## Open: Servers that don't know about `Consistent-*`

Servers that haven't been upgrade will process PUT/PATCH/etc. commands immediately. This may be contrary to the semantics the client wants. Need a way to cause such servers to error out. A single unknown header may not do it. Do we need an `OPTIONS` request for every server to be safe?

New verb? MPUT and friends?

## Idea: Consensus service

[Chubby paper](https://static.googleusercontent.com/media/research.google.com/en//archive/chubby-osdi06.pdf) envisioned and rejected a more general _consensus_ service, rather than the lock service they implemented.

> In a loose sense, one can view the lock service as a way of providing a generic electorate that allows a client system to make decisions correctly when less than a majority of its own members are up. One might imagine solving this last problem in a different way: by providing a “consensus service”, using a number of servers to provide the “acceptors” in the Paxos protocol. Like a lock service, a consensus service would allow clients to make progress safely even with only one active client process; a similar technique has been used to reduce the number of state machines needed for Byzantine fault tolerance [24]. However, assuming a consensus service is not used exclusively to provide locks (which reduces it to a lock service), this approach solves none of the other problems described above.

Possible "layers" of a service:

 * TrueTime ranges: `[tt.earliest, tt.latest]`
   * Semantic: what time is it _not_?
   * Useful to exclude non-causal possible orderings by looking for disjoint intervals
   * Service maintains infrastructure to provide current time and uncertainty (epsilon)
   * Might be semantically misused (e.g. using midpoint as a "more accurate clock")
   * No specific use case that can't be more robustly covered by a post-commit wait timestamp (below)
 * TrueTime timestamps: `tt.timestamp`
   * Semantic: produce a causally-robust ordering of events (global monotonic wall clock)
   * Reduce TrueTime range to a single timestamp by performing a commit wait
   * Service is very similar to one providing ranges
   * Harder to misuse a post-commit wait timestamp than a range
   * Not any worse for performance, users of a timestamp range could just run a concurrent request for a post-commit wait timestamp

With the above, abitrary groups of servers could establish an ordering for their events that is externally consistent and globally ordered with all other events on all other servers.

But what if they fail during consensus? Each would need to maintain its own robust replicated log for recovery. Can we abstract this away?

 * Logged TrueTime timestamps: `{requestId, tt.timestamp}`
   * Semantic: logged causal ordering of events
   * Clients can request a timestamp by sending a new arbitrary `partialRequestId`
   * Service performs commit wait and sends back `{requestId, tt.timestamp}`
     * `requestId = partialRequestId + serverSalt` for uniqueness
   * Anyone can send an existing `requestId` and get back the (logged) `tt.timestamp` for that request
   * Logged timestamps expire after 30 (?) days
   * In Paxos, a client making a COMMIT decision issues a logged timestamp request
   * Existance of the timestamp in the log is evidence of the COMMIT decision
   * Any failed server (or a server that just doesn't hear about the COMMIT decision) can ask the service if a timestamp for this transaction has been requested, and if so, commits the transaction with that timestamp
   * Servers cannot discard the transaction until a global timeout has been met
>  * TODO: add expiry to the service semantics, the service has to be part of deciding whether to expire a transaction

> * TODO: There's probably something in between these two.
 * Ordered logging service
   * Semantic: maintain log of timestamp requests, keyed by requester and some requester-provided metadata
   * Allows failed nodes to reliably confirm a timestamp
 * Consensus service:
   * Establish and record encrypted payloads comprising transactions
   * Trusted third-party oracle for commitment and ordering
   * Provides recovery path without requiring servers to properly behave
   * Servers only need to properly prevent conflicts within _their_ locally stored data

### Scratch

Decisions:

 * Client makes commit decision
 * Ordering service is authoritative about state of transaction
 * Servers determine if local conflicts prevent transaction
 > * TODO: Servers verify other servers are participating/committing

Life of a transaction


 * Client enqueues all operations with servers (verify operations are valid, or fail)
 * Meanwhile client "opens" a ticket with logged ordering service
   * Client specifies a timeout, needs to be a timeout acceptable to all servers
   * Service replies with ticketId (no timestamp yet)
 * Start commit process
   * Client issues `COMMIT` to all servers with ticketId and (non-authoritative) timeout
   * Servers acquire all locks and reply ready to commit (or fail)
     * Servers are now "committed"
   * Servers acquire all locks
   * Servers reply ready to commit (or fail)
     * Ready servers cannot back out, they have to wait for a commit decision (timeout?)
     * Failed servers
 * Acquire all locks

### Flow

> TODO: Add representation of cross-server dependencies

 1. Client generates a `Consistent-Id`
 2. Client issues commands to servers with `Consistent-Id` header, and sends transaction initiation to consensus service with same header
 3. Servers reply to client and forward their own `Consistent-Token`s to consensus service
 4. Consensus service appends `Consistent-Token`s to commit record keyed on `Consistent-Id`
 5. Client requests commitment of transaction with all servers
 6. Servers acquire locks and submit PREPARED message to consensus service
 7. Consensus service appends PREPARED messages to commitment log
 8. Consensus service performs commit wait
 9. If majority of servers reply 

Open questions:

 * Payloads available to everyone?
 * Payloads queryable? For how long?
 * Scale:
   * Consensus service requires storage (logging) that scales with number of transactions (for however long records need to be kept)
   * Lock service requires storage that scales with number of locks
 * Cannot do this without semantic integration
   * Not only does BankA want to know that BankB is particpating in the transaction, BankA wants to know that there is a debit of $10 from BankB before BankA will credit $10.
   * So some cross-origin content visibility is needed for cross-origin transactions
   * But how much visibility? The whole transaction (including upstream and downstream parts)? Who decides? How does the client construct a transaction and sub-parts to share with each of the participants?
   * Two-way trust? At a minimum, BankA needs to say "I want verification from BankB" and BankB needs to say "I will permit sharing transaction details with BankA."

## Other ideas

 * Hashgraph: all nodes replicate a git-like graph of events (including gossip events)
   * Node-local repos have all information needed to run deterministic ordering algorithms that do not require communication
   * Storage requirements scale with number of gossip messages, not number of transactions
   * Transactions can be batched into fewer gossip events, so probably not that bad
   * Nodes sign their own transactions locally
   * Nodes build up trust over time via gossiping known-good information (information that can be verified by multiple sources)
   * Resilient to <1/3 bad actors
   * Global complete record stored at every node (though nodes don't need to store all history if they trust some starting point)
     * New nodes just need a single hash to use as their "root", can get it from a trusted source and validate over time
   * No central server
   * 100k messages per second (?)
   * All messages available to all nodes