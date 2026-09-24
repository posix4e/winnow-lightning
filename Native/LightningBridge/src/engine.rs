use bitcoin::{
    consensus::{deserialize, serialize},
    hashes::{sha256, Hash},
    secp256k1::PublicKey,
    Block, BlockHash, Network, Script, Transaction, Txid,
};
use lightning::{
    chain::{
        chaininterface::{BroadcasterInterface, ConfirmationTarget, FeeEstimator, TransactionType},
        chainmonitor::ChainMonitor,
        BlockLocator, Filter, Listen, Watch, WatchedOutput,
    },
    events::{Event, EventsProvider, ReplayEvent},
    ln::{
        channelmanager::{ChainParameters, ChannelManagerReadArgs, SimpleArcChannelManager},
        peer_handler::{IgnoringMessageHandler, PeerManager, SocketDescriptor},
        types::ChannelId,
    },
    onion_message::messenger::DefaultMessageRouter,
    routing::{
        gossip::NetworkGraph,
        router::DefaultRouter,
        scoring::{
            ProbabilisticScorer, ProbabilisticScoringDecayParameters,
            ProbabilisticScoringFeeParameters,
        },
    },
    sign::{EntropySource, InMemorySigner, KeysManager, NodeSigner, Recipient},
    util::{
        config::UserConfig,
        logger::{Logger, Record},
        persist::{read_channel_monitors, KVStoreSync},
        ser::{ReadableArgs, Writeable},
    },
};
use lightning_persister::fs_store::v1::FilesystemStore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    hash::{Hash as StdHash, Hasher},
    path::PathBuf,
    str::FromStr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, RwLock,
    },
    time::{SystemTime, UNIX_EPOCH},
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
type Manager = SimpleArcChannelManager<Monitor, Services, Services, QuietLogger>;
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

#[derive(Clone, Default, Serialize, Deserialize)]
struct Journal {
    events: BTreeMap<String, Value>,
    watches: BTreeMap<String, Value>,
    submitted: BTreeMap<String, String>,
}

struct Services {
    store: Arc<FilesystemStore>,
    journal: Mutex<Journal>,
    fee: u32,
    failed: AtomicBool,
}

impl Services {
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
        self.fee
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
        self.update(|j| {
            j.watches.insert(
                format!("tx:{txid}"),
                json!({"txid":txid.to_string(), "script":hex::encode(script_pubkey.as_bytes())}),
            );
        })
        .expect("Lightning watch persistence failed");
    }
    fn register_output(&self, output: WatchedOutput) {
        self.update(|j| {
            j.watches.insert(
                format!("output:{}", output.outpoint),
                json!({"txid":output.outpoint.txid.to_string(), "vout":output.outpoint.index,
                "script":hex::encode(output.script_pubkey.as_bytes()),
                "block_hash":output.block_hash.map(|h| h.to_string())}),
            );
        })
        .expect("Lightning watch persistence failed");
    }
}

#[derive(Default)]
struct SocketState {
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
    BlocksDisconnected {
        block_hash: String,
        height: u32,
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
            fee: config.fee_sat_per_kw,
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
        let router = Arc::new(DefaultRouter::new(
            graph.clone(),
            logger.clone(),
            keys.clone(),
            scorer,
            ProbabilisticScoringFeeParameters::default(),
        ));
        let message_router = Arc::new(DefaultMessageRouter::new(graph, keys.clone()));
        let mut config = UserConfig::default();
        // Initial regtest channel type avoids anchor wallet/package fee-bumping
        // requirements. No ordinary Bitcoin wallet is constructed by this core.
        config
            .channel_handshake_config
            .negotiate_anchors_zero_fee_htlc_tx = false;
        config.channel_handshake_config.announce_for_forwarding = false;
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
        for (monitor_tip, channel) in monitors {
            // Catch-up of independently persisted positions must be implemented
            // before permitting peers to reconnect in this recovery case.
            if monitor_tip != tip {
                return Err("monitor and manager need chain reconciliation".into());
            }
            monitor
                .watch_channel(channel.channel_id(), channel)
                .map_err(|_| "restore channel monitor")?;
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
            _lock: lock,
            poisoned: false,
        };
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
        let handler = |event: Event| -> std::result::Result<(), ReplayEvent> {
            let value = match event {
                Event::OpenChannelRequest {
                    temporary_channel_id,
                    counterparty_node_id,
                    ..
                } => {
                    if self.manager.list_channels().len() >= 8 {
                        return Err(ReplayEvent());
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

    pub fn status(&self) -> Value {
        let journal = self.services.journal.lock().unwrap();
        json!({"abi":1, "core_revision":crate::CORE_REVISION, "network":"regtest",
            "node_id":self.keys.get_node_id(Recipient::Node).unwrap().to_string(),
            "kem_key":self.keys.get_pq_kem_node_id().map(hex::encode),
            "signature_key":self.keys.get_pq_node_id().map(hex::encode),
            "height":self.tip.height, "block_hash":self.tip.block_hash.to_string(),
            "events":journal.events, "watches":journal.watches,
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
        match command {
            Command::Status => return Ok(self.status()),
            Command::Connect {
                connection,
                node_id,
                kem_key,
            } => {
                let node = PublicKey::from_str(&node_id).map_err(|_| "invalid node id")?;
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
                if !(20_000..=16_777_215).contains(&amount_sat) {
                    return Err("invalid regtest channel capacity".into());
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
                if height != self.tip.height.checked_add(1).ok_or("height overflow")?
                    || block.header.prev_blockhash != self.tip.block_hash
                {
                    return Err("noncontiguous chain update".into());
                }
                if !block.check_merkle_root() || !block.check_witness_commitment() {
                    return Err("invalid block commitments".into());
                }
                self.monitor.block_connected(&block, height);
                self.manager.block_connected(&block, height);
                self.tip.advance(block.block_hash());
            }
            Command::BlocksDisconnected { block_hash, height } => {
                if height >= self.tip.height {
                    return Err("invalid rollback height".into());
                }
                let fork = BlockLocator::new(
                    BlockHash::from_str(&block_hash).map_err(|_| "invalid fork hash")?,
                    height,
                );
                self.monitor.blocks_disconnected(fork);
                self.manager.blocks_disconnected(fork);
                self.tip = fork;
            }
            Command::Tick => {
                self.manager.timer_tick_occurred();
                self.peers.timer_tick_occurred();
            }
            Command::Drain => {}
        }
        if let Err(error) = self.process() {
            self.poisoned = true;
            return Err(error);
        }
        let mut result = self.status();
        let mut packets = Vec::new();
        for socket in self.sockets.values_mut() {
            // Drain only after manager and monitor persistence. The caller owns
            // this returned data until its socket write completes or disconnects.
            let packet = {
                let mut state = socket.state.lock().unwrap();
                json!({"connection":socket.id, "bytes":hex::encode(std::mem::take(&mut state.bytes)),
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
