use ldk_node::bip39::Mnemonic;
use ldk_node::bitcoin::secp256k1::PublicKey;
use ldk_node::bitcoin::Network;
use ldk_node::entropy::NodeEntropy;
use ldk_node::lightning::ln::msgs::SocketAddress;
use ldk_node::lightning_invoice::{Bolt11Invoice, Bolt11InvoiceDescription, Description};
use ldk_node::{Builder, Node};
use pq_invoice_verify::verify;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

const KEM_KEY_LEN: usize = ldk_node::lightning::ln::peer_handler::PQ_KEM_EK_LEN;

#[derive(Clone)]
struct Peer {
    node_id: PublicKey,
    address: SocketAddress,
    kem_key: [u8; KEM_KEY_LEN],
}

fn decode_hex<const N: usize>(source: &str) -> Result<[u8; N], String> {
    let source = source.trim();
    if source.len() != N * 2 || !source.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(format!("expected {} hex characters", N * 2));
    }
    let mut result = [0u8; N];
    for (index, pair) in source.as_bytes().chunks_exact(2).enumerate() {
        result[index] = u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16)
            .map_err(|error| error.to_string())?;
    }
    Ok(result)
}

fn encode_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn peers_path(state: &Path) -> PathBuf {
    state.join("pq-peers.tsv")
}

fn read_peers(state: &Path) -> Result<Vec<Peer>, String> {
    let path = peers_path(state);
    if !path.exists() {
        return Ok(Vec::new());
    }
    fs::read_to_string(path)
        .map_err(|error| error.to_string())?
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let mut fields = line.split('\t');
            let node_id = PublicKey::from_str(fields.next().ok_or("missing node id")?)
                .map_err(|error| error.to_string())?;
            let address = SocketAddress::from_str(fields.next().ok_or("missing address")?)
                .map_err(|error| error.to_string())?;
            let kem_key = decode_hex(fields.next().ok_or("missing ML-KEM key")?)?;
            if fields.next().is_some() {
                return Err("extra peer fields".into());
            }
            Ok(Peer { node_id, address, kem_key })
        })
        .collect()
}

fn save_peers(state: &Path, peers: &[Peer]) -> Result<(), String> {
    let contents: String = peers
        .iter()
        .map(|peer| format!("{}\t{}\t{}\n", peer.node_id, peer.address, encode_hex(&peer.kem_key)))
        .collect();
    let temporary = state.join("pq-peers.tsv.tmp");
    fs::write(&temporary, contents).map_err(|error| error.to_string())?;
    fs::rename(&temporary, peers_path(state)).map_err(|error| error.to_string())
}

fn load_or_create_entropy(state: &Path) -> Result<NodeEntropy, String> {
    let path = state.join("mnemonic.txt");
    let phrase = if path.exists() {
        fs::read_to_string(&path).map_err(|error| error.to_string())?
    } else {
        let mnemonic = Mnemonic::generate(24).map_err(|error| error.to_string())?;
        let phrase = mnemonic.to_string();
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&path).map_err(|error| error.to_string())?;
        file.write_all(phrase.as_bytes()).map_err(|error| error.to_string())?;
        file.sync_all().map_err(|error| error.to_string())?;
        phrase
    };
    let mnemonic = Mnemonic::parse(phrase.trim()).map_err(|error| error.to_string())?;
    Ok(NodeEntropy::from_bip39_mnemonic(mnemonic, None))
}

