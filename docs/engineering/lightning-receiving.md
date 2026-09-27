# Lightning receiving and provider setup

Both wallet modes offer **Receive → Lightning or Bitcoin**. Bitcoin continues
to show a Winnow address. Lightning shows a standard BOLT11 invoice for a
specific amount once a confirmed channel has usable inbound capacity and a
signed routing policy. An empty wallet does not invent capacity or an invoice.
Kraken's Lightning withdrawal uses the Lightning invoice; an on-chain withdrawal
uses the Bitcoin address. Copy and Share preserve the exact invoice bytes.

Fresh mainnet wallets recommend Olympus by ZEUS. The provider picker contains
three choices, connects to one, and opens no channels or makes payments just
because a choice is selected:

| Provider | Setup |
| --- | --- |
| Olympus by ZEUS | LSPS1 quotes over the authenticated Lightning connection |
| Megalith | LSPS1 quotes over its HTTPS API while the Lightning peer is connected |
| LNServer Wave | Clearly labeled website setup; copy the durable wallet node ID and choose a private channel |

Olympus and Megalith return live capacity limits and a separate setup fee invoice.
Review the fee, capacity, lease and confirmation count. Approving the fee requires
device authentication and reveals that invoice; it does **not** pay it. Pay it
from another Lightning wallet or Kraken. The setup fee buys inbound capacity,
not wallet balance. Check setup status and sync before creating a receive invoice.
Orders and approval survive restart in a sealed, device-protected file. Providers
cannot be changed while an approved order or an existing channel remains active.
Paid or expired fee invoices cannot be offered again as payable invoices.

LNServer quotes and payment approval happen on its website. Winnow does not
claim an in-app quote integration for that provider. Reopen Winnow to sync the
funding transaction and establish receiving capacity.

Purchases request a private channel, zero initial client balance, and at least
three confirmations. Megalith receives the nonempty `Winnow` token described in
its compatibility documentation to avoid zero-reserve channels that violate
the wallet's dust checks. Mainnet services are never defaults on signet/regtest.
Advanced profile import and the existing BOLT12 async offers remain available.

Invoices use Winnow's Bech32 and bit-conversion code, the existing pinned
libsecp256k1 dependency, and the Swift engine's durable payment machinery. Route
hints bind the provider's signature and policy to the funding transaction's
verified block position. Older journals lacking a position request a rescan.
Wall-clock invoice expiry is also persisted and checked when accepting payment.

This remains an experimental Lightning engine. Keep the app open for ordinary
BOLT11 receiving. A default provider does not provide external watchtower
protection; iOS background checks run only when permitted. Public connection and
unpaid-quote diagnostics are separate from funded mainnet payment validation.

Primary contracts:

- [BOLT11](https://github.com/lightning/bolts/blob/master/11-payment-encoding.md)
- [LSPS1](https://github.com/lightning/blips/blob/master/blip-0051.md)
- [Olympus](https://docs.zeusln.app/lsp/services/lsps1/)
- [Megalith](https://docs.megalithic.me/lightning-services/lsp1-get-inbound-liquidity-for-mobile-clients/)
- [LNServer](https://lnserver.com/)
