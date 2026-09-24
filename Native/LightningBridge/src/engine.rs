use bitcoin::{
    consensus::{deserialize, serialize},
    hashes::{sha256, Hash},
    secp256k1::PublicKey,
    Block, BlockHash, Network, Script, ScriptBuf, Transaction, Txid,
};
use lightning::{
    chain::{
        chaininterface::{BroadcasterInterface, ConfirmationTarget, FeeEstimator, TransactionType},
        chainmonitor::ChainMonitor,
        channelmonitor::ChannelMonitor,
        BlockLocator, Confirm, Filter, Listen, Watch, WatchedOutput,
    },
    events::{Event, EventsProvider, InboundChannelFunds, ReplayEvent},
    ln::{
        channel_state::ChannelDetails,
        channelmanager::{
            Bolt11InvoiceParameters, ChainParameters, ChannelManager, ChannelManagerReadArgs,
            OptionalBolt11PaymentParams, PaymentId, RecentPaymentDetails,
        },
        outbound_payment::Retry,
        peer_handler::{IgnoringMessageHandler, PeerManager, SocketDescriptor},
        types::ChannelId,
    },
    onion_message::messenger::DefaultMessageRouter,
    routing::{
        gossip::NetworkGraph,
        router::{DefaultRouter, InFlightHtlcs, Route, RouteParameters, Router},
        scoring::{
            ProbabilisticScorer, ProbabilisticScoringDecayParameters,
            ProbabilisticScoringFeeParameters,
        },
    },
    sign::{
        EntropySource, InMemorySigner, KeysManager, NodeSigner, OutputSpender, Recipient,
        SpendableOutputDescriptor,
    },
    util::{
        config::UserConfig,
        logger::{Logger, Record},
        persist::{read_channel_monitors, KVStoreSync},
        ser::{Readable, ReadableArgs, Writeable},
    },
};
use lightning_invoice::{Bolt11Invoice, Currency};
use lightning_persister::fs_store::v1::FilesystemStore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{File, OpenOptions},
    hash::{Hash as StdHash, Hasher},
    path::PathBuf,
    str::FromStr,
    sync::{
        atomic::{AtomicBool, AtomicU32, Ordering},
        Arc, Mutex, RwLock,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

type Result<T> = std::result::Result<T, String>;
type Monitor = ChainMonitor<
    InMemorySigner,
    Arc<Services>,
    Arc<Services>,
    Arc<Services>,
    Arc<QuietLogger>,
    Arc<FilesystemStore>,
    Arc<KeysManager>,
>;
type Scorer = ProbabilisticScorer<Arc<NetworkGraph<Arc<QuietLogger>>>, Arc<QuietLogger>>;
type BaseRouter = DefaultRouter<
    Arc<NetworkGraph<Arc<QuietLogger>>>,
    Arc<QuietLogger>,
    Arc<KeysManager>,
    Arc<RwLock<Scorer>>,
    ProbabilisticScoringFeeParameters,
    Scorer,
>;
type Manager = ChannelManager<
    Arc<Monitor>,
    Arc<Services>,
    Arc<KeysManager>,
    Arc<KeysManager>,
    Arc<KeysManager>,
    Arc<Services>,
    Arc<PinnedRouter>,
    Arc<
        DefaultMessageRouter<
            Arc<NetworkGraph<Arc<QuietLogger>>>,
            Arc<QuietLogger>,
            Arc<KeysManager>,
        >,
    >,
    Arc<QuietLogger>,
>;

// Regtest private channels do not use public gossip. The caller explicitly
// pins both PQ keys out of band; no self-asserted invoice key becomes trusted.
struct PinnedRouter {
    base: BaseRouter,
    services: Arc<Services>,
}
impl Router for PinnedRouter {
    fn find_route(
        &self,
        payer: &PublicKey,
        params: &RouteParameters,
        first_hops: Option<&[&ChannelDetails]>,
        inflight: InFlightHtlcs,
    ) -> std::result::Result<Route, &'static str> {
        self.base.find_route(payer, params, first_hops, inflight)
    }
    fn pq_kem_key_for_node(&self, node: &PublicKey) -> Option<[u8; 1184]> {
        hex::decode(
            &self
                .services
                .journal
                .lock()
                .ok()?
                .pins
                .get(&node.to_string())?
                .kem_key,
        )
        .ok()?
        .try_into()
        .ok()
    }
    fn pq_node_id_for_node(&self, node: &PublicKey) -> Option<[u8; 1312]> {
        hex::decode(
            &self
                .services
                .journal
                .lock()
                .ok()?
                .pins
                .get(&node.to_string())?
                .signature_key,
        )
        .ok()?
        .try_into()
        .ok()
    }
    fn create_blinded_payment_paths<
        T: bitcoin::secp256k1::Signing + bitcoin::secp256k1::Verification,
    >(
        &self,
        recipient: PublicKey,
        key: lightning::sign::ReceiveAuthKey,
        hops: Vec<ChannelDetails>,
        tlvs: lightning::blinded_path::payment::ReceiveTlvs,
        amount: Option<u64>,
        ctx: &bitcoin::secp256k1::Secp256k1<T>,
    ) -> std::result::Result<Vec<lightning::blinded_path::payment::BlindedPaymentPath>, ()> {
        self.base
            .create_blinded_payment_paths(recipient, key, hops, tlvs, amount, ctx)
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
struct PeerPin {
    kem_key: String,
    signature_key: String,
}

type Peers = PeerManager<
    Socket,
    Arc<Manager>,
    IgnoringMessageHandler,
    IgnoringMessageHandler,
    Arc<QuietLogger>,
    IgnoringMessageHandler,
    Arc<KeysManager>,
    Arc<Monitor>,
>;

// No private protocol data is logged across the FFI boundary.
struct QuietLogger;
impl Logger for QuietLogger {
    fn log(&self, _: Record) {}
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub network: String,
    pub storage_path: PathBuf,
    pub fee_sat_per_kw: u32,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
struct Journal {
    events: BTreeMap<String, Value>,
    watches: BTreeMap<String, Value>,
    submitted: BTreeMap<String, String>,
    watch_revision: u64,
    next_scan: u32,
    pins: BTreeMap<String, PeerPin>,
    invoices: BTreeMap<String, Value>,
    payments: BTreeMap<String, Value>,
    receipts: BTreeMap<String, String>,
    wallet_scripts: BTreeSet<String>,
    spendable: BTreeMap<String, Vec<String>>,
    sweeps: BTreeMap<String, Value>,
    closing: BTreeMap<String, Value>,
}

impl Default for Journal {
    fn default() -> Self {
        Self {
            events: BTreeMap::new(),
            watches: BTreeMap::new(),
            submitted: BTreeMap::new(),
            watch_revision: 0,
            next_scan: 1,
            pins: BTreeMap::new(),
            invoices: BTreeMap::new(),
            payments: BTreeMap::new(),
            receipts: BTreeMap::new(),
            wallet_scripts: BTreeSet::new(),
            spendable: BTreeMap::new(),
            sweeps: BTreeMap::new(),
            closing: BTreeMap::new(),
        }
    }
}

struct Services {
    store: Arc<FilesystemStore>,
    journal: Mutex<Journal>,
    fee: AtomicU32,
    failed: AtomicBool,
}

impl Services {
    fn register_watch(&self, key: String, value: Value) {
        self.update(|j| {
            if j.watches.get(&key) != Some(&value) {
                j.watches.insert(key, value);
                j.watch_revision = j
                    .watch_revision
                    .checked_add(1)
                    .expect("watch revision exhausted");
                // The initial regtest implementation replays from genesis,
                // using Winnow's scanner and no retained filter-body archive.
                j.next_scan = 1;
            }
        })
        .expect("Lightning watch persistence failed");
    }
    fn update(&self, f: impl FnOnce(&mut Journal)) -> Result<()> {
        let mut journal = self.journal.lock().map_err(|_| "journal unavailable")?;
        if self.failed.load(Ordering::Relaxed) {
            return Err("Lightning storage stopped".into());
        }
        let mut candidate = journal.clone();
        f(&mut candidate);
        if self
            .store
            .write(
                "winnow",
                "",
                "journal",
                serde_json::to_vec(&candidate).map_err(|_| "encode journal")?,
            )
            .is_err()
        {
            self.failed.store(true, Ordering::Relaxed);
            return Err("could not persist Lightning journal".into());
        }
        *journal = candidate;
        Ok(())
    }
    fn event(&self, event: Value) -> Result<()> {
        let id =
            <sha256::Hash as Hash>::hash(&serde_json::to_vec(&event).map_err(|_| "encode event")?)
                .to_string();
        self.update(|j| {
            j.events.insert(id, event);
        })
    }
}

impl FeeEstimator for Services {
    fn get_est_sat_per_1000_weight(&self, _: ConfirmationTarget) -> u32 {
        self.fee.load(Ordering::Relaxed)
    }
}
impl BroadcasterInterface for Services {
    fn broadcast_transactions(&self, txs: &[(&Transaction, TransactionType)]) {
        // Preserve the entire package. Swift must acknowledge only after its
        // relay durably accepts it; a multi-transaction package is not a list
        // of independent broadcasts.
        let transactions: Vec<String> = txs
            .iter()
            .map(|(tx, _)| hex::encode(serialize(tx)))
            .collect();
        self.event(json!({"kind":"broadcast", "transactions":transactions}))
            .expect("Lightning broadcast persistence failed");
    }
}
impl Filter for Services {
    fn register_tx(&self, txid: &Txid, script_pubkey: &Script) {
        self.register_watch(
            format!("tx:{txid}"),
            json!({"txid":txid.to_string(), "script":hex::encode(script_pubkey.as_bytes())}),
        );
    }
    fn register_output(&self, output: WatchedOutput) {
        self.register_watch(
            format!("output:{}", output.outpoint),
            json!({"txid":output.outpoint.txid.to_string(), "vout":output.outpoint.index,
                "script":hex::encode(output.script_pubkey.as_bytes()),
                "block_hash":output.block_hash.map(|h| h.to_string())}),
        );
    }
}

#[derive(Default)]
struct SocketState {
    sequence: u64,
    bytes: Vec<u8>,
    resume_read: bool,
    closed: bool,
}
#[derive(Clone)]
struct Socket {
    id: u64,
    state: Arc<Mutex<SocketState>>,
}
impl PartialEq for Socket {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}
impl Eq for Socket {}
impl StdHash for Socket {
    fn hash<H: Hasher>(&self, h: &mut H) {
        self.id.hash(h);
    }
}
impl SocketDescriptor for Socket {
    fn send_data(&mut self, data: &[u8], resume_read: bool) -> usize {
        let mut state = self.state.lock().unwrap();
        state.resume_read = resume_read;
        if state.closed {
            return 0;
        }
        let count = data
            .len()
            .min(1_048_576_usize.saturating_sub(state.bytes.len()));
        state.bytes.extend_from_slice(&data[..count]);
        count
    }
    fn disconnect_socket(&mut self) {
        self.state.lock().unwrap().closed = true;
    }
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Status,
    Drain,
    /// A connected byte stream supplied by Swift. The KEM key is an out-of-band pin.
    Connect {
        connection: u64,
        node_id: String,
        kem_key: String,
    },
    Accept {
        connection: u64,
    },
    Read {
        connection: u64,
        bytes: String,
    },
    Disconnect {
        connection: u64,
    },
    OpenChannel {
        node_id: String,
        amount_sat: u64,
        user_channel_id: u64,
    },
    SubmitFunding {
        temporary_channel_id: String,
        node_id: String,
        transaction: String,
    },
    Acknowledge {
        event_id: String,
    },
    /// Every height, including empty matched-transaction sets, must be delivered
    /// in order after Winnow verifies that height's filter.
    BlockConnected {
        block: String,
        height: u32,
    },
    ScannedBlock {
        header: String,
        block: Option<String>,
        height: u32,
        watch_revision: u64,
    },
    BlocksDisconnected {
        block_hash: String,
        height: u32,
    },
    PinPeer {
        node_id: String,
        kem_key: String,
        signature_key: String,
    },
    CreateInvoice {
        request_id: String,
        amount_msat: u64,
    },
    PayInvoice {
        invoice: String,
        amount_msat: u64,
        max_fee_msat: u64,
    },
    CloseChannel {
        channel_id: String,
        node_id: String,
        script: String,
    },
    ForceClose {
        channel_id: String,
        node_id: String,
    },
    SweepOutputs {
        event_id: String,
        script: String,
    },
    SetFee {
        sat_per_kw: u32,
    },
    Tick,
}

pub struct Engine {
    manager: Arc<Manager>,
    monitor: Arc<Monitor>,
    peers: Peers,
    services: Arc<Services>,
    keys: Arc<KeysManager>,
    sockets: BTreeMap<u64, Socket>,
    tip: BlockLocator,
    recovering: Vec<ChannelMonitor<InMemorySigner>>,
    recovery_height: u32,
    last_forward: Instant,
    next_forward: Duration,
    last_peer_tick: Instant,
    last_manager_tick: Instant,
    _lock: File,
    pub poisoned: bool,
}

impl Engine {
    pub fn new(config: Config, seed: &[u8; 32]) -> Result<Self> {
        if config.network != "regtest" {
            return Err("Lightning is restricted to regtest".into());
        }
        if !(253..=2_500_000).contains(&config.fee_sat_per_kw) {
            return Err("invalid sat/kw fee".into());
        }
        if !config.storage_path.is_absolute() {
            return Err("storage path must be absolute".into());
        }
        std::fs::create_dir_all(&config.storage_path).map_err(|_| "create storage directory")?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(config.storage_path.join("engine.lock"))
            .map_err(|_| "open storage lock")?;
        fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "Lightning storage is already open")?;
        let store = Arc::new(FilesystemStore::new(config.storage_path));
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "system clock")?;
        let keys = Arc::new(KeysManager::new(
            seed,
            now.as_secs(),
            now.subsec_nanos(),
            true,
        ));
        let identity = keys
            .get_node_id(Recipient::Node)
            .map_err(|_| "node identity")?
            .serialize();
        match store.read("winnow", "", "identity") {
            Ok(saved) if saved != identity => {
                return Err("seed does not match Lightning storage".into())
            }
            Ok(_) => {}
            Err(e) if e.kind() == bitcoin::io::ErrorKind::NotFound => {
                store
                    .write("winnow", "", "identity", identity.to_vec())
                    .map_err(|_| "persist identity")?;
            }
            Err(_) => return Err("read identity".into()),
        }
        let journal = match store.read("winnow", "", "journal") {
            Ok(data) => serde_json::from_slice(&data).map_err(|_| "damaged Lightning journal")?,
            Err(e) if e.kind() == bitcoin::io::ErrorKind::NotFound => Journal::default(),
            Err(_) => return Err("read Lightning journal".into()),
        };
        let has_journal_state = !journal.events.is_empty()
            || !journal.watches.is_empty()
            || !journal.submitted.is_empty();
        let services = Arc::new(Services {
            store: store.clone(),
            journal: Mutex::new(journal),
            fee: AtomicU32::new(config.fee_sat_per_kw),
            failed: AtomicBool::new(false),
        });
        let logger = Arc::new(QuietLogger);
        let monitor = Arc::new(Monitor::new(
            Some(services.clone()),
            services.clone(),
            logger.clone(),
            services.clone(),
            store.clone(),
            keys.clone(),
            keys.get_peer_storage_key(),
            false,
        ));
        let graph = Arc::new(NetworkGraph::new(Network::Regtest, logger.clone()));
        let scorer = Arc::new(RwLock::new(ProbabilisticScorer::new(
            ProbabilisticScoringDecayParameters::default(),
            graph.clone(),
            logger.clone(),
        )));
        let router = Arc::new(PinnedRouter {
            services: services.clone(),
            base: DefaultRouter::new(
                graph.clone(),
                logger.clone(),
                keys.clone(),
                scorer,
                ProbabilisticScoringFeeParameters::default(),
            ),
        });
        let message_router = Arc::new(DefaultMessageRouter::new(graph, keys.clone()));
        let mut config = UserConfig::default();
        // Initial regtest channel type avoids anchor wallet/package fee-bumping
        // requirements. No ordinary Bitcoin wallet is constructed by this core.
        config
            .channel_handshake_config
            .negotiate_anchors_zero_fee_htlc_tx = false;
        config.channel_handshake_config.announce_for_forwarding = false;
        // Swift supplies a fresh Winnow destination when the user closes.
        config
            .channel_handshake_config
            .commit_upfront_shutdown_pubkey = false;
        config.require_post_quantum_payments = true;
        config.require_post_quantum_inbound = true;
        let monitors = read_channel_monitors(store.clone(), keys.clone(), keys.clone())
            .map_err(|_| "read channel monitors")?;
        let (tip, manager) = match store.read("", "", "manager") {
            Ok(data) => {
                let args = ChannelManagerReadArgs::new(
                    keys.clone(),
                    keys.clone(),
                    keys.clone(),
                    services.clone(),
                    monitor.clone(),
                    services.clone(),
                    router,
                    message_router,
                    logger.clone(),
                    config,
                    monitors.iter().map(|(_, m)| m).collect(),
                );
                <(BlockLocator, Manager)>::read(&mut bitcoin::io::Cursor::new(data), args)
                    .map_err(|_| "read channel manager")?
            }
            Err(e)
                if e.kind() == bitcoin::io::ErrorKind::NotFound
                    && monitors.is_empty()
                    && !has_journal_state =>
            {
                let tip = BlockLocator::from_network(Network::Regtest);
                let manager = Manager::new(
                    services.clone(),
                    monitor.clone(),
                    services.clone(),
                    router,
                    message_router,
                    logger.clone(),
                    keys.clone(),
                    keys.clone(),
                    keys.clone(),
                    config,
                    ChainParameters {
                        network: Network::Regtest,
                        best_block: tip,
                    },
                    now.as_secs() as u32,
                );
                (tip, manager)
            }
            Err(_) => return Err("missing or unreadable channel manager".into()),
        };
        // As in LDK's block-sync initialization, catch up independently
        // persisted monitors before giving them to the live ChainMonitor.
        let recovery_height = monitors
            .iter()
            .map(|(position, _)| position.height)
            .fold(tip.height, u32::max);
        let mut recovering = Vec::new();
        for (_, channel) in monitors {
            channel.load_outputs_to_watch(services.as_ref(), logger.as_ref());
            if recovery_height == 0 {
                monitor
                    .watch_channel(channel.channel_id(), channel)
                    .map_err(|_| "restore channel monitor")?;
            } else {
                recovering.push(channel);
            }
        }
        let manager = Arc::new(manager);
        let peers = Peers::new_channel_only(
            manager.clone(),
            IgnoringMessageHandler {},
            now.as_secs() as u32,
            &keys.get_secure_random_bytes(),
            logger,
            keys.clone(),
            monitor.clone(),
        );
        let engine = Self {
            manager,
            monitor,
            peers,
            services,
            keys,
            sockets: BTreeMap::new(),
            tip,
            recovering,
            recovery_height,
            last_forward: Instant::now(),
            next_forward: Duration::from_millis(150),
            last_peer_tick: Instant::now(),
            last_manager_tick: Instant::now(),
            _lock: lock,
            poisoned: false,
        };
        // Rebuild the consumer's coverage after every restart. WalletCore
        // validates the saved tip against its own header chain before replay.
        engine.services.update(|j| j.next_scan = 1)?;
        engine.checkpoint()?;
        Ok(engine)
    }

    fn checkpoint(&self) -> Result<()> {
        self.services
            .store
            .write("", "", "manager", self.manager.encode())
            .map_err(|_| "persist channel manager".into())
    }

    fn process(&self) -> Result<()> {
        // ChannelManager may have queued monitor updates during deserialization.
        // Never process them against an incompletely restored monitor set.
        if !self.recovering.is_empty() {
            return self.checkpoint();
        }
        let handler = |event: Event| -> std::result::Result<(), ReplayEvent> {
            let value = match event {
                Event::OpenChannelRequest {
                    temporary_channel_id,
                    counterparty_node_id,
                    channel_type,
                    channel_negotiation_type,
                    funding_satoshis,
                    is_announced,
                    ..
                } => {
                    if self.manager.list_channels().len() >= 8
                        || is_announced
                        || !(20_000..=16_777_215).contains(&funding_satoshis)
                        || channel_type.supports_anchors_zero_fee_htlc_tx()
                        || channel_type.supports_anchors_nonzero_fee_htlc_tx()
                        || channel_type.supports_zero_conf()
                        || matches!(channel_negotiation_type, InboundChannelFunds::DualFunded)
                    {
                        self.manager
                            .force_close_broadcasting_latest_txn(
                                &temporary_channel_id,
                                &counterparty_node_id,
                                "Unsupported research channel type or capacity".into(),
                            )
                            .map_err(|_| ReplayEvent())?;
                        return Ok(());
                    }
                    let id = u128::from_be_bytes(
                        self.keys.get_secure_random_bytes()[..16]
                            .try_into()
                            .unwrap(),
                    );
                    self.manager
                        .accept_inbound_channel(
                            &temporary_channel_id,
                            &counterparty_node_id,
                            id,
                            None,
                        )
                        .map_err(|_| ReplayEvent())?;
                    return Ok(());
                }
                Event::FundingGenerationReady {
                    temporary_channel_id,
                    counterparty_node_id,
                    channel_value_satoshis,
                    output_script,
                    user_channel_id,
                    ..
                } => {
                    json!({"kind":"funding", "temporary_channel_id":temporary_channel_id.to_string(),
                        "node_id":counterparty_node_id.to_string(), "amount_sat":channel_value_satoshis,
                        "script":hex::encode(output_script.as_bytes()), "user_channel_id":user_channel_id.to_string()})
                }
                Event::ChannelReady { channel_id, .. } => {
                    json!({"kind":"channel_ready", "channel_id":channel_id.to_string()})
                }
                Event::ChannelPending { channel_id, .. } => {
                    json!({"kind":"channel_pending", "channel_id":channel_id.to_string()})
                }
                Event::ChannelClosed { channel_id, .. } => {
                    json!({"kind":"channel_closed", "channel_id":channel_id.to_string()})
                }
                Event::SpendableOutputs {
                    outputs,
                    channel_id,
                    ..
                } => {
                    let native_outputs: Vec<_> = outputs
                        .iter()
                        .filter(|output| {
                            if let SpendableOutputDescriptor::StaticOutput { output, .. } = output {
                                !self
                                    .services
                                    .journal
                                    .lock()
                                    .unwrap()
                                    .wallet_scripts
                                    .contains(&hex::encode(output.script_pubkey.as_bytes()))
                            } else {
                                true
                            }
                        })
                        .map(|output| hex::encode(output.encode()))
                        .collect();
                    if native_outputs.is_empty() {
                        return Ok(());
                    }
                    let id =
                        <sha256::Hash as Hash>::hash(&serde_json::to_vec(&native_outputs).unwrap())
                            .to_string();
                    if self
                        .services
                        .journal
                        .lock()
                        .unwrap()
                        .sweeps
                        .contains_key(&id)
                    {
                        return Ok(());
                    }
                    self.services
                        .update(|j| {
                            j.spendable.insert(id.clone(), native_outputs);
                        })
                        .map_err(|_| ReplayEvent())?;
                    json!({"kind":"sweep_required", "output_id":id, "channel_id":channel_id.map(|c| c.to_string())})
                }
                Event::PaymentClaimable { purpose, .. } => {
                    let preimage = purpose.preimage().ok_or(ReplayEvent())?;
                    self.manager.claim_funds(preimage);
                    return Ok(());
                }
                Event::PaymentClaimed {
                    payment_hash,
                    amount_msat,
                    ..
                } => {
                    json!({"kind":"payment_received", "payment_hash":payment_hash.to_string(), "amount_msat":amount_msat})
                }
                Event::PaymentSent {
                    payment_hash,
                    payment_preimage,
                    amount_msat,
                    fee_paid_msat,
                    ..
                } => {
                    let hash = payment_hash.to_string();
                    self.services
                        .update(|j| {
                            j.receipts
                                .insert(hash.clone(), hex::encode(payment_preimage.0));
                            if let Some(record) = j.payments.get_mut(&hash) {
                                record["state"] = json!("sent");
                                record["fee_paid_msat"] = json!(fee_paid_msat);
                            }
                        })
                        .map_err(|_| ReplayEvent())?;
                    json!({"kind":"payment_sent", "payment_hash":hash, "amount_msat":amount_msat, "fee_paid_msat":fee_paid_msat})
                }
                Event::PaymentFailed { payment_hash, .. } => {
                    let hash = payment_hash.ok_or(ReplayEvent())?.to_string();
                    let mut sent = false;
                    self.services
                        .update(|j| {
                            sent = j.receipts.contains_key(&hash);
                            if !sent {
                                if let Some(record) = j.payments.get_mut(&hash) {
                                    record["state"] = json!("failed");
                                }
                            }
                        })
                        .map_err(|_| ReplayEvent())?;
                    if sent {
                        return Ok(());
                    }
                    json!({"kind":"payment_failed", "payment_hash":hash})
                }
                Event::PaymentPathSuccessful { .. } | Event::PaymentPathFailed { .. } => {
                    return Ok(())
                }
                // Preserve unimplemented event types in LDK for replay. Never
                // claim that spendable outputs or payment claims were handled.
                _ => return Err(ReplayEvent()),
            };
            self.services
                .event(value)
                .expect("Lightning event persistence failed");
            Ok(())
        };
        self.monitor.process_pending_events(&handler);
        self.manager.process_pending_events(&handler);
        self.peers.process_events();
        self.checkpoint()
    }

    fn scanned_block(
        &mut self,
        header: bitcoin::block::Header,
        block: Option<Block>,
        height: u32,
        watch_revision: u64,
    ) -> Result<()> {
        {
            let journal = self.services.journal.lock().unwrap();
            if journal.watch_revision != watch_revision {
                return Err("watch revision changed".into());
            }
            if journal.next_scan != height {
                return Err("scan restart required".into());
            }
        }
        if height > self.tip.height
            && (height != self.tip.height.checked_add(1).ok_or("height overflow")?
                || header.prev_blockhash != self.tip.block_hash)
        {
            return Err("noncontiguous chain update".into());
        }
        if height == self.tip.height && header.block_hash() != self.tip.block_hash {
            return Err("rollback required before replacement confirmations".into());
        }
        if let Some(ref block) = block {
            if block.header != header
                || !block.check_merkle_root()
                || !block.check_witness_commitment()
            {
                return Err("invalid block commitments".into());
            }
            // Supply the complete matched block, including descendants of
            // outputs registered while a monitor processes its parent.
            // Confirm explicitly supports historical confirmations after a
            // tip update; repeated same-chain confirmations are idempotent.
            let txdata: Vec<_> = block.txdata.iter().enumerate().collect();
            self.monitor
                .transactions_confirmed(&header, &txdata, height);
            self.manager
                .transactions_confirmed(&header, &txdata, height);
        }
        for channel in &self.recovering {
            if height > channel.current_best_block().height {
                let txdata: Vec<_> = block
                    .as_ref()
                    .map(|b| b.txdata.iter().enumerate().collect())
                    .unwrap_or_default();
                channel.block_connected(
                    &header,
                    &txdata,
                    height,
                    &self.services,
                    &self.services,
                    &QuietLogger,
                );
                channel.load_outputs_to_watch(self.services.as_ref(), &QuietLogger);
            }
        }
        if height > self.tip.height {
            self.monitor.best_block_updated(&header, height);
            self.manager.best_block_updated(&header, height);
            self.tip.advance(header.block_hash());
        }
        if !self.recovering.is_empty() && height >= self.recovery_height {
            for channel in std::mem::take(&mut self.recovering) {
                // Persist the reconciled monitor before any pending channel
                // update or peer packet can be processed.
                self.monitor
                    .watch_channel(channel.channel_id(), channel)
                    .map_err(|_| "restore reconciled monitor")?;
            }
        }
        self.services.update(|j| {
            // A watch added by this block needs historical coverage too. Do
            // not overwrite its rewind with this older watch-set's progress.
            if j.watch_revision == watch_revision {
                j.next_scan = height.checked_add(1).expect("scan height exhausted");
            }
        })
    }

    pub fn status(&self) -> Value {
        let journal = self.services.journal.lock().unwrap();
        json!({"abi":1, "core_revision":crate::CORE_REVISION, "network":"regtest",
            "fee_sat_per_kw":self.services.fee.load(Ordering::Relaxed),
            "node_id":self.keys.get_node_id(Recipient::Node).unwrap().to_string(),
            "kem_key":self.keys.get_pq_kem_node_id().map(hex::encode),
            "signature_key":self.keys.get_pq_node_id().map(hex::encode),
            "height":self.tip.height, "block_hash":self.tip.block_hash.to_string(),
            "watch_revision":journal.watch_revision, "scan_next":journal.next_scan,
            "chain_ready":journal.next_scan > self.tip.height && self.recovering.is_empty(),
            "chain_positions":std::iter::once(self.tip).chain(self.recovering.iter().map(|m| m.current_best_block()))
                .map(|p| json!({"height":p.height,"block_hash":p.block_hash.to_string(),
                    "previous_blocks":p.previous_blocks.map(|h| h.map(|v| v.to_string()))})).collect::<Vec<_>>(),
            "events":journal.events, "watches":journal.watches,
            "invoices":journal.invoices, "payments":journal.payments, "sweeps":journal.sweeps,
            "close_destinations":journal.closing.iter().map(|(id, intent)| (id.clone(), intent["script"].clone())).collect::<BTreeMap<_,_>>(),
            "peers":self.peers.list_peers().iter().map(|p| p.counterparty_node_id.to_string()).collect::<Vec<_>>(),
            "channels":self.manager.list_channels().iter().map(|c| json!({
                "channel_id":c.channel_id.to_string(), "node_id":c.counterparty.node_id.to_string(),
                "amount_sat":c.channel_value_satoshis, "ready":c.is_channel_ready, "usable":c.is_usable,
                "funding_txid":c.funding_txo.map(|o| o.txid.to_string())})).collect::<Vec<_>>()})
    }

    fn socket(&mut self, id: u64) -> Result<Socket> {
        if id == 0 || self.sockets.contains_key(&id) || self.sockets.len() >= 16 {
            return Err("invalid or duplicate connection".into());
        }
        let socket = Socket {
            id,
            state: Arc::new(Mutex::new(SocketState {
                resume_read: true,
                ..Default::default()
            })),
        };
        self.sockets.insert(id, socket.clone());
        Ok(socket)
    }

    pub fn call(&mut self, command: Command) -> Result<Value> {
        if self.poisoned || self.services.failed.load(Ordering::Relaxed) {
            return Err("engine stopped after storage or native failure; reopen required".into());
        }
        if matches!(
            &command,
            Command::Connect { .. }
                | Command::Accept { .. }
                | Command::Read { .. }
                | Command::OpenChannel { .. }
                | Command::SubmitFunding { .. }
                | Command::Tick
                | Command::CreateInvoice { .. }
                | Command::PayInvoice { .. }
                | Command::CloseChannel { .. }
                | Command::ForceClose { .. }
                | Command::SweepOutputs { .. }
        ) && (!self.recovering.is_empty()
            || self.services.journal.lock().unwrap().next_scan <= self.tip.height)
        {
            return Err("chain catch-up required".into());
        }
        match command {
            Command::Status => return Ok(self.status()),
            Command::Connect {
                connection,
                node_id,
                kem_key,
            } => {
                let node = PublicKey::from_str(&node_id).map_err(|_| "invalid node id")?;
                if let Some(pin) = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .pins
                    .get(&node.to_string())
                {
                    if pin.kem_key != kem_key.to_lowercase() {
                        return Err("peer key differs from pin".into());
                    }
                }
                let kem = hex::decode(kem_key)
                    .map_err(|_| "invalid KEM pin")?
                    .try_into()
                    .map_err(|_| "invalid KEM pin length")?;
                let socket = self.socket(connection)?;
                match self
                    .peers
                    .new_outbound_connection_pq(node, socket.clone(), None, kem)
                {
                    Ok(act) => socket.state.lock().unwrap().bytes.extend(act),
                    Err(_) => {
                        self.sockets.remove(&connection);
                        return Err("PQ connection rejected".into());
                    }
                }
            }
            Command::Accept { connection } => {
                let socket = self.socket(connection)?;
                if self.peers.new_inbound_connection_pq(socket, None).is_err() {
                    self.sockets.remove(&connection);
                    return Err("PQ connection rejected".into());
                }
            }
            Command::Read { connection, bytes } => {
                let mut socket = self
                    .sockets
                    .get(&connection)
                    .cloned()
                    .ok_or("unknown connection")?;
                let data = hex::decode(bytes).map_err(|_| "invalid peer bytes")?;
                if data.len() > 65_536 {
                    return Err("peer input exceeds 64 KiB".into());
                }
                if !socket.state.lock().unwrap().resume_read {
                    return Err("peer input is paused".into());
                }
                match self.peers.read_event(&mut socket, &data) {
                    Ok(()) => {}
                    Err(_) => {
                        self.sockets.remove(&connection);
                        return Err("peer disconnected after protocol error".into());
                    }
                }
            }
            Command::Disconnect { connection } => {
                if let Some(socket) = self.sockets.remove(&connection) {
                    self.peers.socket_disconnected(&socket);
                }
            }
            Command::OpenChannel {
                node_id,
                amount_sat,
                user_channel_id,
            } => {
                if !(20_000..=16_777_215).contains(&amount_sat)
                    || self.manager.list_channels().len() >= 8
                {
                    return Err("invalid regtest channel capacity or channel limit".into());
                }
                self.manager
                    .create_channel(
                        PublicKey::from_str(&node_id).map_err(|_| "invalid node id")?,
                        amount_sat,
                        0,
                        user_channel_id.into(),
                        None,
                        None,
                    )
                    .map_err(|_| "channel creation rejected")?;
            }
            Command::SubmitFunding {
                temporary_channel_id,
                node_id,
                transaction,
            } => {
                let id = ChannelId::from_bytes(
                    hex::decode(&temporary_channel_id)
                        .map_err(|_| "invalid channel id")?
                        .try_into()
                        .map_err(|_| "invalid channel id length")?,
                );
                let node = PublicKey::from_str(&node_id).map_err(|_| "invalid node id")?;
                let raw = hex::decode(&transaction).map_err(|_| "invalid funding bytes")?;
                if raw.len() > 400_000 {
                    return Err("funding transaction exceeds limit".into());
                }
                let tx: Transaction =
                    deserialize(&raw).map_err(|_| "invalid funding transaction")?;
                if serialize(&tx) != raw {
                    return Err("noncanonical funding transaction".into());
                }
                let key = format!("{node}:{id}");
                let existing = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .submitted
                    .get(&key)
                    .cloned();
                if existing.as_ref().is_some_and(|saved| *saved != transaction) {
                    return Err("funding transaction changed".into());
                }
                let already_funded = self.manager.list_channels().iter().any(|channel| {
                    channel.counterparty.node_id == node
                        && channel
                            .funding_txo
                            .is_some_and(|o| o.txid == tx.compute_txid())
                });
                if !already_funded {
                    self.manager
                        .funding_transaction_generated(id, node, tx)
                        .map_err(|_| "funding rejected")?;
                }
                if existing.is_none() {
                    // Written before any queued Lightning messages leave Rust.
                    self.services.update(|j| {
                        j.submitted.insert(key, transaction);
                    })?;
                }
            }
            Command::Acknowledge { event_id } => {
                self.services.update(|j| {
                    j.events.remove(&event_id);
                })?;
            }
            Command::BlockConnected { block, height } => {
                let raw = hex::decode(block).map_err(|_| "invalid block bytes")?;
                if raw.len() > 4_000_000 {
                    return Err("block exceeds limit".into());
                }
                let block: Block = deserialize(&raw).map_err(|_| "invalid block")?;
                let revision = self.services.journal.lock().unwrap().watch_revision;
                self.scanned_block(block.header, Some(block), height, revision)?;
            }
            Command::ScannedBlock {
                header,
                block,
                height,
                watch_revision,
            } => {
                let raw_header = hex::decode(header).map_err(|_| "invalid header bytes")?;
                if raw_header.len() != 80 {
                    return Err("invalid header length".into());
                }
                let header = deserialize(&raw_header).map_err(|_| "invalid header")?;
                let block: Option<Block> = block
                    .map(|hex| -> Result<Block> {
                        let raw = hex::decode(hex).map_err(|_| "invalid block bytes")?;
                        if raw.len() > 4_000_000 {
                            return Err("block exceeds limit".into());
                        }
                        deserialize(&raw).map_err(|_| "invalid block".into())
                    })
                    .transpose()?;
                self.scanned_block(header, block, height, watch_revision)?;
            }
            Command::BlocksDisconnected { block_hash, height } => {
                if height >= self.tip.height
                    && !self
                        .recovering
                        .iter()
                        .any(|m| m.current_best_block().height > height)
                {
                    return Err("invalid rollback height".into());
                }
                let fork = BlockLocator::new(
                    BlockHash::from_str(&block_hash).map_err(|_| "invalid fork hash")?,
                    height,
                );
                self.monitor.blocks_disconnected(fork);
                for channel in &self.recovering {
                    if channel.current_best_block().height > height {
                        channel.blocks_disconnected(
                            fork,
                            &self.services,
                            &self.services,
                            &QuietLogger,
                        );
                    }
                }
                if self.tip.height > height {
                    self.manager.blocks_disconnected(fork);
                    self.tip = fork;
                }
                self.recovery_height = self
                    .recovering
                    .iter()
                    .map(|m| m.current_best_block().height)
                    .fold(self.tip.height, u32::max);
                self.services.update(|j| j.next_scan = 1)?;
            }
            Command::PinPeer {
                node_id,
                kem_key,
                signature_key,
            } => {
                let node = PublicKey::from_str(&node_id)
                    .map_err(|_| "invalid node id")?
                    .to_string();
                if hex::decode(&kem_key).map_err(|_| "invalid KEM key")?.len() != 1184
                    || hex::decode(&signature_key)
                        .map_err(|_| "invalid signature key")?
                        .len()
                        != 1312
                {
                    return Err("invalid PQ key lengths".into());
                }
                let pin = PeerPin {
                    kem_key: kem_key.to_lowercase(),
                    signature_key: signature_key.to_lowercase(),
                };
                if let Some(saved) = self.services.journal.lock().unwrap().pins.get(&node) {
                    if *saved != pin {
                        return Err("peer keys differ from pin".into());
                    }
                }
                self.services.update(|j| {
                    j.pins.insert(node, pin);
                })?;
            }
            Command::CreateInvoice {
                request_id,
                amount_msat,
            } => {
                if request_id.is_empty()
                    || request_id.len() > 128
                    || !(1..=1_000_000_000).contains(&amount_msat)
                {
                    return Err("invalid invoice request".into());
                }
                let existing = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .invoices
                    .get(&request_id)
                    .cloned();
                if let Some(saved) = existing {
                    if saved["amount_msat"].as_u64() != Some(amount_msat) {
                        return Err("invoice request changed".into());
                    }
                } else {
                    let invoice = self
                        .manager
                        .create_bolt11_invoice(Bolt11InvoiceParameters {
                            amount_msats: Some(amount_msat),
                            invoice_expiry_delta_secs: Some(3600),
                            ..Default::default()
                        })
                        .map_err(|_| "could not create invoice")?;
                    self.services.update(|j| { j.invoices.insert(request_id, json!({"invoice":invoice.to_string(),
                        "amount_msat":amount_msat,"payment_hash":invoice.payment_hash().to_string()})); })?;
                }
            }
            Command::PayInvoice {
                invoice,
                amount_msat,
                max_fee_msat,
            } => {
                if invoice.len() > 32768
                    || !(1..=1_000_000_000).contains(&amount_msat)
                    || max_fee_msat > amount_msat
                {
                    return Err("invalid payment limits".into());
                }
                let parsed = Bolt11Invoice::from_str(&invoice).map_err(|_| "invalid invoice")?;
                if parsed.currency() != Currency::Regtest
                    || parsed.amount_milli_satoshis() != Some(amount_msat)
                {
                    return Err("invoice network or amount mismatch".into());
                }
                let pin = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .pins
                    .get(&parsed.get_payee_pub_key().to_string())
                    .cloned()
                    .ok_or("invoice payee needs pinned PQ keys")?;
                let trusted_key: [u8; 1312] = hex::decode(&pin.signature_key)
                    .map_err(|_| "invalid pin")?
                    .try_into()
                    .map_err(|_| "invalid pin length")?;
                if !matches!(
                    lightning::ln::invoice_utils::verify_bolt11_pq_signature(
                        &parsed,
                        Some(&trusted_key),
                        &QuietLogger
                    ),
                    lightning::ln::invoice_utils::Bolt11PqVerification::Verified
                ) {
                    return Err("invoice PQ signature does not match pin".into());
                }
                let hash = parsed.payment_hash().to_string();
                let id = PaymentId(parsed.payment_hash().0);
                let existing = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .payments
                    .get(&hash)
                    .cloned();
                if let Some(ref saved) = existing {
                    if saved["invoice"] != invoice
                        || saved["max_fee_msat"].as_u64() != Some(max_fee_msat)
                    {
                        return Err("payment request changed".into());
                    }
                }
                let tracked = self.manager.list_recent_payments().iter().any(|payment| {
                    let payment_id = match payment {
                        RecentPaymentDetails::AwaitingInvoice { payment_id }
                        | RecentPaymentDetails::Pending { payment_id, .. }
                        | RecentPaymentDetails::Fulfilled { payment_id, .. }
                        | RecentPaymentDetails::Abandoned { payment_id, .. } => payment_id,
                    };
                    *payment_id == id
                });
                let complete = existing
                    .as_ref()
                    .is_some_and(|v| v["state"] == "sent" || v["state"] == "failed");
                if !tracked && !complete {
                    self.services.update(|j| {
                        j.payments.insert(
                            hash.clone(),
                            json!({"invoice":invoice,
                        "amount_msat":amount_msat,"max_fee_msat":max_fee_msat,"state":"pending"}),
                        );
                    })?;
                    let mut params = OptionalBolt11PaymentParams::default();
                    params.trusted_pq_key = Some(trusted_key);
                    params.retry_strategy = Retry::Timeout(Duration::from_secs(10));
                    params.route_params_config.max_total_routing_fee_msat = Some(max_fee_msat);
                    if let Err(error) = self
                        .manager
                        .pay_for_bolt11_invoice(&parsed, id, None, params)
                    {
                        self.services.update(|j| {
                            j.payments.get_mut(&hash).unwrap()["state"] = json!("failed");
                        })?;
                        return Err(format!("payment rejected: {error:?}"));
                    }
                }
            }
            Command::CloseChannel {
                channel_id,
                node_id,
                script,
            } => {
                let id = parse_channel_id(&channel_id)?;
                let node = PublicKey::from_str(&node_id).map_err(|_| "invalid node id")?;
                let destination = wallet_script(&script)?;
                let intent = json!({"node_id":node.to_string(), "script":script.to_lowercase()});
                let existing = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .closing
                    .get(&channel_id)
                    .cloned();
                if existing.as_ref().is_some_and(|saved| *saved != intent) {
                    return Err("close destination changed".into());
                }
                if self
                    .manager
                    .list_channels()
                    .iter()
                    .any(|c| c.channel_id == id && c.counterparty.node_id == node)
                {
                    self.services.update(|j| {
                        j.wallet_scripts.insert(script.to_lowercase());
                        j.closing.insert(channel_id, intent);
                    })?;
                    let shutdown = lightning::ln::script::ShutdownScript::try_from(destination)
                        .map_err(|_| "invalid shutdown script")?;
                    self.manager
                        .close_channel_with_feerate_and_script(
                            &id,
                            &node,
                            Some(self.services.fee.load(Ordering::Relaxed)),
                            Some(shutdown),
                        )
                        .map_err(|e| format!("close rejected: {e:?}"))?;
                } else if existing.is_none() {
                    return Err("unknown channel".into());
                }
            }
            Command::ForceClose {
                channel_id,
                node_id,
            } => {
                let id = parse_channel_id(&channel_id)?;
                let node = PublicKey::from_str(&node_id).map_err(|_| "invalid node id")?;
                self.manager
                    .force_close_broadcasting_latest_txn(&id, &node, "Winnow regtest close".into())
                    .map_err(|e| format!("force close rejected: {e:?}"))?;
            }
            Command::SweepOutputs { event_id, script } => {
                let destination = wallet_script(&script)?;
                let existing = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .sweeps
                    .get(&event_id)
                    .cloned();
                let raw = if let Some(saved) = existing {
                    if saved["script"] != script.to_lowercase() {
                        return Err("sweep destination changed".into());
                    }
                    saved["transaction"]
                        .as_str()
                        .ok_or("damaged sweep")?
                        .to_string()
                } else {
                    let outputs = self
                        .services
                        .journal
                        .lock()
                        .unwrap()
                        .spendable
                        .get(&event_id)
                        .cloned()
                        .ok_or("unknown spendable outputs")?;
                    let descriptors: Vec<SpendableOutputDescriptor> = outputs
                        .iter()
                        .map(|value| {
                            let bytes =
                                hex::decode(value).map_err(|_| "damaged output descriptor")?;
                            SpendableOutputDescriptor::read(&mut bitcoin::io::Cursor::new(bytes))
                                .map_err(|_| "invalid output descriptor")
                        })
                        .collect::<std::result::Result<_, _>>()?;
                    let descriptors = descriptors.iter().collect::<Vec<_>>();
                    let tx = self
                        .keys
                        .spend_spendable_outputs(
                            &descriptors,
                            Vec::new(),
                            destination,
                            self.services.fee.load(Ordering::Relaxed),
                            Some(
                                bitcoin::absolute::LockTime::from_height(self.tip.height)
                                    .map_err(|_| "invalid height")?,
                            ),
                            &bitcoin::secp256k1::Secp256k1::new(),
                        )
                        .map_err(|_| "could not sign channel sweep")?;
                    let raw = hex::encode(serialize(&tx));
                    raw
                };
                let broadcast = json!({"kind":"broadcast", "transactions":[raw]});
                let broadcast_id =
                    <sha256::Hash as Hash>::hash(&serde_json::to_vec(&broadcast).unwrap())
                        .to_string();
                self.services.update(|j| {
                    j.wallet_scripts.insert(script.to_lowercase());
                    j.sweeps.insert(
                        event_id.clone(),
                        json!({"script":script.to_lowercase(),"transaction":raw}),
                    );
                    j.events.insert(broadcast_id, broadcast);
                    j.events.retain(|_, event| {
                        event["kind"] != "sweep_required" || event["output_id"] != event_id
                    });
                })?;
            }
            Command::SetFee { sat_per_kw } => {
                if !(253..=2_500_000).contains(&sat_per_kw) {
                    return Err("invalid sat/kw fee".into());
                }
                self.services.fee.store(sat_per_kw, Ordering::Relaxed);
            }
            Command::Tick => {
                if self.last_forward.elapsed() >= self.next_forward {
                    self.manager.process_pending_htlc_forwards();
                    self.last_forward = Instant::now();
                    self.next_forward = Duration::from_millis(
                        100 + u64::from(self.keys.get_secure_random_bytes()[0]) % 100,
                    );
                }
                if self.last_peer_tick.elapsed() >= Duration::from_secs(30) {
                    self.peers.timer_tick_occurred();
                    self.last_peer_tick = Instant::now();
                }
                if self.last_manager_tick.elapsed() >= Duration::from_secs(60) {
                    self.manager.timer_tick_occurred();
                    self.last_manager_tick = Instant::now();
                }
            }
            Command::Drain => {}
        }
        if let Err(error) = self.process() {
            self.poisoned = true;
            return Err(error);
        }
        let mut result = self.status();
        if !self.recovering.is_empty()
            || self.services.journal.lock().unwrap().next_scan <= self.tip.height
        {
            result["packets"] = json!([]);
            return Ok(result);
        }
        let mut packets = Vec::new();
        for socket in self.sockets.values_mut() {
            // Drain only after manager and monitor persistence. The caller owns
            // this returned data until its socket write completes or disconnects.
            let packet = {
                let mut state = socket.state.lock().unwrap();
                let sequence = state.sequence;
                state.sequence = state
                    .sequence
                    .checked_add(1)
                    .expect("packet sequence exhausted");
                json!({"connection":socket.id, "sequence":sequence, "bytes":hex::encode(std::mem::take(&mut state.bytes)),
                    "resume_read":state.resume_read, "closed":state.closed})
            };
            packets.push(packet);
            if self.peers.write_buffer_space_avail(socket).is_err() {
                socket.state.lock().unwrap().closed = true;
            }
        }
        result["packets"] = json!(packets);
        Ok(result)
    }
}

fn parse_channel_id(value: &str) -> Result<ChannelId> {
    Ok(ChannelId::from_bytes(
        hex::decode(value)
            .map_err(|_| "invalid channel id")?
            .try_into()
            .map_err(|_| "invalid channel id length")?,
    ))
}
fn wallet_script(value: &str) -> Result<ScriptBuf> {
    let script = ScriptBuf::from_bytes(hex::decode(value).map_err(|_| "invalid wallet script")?);
    if !script.is_p2tr() {
        return Err("Winnow destination must be P2TR".into());
    }
    Ok(script)
}
