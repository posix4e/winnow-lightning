# Winnow regtest message claims, version 1

This private experiment uses the pinned PQLN channel core and Winnow's wallet,
Bitcoin peers, compact-filter scanner and broadcaster. It is not a BOLT 12
refund, a new Bitcoin transaction format, or a production payment service.
Funded claims remain disabled by default while the acceptance tests and app
integration are completed. Ordinary BOLT 12 refunds return an explicit
unsupported result because the pinned refund response does not satisfy this
app's required PQ invoice authentication.

## Contract

The sender S has a channel to provider A. A pays recipient R through a different
provider B; R needs no channel to A. S can terminate after funding is committed.
A must remain available during redemption. S reconciles when it returns, or
uses its channel monitor to recover on chain after a failure.

The first version accepts 5,000–100,000 regtest sats, one active claim per
sender, one recipient invoice, and a single outgoing HTLC. The fixed provider
fee is 100 sats. The sender's direct funding payment has a zero routing-fee
budget; A pays downstream fees out of its 100-sat fee. On-chain recovery fees
are additional. There is no early cancellation after commitment, change claim,
split claim, or replacement recipient invoice. An unfunded quote can be
discarded with an acknowledged, idempotent cancellation.

The sender generates a random 32-byte preimage p, payment hash SHA256(p), and
independent random 32-byte capability c. A initially receives only the payment
hash and SHA256(c). The recipient gets p and c in the bearer payload. Redemption
sends c and a recipient invoice to A, never p. The recipient gives p to the
channel core only for the exact accepted incoming amount. A obtains p from its
outgoing payment's settlement (including an on-chain spend) and fulfills the
held incoming payment. An acknowledged share or provider message never credits
the recipient's balance.

The payload is copyable. Its first accepted recipient invoice consumes the
binding, including when another holder is the sender. Keeping p private during
the honest flow does not stop a malicious holder from disclosing it. Possession
of p is not proof that a named recipient was paid. Receipts use channel events.

## Authentication and encoding

The prefix is `wlnclaim1:` followed by lowercase hex of compact UTF-8 JSON in
the fixed Rust structure field order. Whitespace, unknown fields, duplicate
fields, alternate encodings, other networks and versions are rejected. The
entire text is capped at 32,768 bytes. The envelope contains `quote`,
`capability`, and `preimage`; `quote` contains `terms` and `invoice`.

Terms, in order: `version`, `network`, `claim_id`, `provider_node_id`,
`provider_host`, `provider_port`, `payment_hash`, `capability_hash`,
`amount_msat`, `fee_msat`, `latest_claim_height`, `expires_at_unix`,
`hold_delta`. Amounts are checked unsigned integer millisatoshis. IDs and
secrets use canonical 32-byte lowercase hex. Node IDs are canonical compressed
secp256k1 public keys. The provider host is a bounded host name or IP literal,
not a URL, and is authenticated along with its port.

The commitment is SHA256 of the ASCII domain
`winnow-regtest-funded-claim-v1`, one NUL byte, and the compact terms JSON.
The funding BOLT 11 invoice's description hash contains that commitment.
Its existing hybrid PQ signature authenticates the commitment and the invoice's
payee, hash, amount and final CLTV. Both sender and recipient require an
independently pinned provider ML-DSA key; the payload cannot install a pin.
A likewise verifies the recipient's invoice against a separately pinned key
and the authenticated control connection's node identity. The fixture installs
these public keys out of band. General provider discovery is not implemented.

A measured valid hybrid-PQ envelope is 14,168 UTF-8 bytes with a 6,362-byte
invoice. This version offers text and file sharing; it makes no single-QR
claim. A recipient must preserve every byte. No link shortener, hosted claim
page, compression layer or universal-link domain is required.

## Time and funding readiness

New redemption must begin before both the quote's one-hour wall-clock deadline
and its 72-block deadline. The pinned core publishes a 39-block HTLC fail-back
buffer. The requested holding delta is
`72 + 144 + 2 * 39 + 3 = 297`; the core adds three blocks in the invoice, making
its advertised final delta 300. The downstream route's absolute expiry is
bounded by the actual `PaymentClaimable.claim_deadline` minus the full 39-block
buffer. A restart recomputes the remaining delta against this saved absolute
height; it cannot extend the budget. Route randomization must stay within the
same bound, and the outgoing route is restricted to one path.

Share requires all of: A's durable held-payment acknowledgement, the sender's
matching non-dust outbound HTLC in `Committed`, the exact debit and provider,
current quote terms, caught-up chain state, and persisted manager/monitor and
claim records. A checks a live, committed, non-dust incoming HTLC before binding
a payout. The initial incoming claim must arrive through the quoted sender's
channel with exactly the invoice amount and one receiving channel. Core
duplicate-HTLC checks protect an already claimable hash; the bridge additionally
binds the original inbound payment ID and rejects later reuse.

Expiry changes display state, not balances. Only definitive channel failure or
on-chain timeout recovery releases the sender's funds. Recorded success takes
precedence over late failure notifications and cannot be reopened by a reorg.

## Control messages and persistence

The extension uses private odd Lightning wire type 39001 over the existing
authenticated hybrid peer connection. It is separate from standard async
onion messages. Each control message is a two-byte length followed by bounded
JSON (maximum 16,384 bytes); incoming and outgoing queues each hold at most 32
messages. Unknown or malformed messages cannot allocate an unbounded queue.
The message debug representation reveals only its byte count.

Messages are Prepare, Quoted, Check, Ready, Redeem, Cancel, Cancelled and
Rejected. Prepare carries hashes, identity and amount, never p or c. Redeem
carries c and the recipient invoice, never p. Requests retry the same durable
identity and parameters. The native worker serializes incoming messages and
financial actions; a racing recipient cannot replace a saved invoice binding.

The protected native journal stores creation intent, secrets, immutable quote
terms, the canonical exported payload and recipient/provider bindings. Routine
snapshots expose only public projections. Export is an explicit authenticated
app operation. Provider terms persist before invoice registration; payout
binding persists before sending; an outgoing settlement receipt persists before
claiming upstream. Queued wire bytes leave the bridge only after manager and
monitor persistence. Startup first restores and catches up Winnow's verified
chain, then resumes saved operations. A provider response cannot manufacture a
recipient receipt or refund.

## Verification and limits

Local four-node protocol tests cover non-overlapping sender/recipient sessions,
sender reconnection, two competing
claimants, provider restart after binding, recipient restart, cooperative expiry,
provider-offline on-chain timeout recovery, force-close preimage recovery and a
reorg during on-chain settlement. Parser and signature tests reject altered
terms and secret commitments without import side effects. Native storage tests
cover failure before publication and restored manager/monitor state.

The CI job runs these cases plus the existing Winnow suite and three real app
journeys (base channel lifecycle, sender sharing/reconnecting, recipient
claiming while the sender is stopped). Each recording's manifest identifies its
source revision and dirty status; a local draft recording is not release proof.
The release script requires successful hosted CI at the archived commit.

This is a regtest research protocol with foreground-only monitoring, no seed-only
channel restore, no watchtower, bounded single-path claims, private peer routing
and no anchor transaction packages. Apple processing and group membership are
separate release gates; code or a successful archive does not establish
TestFlight availability. Actual results are recorded with the rollout evidence.