fn command(node: &Node, state: &Path, peers: &mut Vec<Peer>, line: &str) -> Result<bool, String> {
    let mut words = line.split_whitespace();
    match words.next() {
        Some("help") => println!("address | identity | sync | balance | status | channels | test-watch REGTEST_ADDRESS | connect NODE_ID ADDRESS KEM_KEY_FILE | open NODE_ID SATS | open-public NODE_ID SATS | invoice MSAT DESCRIPTION | invoice-file MSAT OUTPUT_FILE DESCRIPTION | pay INVOICE_FILE TRUSTED_ML_DSA_KEY_FILE | quit"),
        Some("address") => println!("{}", node.onchain_payment().new_address().map_err(|e| e.to_string())?),
        Some("test-watch") => {
            let address = ldk_node::bitcoin::Address::from_str(words.next().ok_or("missing address")?)
                .map_err(|e| e.to_string())?.require_network(ldk_node::bitcoin::Network::Regtest)
                .map_err(|e| e.to_string())?;
            if words.next().is_some() { return Err("too many arguments".into()); }
            node.test_watch_script(address.script_pubkey());
            println!("test watch registered");
        }
        Some("identity") => {
            println!("node id: {}", node.node_id());
            println!("ML-DSA: {}", node.pq_node_id().map(|key| encode_hex(&key)).ok_or("PQ identity unavailable")?);
            println!("ML-KEM: {}", node.pq_kem_node_id().map(|key| encode_hex(&key)).ok_or("PQ KEM identity unavailable")?);
        }
        Some("status") => println!("{:?}", node.status()),
        Some("sync") => {
            node.sync_wallets().map_err(|e| e.to_string())?;
            println!("wallet synced");
        }
        Some("balance") => println!("{:?}", node.list_balances()),
        Some("channels") => {
            for channel in node.list_channels() {
                println!("{:?}", channel);
            }
        }
        Some("connect") => {
            let node_id = PublicKey::from_str(words.next().ok_or("missing node id")?).map_err(|e| e.to_string())?;
            let address = SocketAddress::from_str(words.next().ok_or("missing address")?).map_err(|e| e.to_string())?;
            let key_file = words.next().ok_or("missing ML-KEM key file")?;
            if words.next().is_some() { return Err("too many arguments".into()); }
            let key_text = fs::read_to_string(key_file).map_err(|e| e.to_string())?;
            let kem_key = decode_hex(&key_text)?;
            node.register_pq_peer(node_id, kem_key);
            node.connect(node_id, address.clone(), true).map_err(|e| e.to_string())?;
            peers.retain(|peer| peer.node_id != node_id);
            peers.push(Peer { node_id, address, kem_key });
            save_peers(state, peers)?;
            println!("PQLN peer connected and saved");
        }
        Some(open @ ("open" | "open-public")) => {
            let node_id = PublicKey::from_str(words.next().ok_or("missing node id")?).map_err(|e| e.to_string())?;
            let sats: u64 = words.next().ok_or("missing channel amount")?.parse::<u64>().map_err(|e| e.to_string())?;
            if words.next().is_some() { return Err("too many arguments".into()); }
            let peer = peers.iter().find(|peer| peer.node_id == node_id).ok_or("connect and pin the peer first")?;
            let channel_id = if open == "open-public" {
                node.open_announced_channel(node_id, peer.address.clone(), sats, None, None)
            } else {
                node.open_channel(node_id, peer.address.clone(), sats, None, None)
            }.map_err(|e| e.to_string())?;
            println!("channel opening started: {:?}", channel_id);
        }
        Some(action @ ("invoice" | "invoice-file")) => {
            let msat: u64 = words.next().ok_or("missing amount")?.parse::<u64>().map_err(|e| e.to_string())?;
            let output_file = if action == "invoice-file" { Some(words.next().ok_or("missing output file")?) } else { None };
            let description = words.collect::<Vec<_>>().join(" ");
            let description = Bolt11InvoiceDescription::Direct(Description::new(description).map_err(|e| e.to_string())?);
            let invoice = node.bolt11_payment().receive(msat, &description, 3600).map_err(|e| e.to_string())?;
            if let Some(path) = output_file {
                fs::write(path, invoice.to_string()).map_err(|e| e.to_string())?;
                println!("invoice saved: {path}");
            } else {
                println!("{}", invoice);
            }
        }
        Some("pay") => {
            let invoice_file = words.next().ok_or("missing invoice file")?;
            let key_file = words.next().ok_or("missing trusted ML-DSA key file")?;
            if words.next().is_some() { return Err("too many arguments".into()); }
            let invoice_text = fs::read_to_string(invoice_file).map_err(|e| e.to_string())?;
            let key_text = fs::read_to_string(key_file).map_err(|e| e.to_string())?;
            verify(&invoice_text, &key_text)?;
            let invoice = Bolt11Invoice::from_str(invoice_text.trim()).map_err(|e| e.to_string())?;
            if invoice.currency() != ldk_node::lightning_invoice::Currency::Regtest {
                return Err("this prototype pays regtest invoices only".into());
            }
            let payment_id = node.bolt11_payment().send(&invoice, None).map_err(|e| e.to_string())?;
            println!("payment started: {:?}", payment_id);
        }
        Some("quit" | "exit") => return Ok(false),
        Some(other) => return Err(format!("unknown command: {other}")),
        None => {}
    }
    Ok(true)
}

fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() == 2 && args[1] == "--help" {
        println!("usage: pq-light-client STATE_DIR PEER1_HOST:PORT,PEER2_HOST:PORT [LISTEN_ADDRESS]");
        return Ok(());
    }
    if args.len() < 3 || args.len() > 4 {
        return Err("usage: pq-light-client STATE_DIR PEER1_HOST:PORT,PEER2_HOST:PORT [LISTEN_ADDRESS]".into());
    }
    let state = PathBuf::from(&args[1]);
    fs::create_dir_all(&state).map_err(|error| error.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    }
    let entropy = load_or_create_entropy(&state)?;
    let mut peers = read_peers(&state)?;
    let mut builder = Builder::new();
    builder.set_network(Network::Regtest);
    builder.set_chain_source_p2p(args[2].clone());
    builder.set_gossip_source_p2p();
    builder.set_node_alias("winnow-pqln-regtest".to_string()).map_err(|e| e.to_string())?;
    if let Some(listen) = args.get(3) {
        let address = SocketAddress::from_str(listen).map_err(|e| e.to_string())?;
        builder.set_listening_addresses(vec![address]).map_err(|e| e.to_string())?;
    }
    builder.set_storage_dir_path(state.join("node").to_string_lossy().into_owned());
    let node = Arc::new(builder.build(entropy).map_err(|e| e.to_string())?);
    let pq_node_key = node.pq_node_id().ok_or("PQ identity unavailable")?;
    let pq_kem_key = node.pq_kem_node_id().ok_or("PQ KEM identity unavailable")?;
    fs::write(state.join("pq-node-key.hex"), encode_hex(&pq_node_key)).map_err(|e| e.to_string())?;
    fs::write(state.join("pq-kem-key.hex"), encode_hex(&pq_kem_key)).map_err(|e| e.to_string())?;
    fs::write(state.join("node-id.txt"), node.node_id().to_string()).map_err(|e| e.to_string())?;
    for peer in &peers { node.register_pq_peer(peer.node_id, peer.kem_key); }
    node.start().map_err(|e| e.to_string())?;

    let running = Arc::new(AtomicBool::new(true));
    let event_node = Arc::clone(&node);
    let event_running = Arc::clone(&running);
    let event_worker = thread::spawn(move || {
        while event_running.load(Ordering::Relaxed) {
            if let Some(event) = event_node.next_event() {
                println!("\nevent: {:?}", event);
                if let Err(error) = event_node.event_handled() { eprintln!("event persistence failed: {error}"); }
            }
            thread::sleep(Duration::from_millis(250));
        }
    });

    println!("regtest PQLN light client running; type help for commands");
    let stdin = io::stdin();
    loop {
        print!("pqln> ");
        io::stdout().flush().map_err(|e| e.to_string())?;
        let mut line = String::new();
        if stdin.lock().read_line(&mut line).map_err(|e| e.to_string())? == 0 { break; }
        match command(&node, &state, &mut peers, &line) {
            Ok(true) => {},
            Ok(false) => break,
            Err(error) => eprintln!("{error}"),
        }
    }
    running.store(false, Ordering::Relaxed);
    event_worker.join().map_err(|_| "event worker panicked".to_string())?;
    node.stop().map_err(|e| e.to_string())?;
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kem_key_parser_rejects_truncation_and_non_hex() {
        assert_eq!(decode_hex::<4>("0011aAff").unwrap(), [0, 17, 170, 255]);
        assert!(decode_hex::<4>("0011aa").is_err());
        assert!(decode_hex::<4>("0011aagg").is_err());
    }
}
