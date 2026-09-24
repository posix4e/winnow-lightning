use bitcoin::hashes::sha256;
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
        allow_private_forwarding: false,
        enable_claims: false,
        claim_provider: None,
    }
}

#[test]
fn claim_quote_binds_public_terms_to_a_pinned_pq_invoice_without_import_side_effects() {
    use winnow_lightning_bridge::claim_protocol::{self as protocol, Envelope, Quote, Terms};
    let provider_dir = TempDir::new().unwrap();
    let recipient_dir = TempDir::new().unwrap();
    let mut provider = Engine::new(config(&provider_dir), &[51; 32]).unwrap();
    let mut recipient = Engine::new(config(&recipient_dir), &[52; 32]).unwrap();
    let identity = provider.status();
    let terms = Terms {
        version: 1,
        network: "regtest".into(),
        claim_id: hex::encode([13; 32]),
        provider_node_id: identity["node_id"].as_str().unwrap().into(),
        provider_host: "127.0.0.1".into(),
        provider_port: 9735,
        payment_hash: protocol::digest(&[14; 32]),
        capability_hash: protocol::digest(&[15; 32]),
        amount_msat: 5_000_000,
        fee_msat: protocol::PROVIDER_FEE_MSAT,
        latest_claim_height: protocol::CLAIM_BLOCKS,
        expires_at_unix: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + u64::from(protocol::LIFETIME_SECONDS),
        hold_delta: protocol::HOLD_DELTA,
    };
    let result = provider
        .call(Command::CreateHashInvoice {
            request_id: terms.claim_id.clone(),
            amount_msat: terms.debit().unwrap(),
            payment_hash: terms.payment_hash.clone(),
            preimage: None,
            expiry_secs: protocol::LIFETIME_SECONDS,
            min_final_cltv_delta: terms.hold_delta,
            description_hash: Some(terms.commitment().unwrap().to_string()),
        })
        .unwrap();
    let invoice = result["hash_invoices"][&terms.payment_hash]["invoice"]
        .as_str()
        .unwrap()
        .to_owned();
    let envelope = Envelope {
        quote: Quote { terms, invoice },
        capability: hex::encode([15; 32]),
        preimage: hex::encode([14; 32]),
    };
    let text = envelope.encode().unwrap();
    assert!(recipient
        .call(Command::InspectClaim {
            claim: text.clone()
        })
        .is_err());
    recipient
        .call(Command::PinPeer {
            node_id: identity["node_id"].as_str().unwrap().into(),
            kem_key: identity["kem_key"].as_str().unwrap().into(),
            signature_key: identity["signature_key"].as_str().unwrap().into(),
        })
        .unwrap();
    let before = recipient.status();
    let inspected = recipient
        .call(Command::InspectClaim {
            claim: text.clone(),
        })
        .unwrap();
    assert_eq!(inspected["inspected_claim"]["amount_msat"], 5_000_000);
    assert_eq!(recipient.status(), before);
    assert!(!inspected.to_string().contains(&envelope.preimage));
    assert!(!inspected.to_string().contains(&envelope.capability));
    let mut tampered = envelope.clone();
    tampered.quote.terms.provider_host = "evil.example".into();
    assert!(recipient
        .call(Command::InspectClaim {
            claim: tampered.encode().unwrap()
        })
        .is_err());
    tampered = envelope.clone();
    tampered.quote.terms.amount_msat += 1;
    assert!(recipient
        .call(Command::InspectClaim {
            claim: tampered.encode().unwrap()
        })
        .is_err());
    println!(
        "Measured hybrid-PQ claim envelope: {} UTF-8 bytes; invoice: {} bytes",
        text.len(),
        envelope.quote.invoice.len()
    );
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

#[test]
fn journal_failure_stops_requests_until_reopen_without_publishing_candidate_state() {
    let dir = TempDir::new().unwrap();
    let mut engine = Engine::new(config(&dir), &[11; 32]).unwrap();
    let journal = dir.path().join("winnow");
    let saved = dir.path().join("saved-journal");
    std::fs::rename(&journal, &saved).unwrap();
    std::fs::write(&journal, b"injected storage failure").unwrap();
    assert!(engine
        .call(Command::CreateInvoice {
            request_id: "failed".into(),
            amount_msat: 1000
        })
        .is_err());
    std::fs::remove_file(&journal).unwrap();
    std::fs::rename(&saved, &journal).unwrap();
    assert!(engine.call(Command::Status).is_err());
    drop(engine);
    let mut restored = Engine::new(config(&dir), &[11; 32]).unwrap();
    assert!(restored.status()["invoices"]
        .as_object()
        .unwrap()
        .is_empty());
    assert!(restored
        .call(Command::CreateInvoice {
            request_id: "recovered".into(),
            amount_msat: 1000
        })
        .is_ok());
}

#[test]
fn fee_policy_updates_are_bounded_and_keep_explicit_sat_per_kw_units() {
    let dir = TempDir::new().unwrap();
    let mut engine = Engine::new(config(&dir), &[12; 32]).unwrap();
    let updated = engine.call(Command::SetFee { sat_per_kw: 1250 }).unwrap();
    assert_eq!(updated["fee_sat_per_kw"], 1250);
    assert!(engine.call(Command::SetFee { sat_per_kw: 1 }).is_err());
    assert_eq!(
        engine.call(Command::Status).unwrap()["fee_sat_per_kw"],
        1250
    );
}

#[test]
fn supplied_hash_invoice_survives_restart_without_exporting_its_preimage() {
    let dir = TempDir::new().unwrap();
    let secret = [93; 32];
    let hash = sha256::Hash::hash(&secret).to_string();
    let request = || Command::CreateHashInvoice {
        request_id: "imported-claim".into(),
        amount_msat: 2_000_000,
        payment_hash: hash.clone(),
        preimage: Some(hex::encode(secret)),
        expiry_secs: 3600,
        description_hash: None,
        min_final_cltv_delta: 0,
    };
    let mut node = Engine::new(config(&dir), &[61; 32]).unwrap();
    let first = node.call(request()).unwrap();
    let invoice = first["hash_invoices"][&hash]["invoice"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!invoice.is_empty());
    assert!(!first.to_string().contains(&hex::encode(secret)));
    assert_eq!(
        node.call(request()).unwrap()["hash_invoices"][&hash]["invoice"],
        invoice
    );
    drop(node);
    let mut restored = Engine::new(config(&dir), &[61; 32]).unwrap();
    assert_eq!(
        restored.call(request()).unwrap()["hash_invoices"][&hash]["invoice"],
        invoice
    );
    assert!(restored
        .call(Command::CreateHashInvoice {
            request_id: "imported-claim".into(),
            amount_msat: 2_000_001,
            payment_hash: hash.clone(),
            preimage: Some(hex::encode(secret)),
            expiry_secs: 3600,
            description_hash: None,
            min_final_cltv_delta: 0,
        })
        .is_err());
    assert_eq!(
        restored.status()["hash_invoices"][&hash]["amount_msat"],
        2_000_000
    );
}

#[test]
fn invalid_external_preimage_cannot_register_or_replace_an_invoice() {
    let dir = TempDir::new().unwrap();
    let mut node = Engine::new(config(&dir), &[62; 32]).unwrap();
    let hash = sha256::Hash::hash(&[45; 32]).to_string();
    assert!(node
        .call(Command::CreateHashInvoice {
            request_id: "mismatch".into(),
            amount_msat: 2_000_000,
            payment_hash: hash.clone(),
            preimage: Some(hex::encode([46; 32])),
            expiry_secs: 3600,
            description_hash: None,
            min_final_cltv_delta: 0,
        })
        .is_err());
    assert!(node.status()["hash_invoices"]
        .as_object()
        .unwrap()
        .is_empty());
    let held = node
        .call(Command::CreateHashInvoice {
            request_id: "hold".into(),
            amount_msat: 2_000_000,
            payment_hash: hash.clone(),
            preimage: None,
            expiry_secs: 3600,
            description_hash: None,
            min_final_cltv_delta: 288,
        })
        .unwrap();
    assert_eq!(held["hash_invoices"][&hash]["state"], "registered");
    assert!(held["hash_invoices"][&hash].get("preimage").is_none());
}

#[test]
fn classical_fallback_and_pinned_key_substitution_have_no_payment_side_effects() {
    use bitcoin::secp256k1::{PublicKey, Secp256k1, SecretKey};
    use lightning::types::payment::PaymentHash;
    use lightning_invoice::PaymentSecret;
    use lightning_invoice::{Currency, InvoiceBuilder};
    let dir = TempDir::new().unwrap();
    let mut node = Engine::new(config(&dir), &[64; 32]).unwrap();
    let identity = node.status();
    let secret = SecretKey::from_slice(&[65; 32]).unwrap();
    let secp = Secp256k1::new();
    let peer = PublicKey::from_secret_key(&secp, &secret).to_string();
    node.call(Command::PinPeer {
        node_id: peer.clone(),
        kem_key: identity["kem_key"].as_str().unwrap().into(),
        signature_key: identity["signature_key"].as_str().unwrap().into(),
    })
    .unwrap();
    let before = node.status();
    assert!(node
        .call(Command::PinPeer {
            node_id: peer,
            kem_key: identity["kem_key"].as_str().unwrap().into(),
            signature_key: hex::encode([0; 1312]),
        })
        .is_err());
    let invoice = InvoiceBuilder::new(Currency::Regtest)
        .description("classical-only control".into())
        .payment_hash(PaymentHash(sha256::Hash::hash(&[66; 32]).to_byte_array()))
        .payment_secret(PaymentSecret([67; 32]))
        .duration_since_epoch(
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap(),
        )
        .min_final_cltv_expiry_delta(80)
        .amount_milli_satoshis(5_000_000)
        .build_signed(|message| secp.sign_ecdsa_recoverable(message, &secret))
        .unwrap();
    assert!(node
        .call(Command::PayInvoice {
            invoice: invoice.to_string(),
            amount_msat: 5_000_000,
            max_fee_msat: 1000,
        })
        .is_err());
    assert!(node
        .call(Command::CreateRefund {
            amount_msat: 5_000_000
        })
        .is_err());
    assert_eq!(node.status()["payments"], before["payments"]);
    assert_eq!(node.status()["claims"], before["claims"]);
    assert_eq!(
        node.status()["capabilities"]["bolt12_refund_payments"],
        false
    );
}
