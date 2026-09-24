# Running the regtest beta

Install **Winnow Lightning**, bundle `com.btcswift.lightning`, from the existing
**PQLN Regtest Internal** TestFlight group. This update preserves older app data
and starts a separate regtest wallet; it does not migrate or delete older keys.
Use valueless regtest coins. Keep the app open while monitoring channels. A seed
cannot restore its channels, so retain each device and its app data.

## A provider you control

The beta has no shared hosted service. Run the following on an Apple-silicon Mac
on the same LAN as the phone. It uses Winnow for Bitcoin P2P, wallet funding,
filter verification and broadcasts. Bitcoin Core RPC is only for creating the
lab chain, funding addresses and mining blocks.

1. Build: `scripts/build-lightning.sh --all`, then
   `swift build --package-path Lightning --product winnow-lightning-lab`.
2. Run Bitcoin Core with a **new, dedicated** regtest data directory, compact
   filter index (`blockfilterindex=1`) and filter serving (`peerblockfilters=1`).
   Bind Bitcoin P2P to your LAN interface (e.g. port 18444). Keep RPC on localhost;
   never expose RPC to the phone. Mine 101 blocks to a Core lab wallet, then mine
   each deposit and six confirmations for channel funding.
3. Create one config per lab node, changing its Lightning port:

   ```json
   {"bitcoin_host":"192.168.1.10","bitcoin_port":18444,
    "listen_port":19735,"advertised_host":"192.168.1.10","provider":true}
   ```

4. Run `swift run --skip-build --package-path Lightning winnow-lightning-lab A.json lab/A`.
   Keep this process and its state directory. Fund the printed Winnow address
   with at least 600,000 regtest sats, mine a block, and enter
   `{"command":"status"}` until its wallet balance appears. The seed and channel
   files are deliberately local to this disposable lab; never use real coins.
5. In the app select the regtest network, configure its Bitcoin peer to the Mac's
   LAN address and Bitcoin P2P port, and allow Local Network access. Create/fund a
   fresh wallet. Open Settings → Lightning, unlock, and wait for scan catch-up.
6. Obtain `lab/A/public-peer-card.json` directly from the operator, paste it into
   the app's Peer section, enter A's LAN host/port and choose Pin keys and connect.
   Share the app's **public peer card** back to the operator. Save it as a file and
   enter `{"command":"pin","card_file":"/absolute/path/app-card.json"}` at A.
   A claim string never supplies a replacement trust key.

Commands accept one JSON object per line. `connect` takes `card_file`, `host`,
`port`; `open` takes `node_id`, `amount_sat`; `status` reports public state;
`stop` closes the lab cleanly. Opening a channel expressly authorizes this lab
wallet to select/sign its funding inputs and broadcast when the protocol allows.
The app instead shows its own funding review. Wait for the channel's `usable`
state on both ends before payments.

## Four-node message payment

Use topology **sender S — provider A — provider B — recipient R**, with no
channel between A and R. A runs with `provider:true`; B and any desktop client
use `provider:false`. A and B have `forwarding` enabled in the lab. Exchange and
pin each public peer card through the operator before use.

- Connect A to B and B to R (R can initiate the socket to B). Fund 200,000-sat
  channels A→B and B→R using `open`, mining six confirmations per channel.
- Fund S→A from the sender app's Winnow wallet. If the sender is a desktop lab
  client, connect and open its channel in the same way.
- R also pins and connects A for authenticated claim control. This connection
  does not open an A→R channel. A must have R's pinned invoice signature key.
- On S: **Send or receive by message → Get claim quote**. Review the amount,
  fixed 100-sat provider fee and deadline, then commit. Share becomes available
  only after the committed hold is verified. Choose Share, Copy, or a `.wlnclaim`
  file in your preferred messenger. Claims are about 14 KB; use a file for a
  messenger with a smaller text limit.
- Stop S after sharing. On R, paste or import the exact claim, review it, and
  choose Claim payment. Wait for **Payment received**. Reopen S and reconnect A
  to observe **Payment settled**. Imported text or a provider acknowledgment
  alone is not a payment receipt.

A desktop S can use `prepare` with `request_id`, `node_id` (A), `host`, `port`,
`amount_sat`, then `commit` with the returned `claim_id`. `export` takes that ID
and a **new** absolute `file` path. A desktop R uses `import` with that file,
then `redeem` with the claim ID. These explicit commands print public summaries;
they do not print bearer secrets. Delete exported copies when finished.

Anyone holding a copy can race to claim, including the sender. Re-share repeats
the same claim; it does not issue another payment. Unfunded quotes can be
discarded. Funded claims cannot be cancelled early. The claim window ends after
one hour or 72 blocks, whichever arrives first; funds remain pending until the
channel actually settles or resolves its HTLC timeout. If peers disappear,
reconnect them and keep monitoring the chain; do not reset wallet/channel data.

## Reproducible simulator evidence

The existing CI Lightning job runs the base funding/payment/restart/close video
and separate sender and recipient recordings with the same app build. Run the
same wrapper locally with `UI_TEST_SELECTION` set to either
`WinnowLightningUITests/WinnowLightningUITests/testSenderSharesFundedClaimAndReturns`
or `WinnowLightningUITests/WinnowLightningUITests/testRecipientClaimsWhileSenderIsStopped`.
The default is the original channel journey. Use a fresh results directory each
time. Each journey retains a continuous video, screenshots, `.xcresult`, logs and
a digest manifest. It never uploads fixture wallets or bearer handoff files.
