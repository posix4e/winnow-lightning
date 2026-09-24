use bitcoin::{
    absolute, consensus::serialize, hashes::Hash, transaction, Amount, OutPoint, ScriptBuf,
    Sequence, Transaction, TxIn, TxOut, Txid, Witness,
};
use serde_json::Value;
use std::collections::VecDeque;
use tempfile::TempDir;
use winnow_lightning_bridge::engine::{Command, Config, Engine};

fn config(dir: &TempDir) -> Config {
    Config {
        network: "regtest".into(),
        storage_path: dir.path().into(),
        fee_sat_per_kw: 500,
    }
}
fn packets(queue: &mut VecDeque<(usize, String)>, source: usize, result: Value) {
    for packet in result["packets"].as_array().unwrap() {
        assert!(!packet["closed"].as_bool().unwrap());
        let bytes = packet["bytes"].as_str().unwrap();
        if !bytes.is_empty() {
            queue.push_back((1 - source, bytes.into()));
        }
    }
}
fn pump(nodes: &mut [Engine; 2], source: usize, initial: Value) {
    let mut queue = VecDeque::new();
    packets(&mut queue, source, initial);
    for _ in 0..200 {
        if let Some((to, bytes)) = queue.pop_front() {
            for chunk in bytes.as_bytes().chunks(131_072) {
                let result = nodes[to]
                    .call(Command::Read {
                        connection: 1,
                        bytes: String::from_utf8(chunk.to_vec()).unwrap(),
                    })
                    .unwrap();
                packets(&mut queue, to, result);
            }
        } else {
            for (i, node) in nodes.iter_mut().enumerate() {
                packets(&mut queue, i, node.call(Command::Drain).unwrap());
            }
            if queue.is_empty() {
                return;
            }
        }
    }
    panic!("peer exchange did not settle");
}

#[test]
fn identity_storage_lock_and_network_boundary() {
    let dir = TempDir::new().unwrap();
    let first = Engine::new(config(&dir), &[1; 32]).unwrap();
    let status = first.status();
    assert_eq!(status["kem_key"].as_str().unwrap().len(), 1184 * 2);
    assert!(Engine::new(config(&dir), &[1; 32]).is_err());
    drop(first);
    let restored = Engine::new(config(&dir), &[1; 32]).unwrap();
    assert_eq!(status["node_id"], restored.status()["node_id"]);
    assert_eq!(status["kem_key"], restored.status()["kem_key"]);
    drop(restored);
    assert!(Engine::new(config(&dir), &[2; 32]).is_err());
    let mut mainnet = config(&dir);
    mainnet.network = "bitcoin".into();
    assert!(Engine::new(mainnet, &[1; 32]).is_err());
}

#[test]
fn hybrid_handshake_funding_authorization_and_restart() {
    let a = TempDir::new().unwrap();
    let b = TempDir::new().unwrap();
    let mut nodes = [
        Engine::new(config(&a), &[1; 32]).unwrap(),
        Engine::new(config(&b), &[2; 32]).unwrap(),
    ];
    let remote = nodes[1].status();
    let inbound = nodes[1].call(Command::Accept { connection: 1 }).unwrap();
    pump(&mut nodes, 1, inbound);
    let outbound = nodes[0]
        .call(Command::Connect {
            connection: 1,
            node_id: remote["node_id"].as_str().unwrap().into(),
            kem_key: remote["kem_key"].as_str().unwrap().into(),
        })
        .unwrap();
    pump(&mut nodes, 0, outbound);
    assert_eq!(nodes[0].status()["peers"].as_array().unwrap().len(), 1);
    assert_eq!(nodes[1].status()["peers"].as_array().unwrap().len(), 1);
    let opened = nodes[0]
        .call(Command::OpenChannel {
            node_id: remote["node_id"].as_str().unwrap().into(),
            amount_sat: 100_000,
            user_channel_id: 42,
        })
        .unwrap();
    pump(&mut nodes, 0, opened);
    let status = nodes[0].status();
    let events = status["events"].as_object().unwrap();
    assert!(!events.values().any(|e| e["kind"] == "broadcast"));
    let funding = events
        .values()
        .find(|e| e["kind"] == "funding")
        .expect("real FundingGenerationReady");
    assert_eq!(funding["amount_sat"], 100_000);

    // This exercises the protocol boundary only. The Swift integration test
    // supplies a transaction actually signed by Winnow; this dummy witness is
    // not a consensus-valid spend and is never relayed to a Bitcoin peer.
    let tx = Transaction {
        version: transaction::Version::TWO,
        lock_time: absolute::LockTime::ZERO,
        input: vec![TxIn {
            previous_output: OutPoint {
                txid: Txid::from_byte_array([3; 32]),
                vout: 0,
            },
            script_sig: ScriptBuf::new(),
            sequence: Sequence::MAX,
            witness: Witness::from_slice(&[vec![0; 64]]),
        }],
        output: vec![TxOut {
            value: Amount::from_sat(100_000),
            script_pubkey: ScriptBuf::from_bytes(
                hex::decode(funding["script"].as_str().unwrap()).unwrap(),
            ),
        }],
    };
    let raw = hex::encode(serialize(&tx));
    let temp_id = funding["temporary_channel_id"].as_str().unwrap().to_owned();
    let node_id = remote["node_id"].as_str().unwrap().to_owned();
    let submitted = nodes[0]
        .call(Command::SubmitFunding {
            temporary_channel_id: temp_id.clone(),
            node_id: node_id.clone(),
            transaction: raw.clone(),
        })
        .unwrap();
    assert!(!submitted["events"]
        .as_object()
        .unwrap()
        .values()
        .any(|e| e["kind"] == "broadcast"));
    pump(&mut nodes, 0, submitted);
    let authorized = nodes[0].status();
    let broadcast = authorized["events"]
        .as_object()
        .unwrap()
        .values()
        .find(|e| e["kind"] == "broadcast")
        .unwrap();
    assert_eq!(broadcast["transactions"], serde_json::json!([raw]));
    assert!(!authorized["watches"].as_object().unwrap().is_empty());
    let channels = authorized["channels"].clone();
    nodes[0]
        .call(Command::SubmitFunding {
            temporary_channel_id: temp_id,
            node_id,
            transaction: raw,
        })
        .unwrap();
    drop(nodes);
    let restored = Engine::new(config(&a), &[1; 32]).unwrap();
    assert_eq!(restored.status()["events"], authorized["events"]);
    assert_eq!(restored.status()["watches"], authorized["watches"]);
    assert_eq!(
        restored.status()["channels"][0]["funding_txid"],
        channels[0]["funding_txid"]
    );
}
