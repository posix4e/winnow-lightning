//! Durable application protocol above the core's HTLC/invoice primitives.
//! Secrets never enter ordinary status snapshots or control-message replies.
use super::*;
use crate::claim_protocol::{self as protocol, Envelope, Quote, Terms};

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderConfig {
    pub host: String,
    pub port: u16,
}

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct SentClaim {
    request_id: String,
    claim_id: String,
    provider: String,
    host: String,
    port: u16,
    amount_msat: u64,
    preimage: String,
    capability: String,
    quote: Option<Quote>,
    phase: String,
    provider_ready: bool,
    exported: Option<String>,
    #[serde(default)]
    last_error: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct ReceivedClaim {
    envelope: Envelope,
    redeeming: bool,
    #[serde(default)]
    last_error: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct ProviderClaim {
    sender: String,
    quote: Quote,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
enum Message {
    Prepare {
        claim_id: String,
        payment_hash: String,
        capability_hash: String,
        amount_msat: u64,
    },
    Quoted {
        quote: Quote,
    },
    Check {
        claim_id: String,
    },
    Ready {
        claim_id: String,
    },
    Redeem {
        claim_id: String,
        capability: String,
        invoice: String,
    },
    Cancel {
        claim_id: String,
    },
    Cancelled {
        claim_id: String,
    },
    Rejected {
        claim_id: String,
        reason: String,
    },
}

fn now() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|n| n.as_secs())
        .map_err(|_| "clock before epoch".into())
}

impl Engine {
    pub(super) fn claim_funding_origin_allowed(
        &self,
        hash: &str,
        channels: &[(ChannelId, Option<u128>)],
    ) -> bool {
        let expected = self
            .services
            .journal
            .lock()
            .unwrap()
            .provider_claims
            .values()
            .find(|c| c.quote.terms.payment_hash == hash)
            .map(|c| c.sender.clone());
        let Some(expected) = expected else {
            return true;
        };
        let known = self.manager.list_channels();
        channels.len() == 1
            && known.iter().any(|c| {
                c.channel_id == channels[0].0 && c.counterparty.node_id.to_string() == expected
            })
    }
    fn send_claim_message(&self, peer: &str, message: Message) -> Result<()> {
        self.claim_wire.send(
            PublicKey::from_str(peer).map_err(|_| "invalid provider")?,
            serde_json::to_vec(&message).map_err(|_| "claim message encoding failed")?,
        )?;
        Ok(())
    }

    pub(super) fn prepare_claim(
        &self,
        request_id: String,
        provider: String,
        host: String,
        port: u16,
        amount_msat: u64,
    ) -> Result<()> {
        if !self.claims_enabled {
            return Err("funded claims disabled pending protocol validation".into());
        }
        if request_id.is_empty() || request_id.len() > 128 {
            return Err("invalid claim request id".into());
        }
        let journal = self.services.journal.lock().unwrap().clone();
        if !journal.pins.contains_key(&provider) {
            return Err("provider requires independently pinned PQ keys".into());
        }
        if let Some(saved) = journal
            .sent_claims
            .values()
            .find(|c| c.request_id == request_id)
        {
            if saved.provider != provider
                || saved.host != host
                || saved.port != port
                || saved.amount_msat != amount_msat
            {
                return Err("claim request changed".into());
            }
            return Ok(());
        }
        if journal.sent_claims.len() >= 128
            || journal.sent_claims.values().any(|c| {
                !matches!(
                    self.sent_claim_phase(c, &journal).as_str(),
                    "paid" | "failed"
                )
            })
        {
            return Err("resolve the existing claim before creating another".into());
        }
        let preimage = self.keys.get_secure_random_bytes();
        let capability = self.keys.get_secure_random_bytes();
        let claim_id = hex::encode(self.keys.get_secure_random_bytes());
        let terms = Terms {
            version: 1,
            network: "regtest".into(),
            claim_id: claim_id.clone(),
            provider_node_id: provider.clone(),
            provider_host: host.clone(),
            provider_port: port,
            payment_hash: protocol::digest(&preimage),
            capability_hash: protocol::digest(&capability),
            amount_msat,
            fee_msat: protocol::PROVIDER_FEE_MSAT,
            latest_claim_height: self
                .tip
                .height
                .checked_add(protocol::CLAIM_BLOCKS)
                .ok_or("height overflow")?,
            expires_at_unix: now()?
                .checked_add(u64::from(protocol::LIFETIME_SECONDS))
                .ok_or("clock overflow")?,
            hold_delta: protocol::HOLD_DELTA,
        };
        terms.validate()?;
        if !self.manager.list_channels().iter().any(|c| {
            c.counterparty.node_id.to_string() == provider
                && c.is_usable
                && c.next_outbound_htlc_limit_msat >= terms.debit().unwrap()
        }) {
            return Err("provider needs a usable funded channel with sufficient liquidity".into());
        }
        self.services.update(|j| {
            j.sent_claims.insert(
                claim_id.clone(),
                SentClaim {
                    request_id,
                    claim_id: claim_id.clone(),
                    provider: provider.clone(),
                    host,
                    port,
                    amount_msat,
                    preimage: hex::encode(preimage),
                    capability: hex::encode(capability),
                    quote: None,
                    phase: "preparing".into(),
                    provider_ready: false,
                    exported: None,
                    last_error: None,
                },
            );
        })?;
        self.send_claim_message(
            &provider,
            Message::Prepare {
                claim_id,
                payment_hash: terms.payment_hash,
                capability_hash: terms.capability_hash,
                amount_msat,
            },
        )
    }

    pub(super) fn commit_claim(&self, claim_id: String, quote_commitment: String) -> Result<()> {
        if !self.claims_enabled {
            return Err("funded claims disabled pending protocol validation".into());
        }
        let record = self
            .services
            .journal
            .lock()
            .unwrap()
            .sent_claims
            .get(&claim_id)
            .cloned()
            .ok_or("unknown claim")?;
        let quote = record.quote.ok_or("claim quote not received")?;
        if quote.terms.commitment()?.to_string() != quote_commitment {
            return Err("claim review changed".into());
        }
        if record.phase == "quoted" {
            self.verify_claim_quote(&quote)?;
            self.services.update(|j| {
                j.sent_claims.get_mut(&claim_id).unwrap().phase = "committing".into();
            })?;
        }
        self.resume_claim_commit(&claim_id)
    }

    pub(super) fn cancel_claim(&self, id: &str) -> Result<()> {
        let journal = self.services.journal.lock().unwrap().clone();
        let record = journal.sent_claims.get(id).ok_or("unknown claim")?;
        let hash = protocol::digest(&protocol::bytes32(&record.preimage)?);
        if !matches!(record.phase.as_str(), "preparing" | "quoted" | "cancelling")
            || journal.payments.contains_key(&hash)
        {
            return Err("a committed claim cannot be cancelled".into());
        }
        self.services.update(|j| {
            j.sent_claims.get_mut(id).unwrap().phase = "cancelling".into();
        })?;
        self.send_claim_message(
            &record.provider,
            Message::Cancel {
                claim_id: id.into(),
            },
        )
    }

    fn resume_claim_commit(&self, id: &str) -> Result<()> {
        let record = self
            .services
            .journal
            .lock()
            .unwrap()
            .sent_claims
            .get(id)
            .cloned()
            .ok_or("unknown claim")?;
        if record.phase != "committing" {
            return Ok(());
        }
        let quote = record.quote.ok_or("missing saved quote")?;
        // The direct provider channel has no routing fee. This explicitly
        // bounds the reviewed debit to recipient amount plus the fixed fee.
        self.pay_invoice(
            quote.invoice,
            quote.terms.debit()?,
            0,
            Some(u32::from(protocol::HOLD_DELTA) + 6),
        )?;
        self.services.update(|j| {
            j.sent_claims.get_mut(id).unwrap().phase = "funding".into();
        })
    }

    fn sent_claim_phase(&self, record: &SentClaim, journal: &Journal) -> String {
        let Some(quote) = &record.quote else {
            return record.phase.clone();
        };
        match journal
            .payments
            .get(&quote.terms.payment_hash)
            .and_then(|p| p["state"].as_str())
        {
            Some("sent") => return "paid".into(),
            Some("failed") => return "failed".into(),
            _ => {}
        }
        let committed = self.manager.list_channels().iter().any(|c| {
            c.counterparty.node_id.to_string() == record.provider
                && c.pending_outbound_htlcs.iter().any(|h| {
                    h.payment_hash.to_string() == quote.terms.payment_hash
                        && !h.is_dust
                        && h.amount_msat == quote.terms.debit().unwrap_or(u64::MAX)
                        && matches!(
                            h.state,
                            Some(lightning::ln::channel_state::OutboundHTLCStateDetails::Committed)
                        )
                })
        });
        if record.provider_ready && committed {
            if quote
                .terms
                .is_current(self.tip.height, now().unwrap_or(u64::MAX))
            {
                "awaiting_claim".into()
            } else {
                "expired_pending".into()
            }
        } else {
            record.phase.clone()
        }
    }

    pub(super) fn export_claim(&self, id: &str) -> Result<String> {
        if !self.claims_enabled {
            return Err("funded claims disabled pending protocol validation".into());
        }
        let journal = self.services.journal.lock().unwrap().clone();
        let record = journal.sent_claims.get(id).ok_or("unknown claim")?;
        if self.sent_claim_phase(record, &journal) != "awaiting_claim" {
            return Err("claim funding is not committed".into());
        }
        let quote = record.quote.clone().ok_or("missing quote")?;
        self.verify_claim_quote(&quote)?;
        if let Some(text) = &record.exported {
            return Ok(text.clone());
        }
        let text = Envelope {
            quote,
            capability: record.capability.clone(),
            preimage: record.preimage.clone(),
        }
        .encode()?;
        self.services.update(|j| {
            j.sent_claims.get_mut(id).unwrap().exported = Some(text.clone());
        })?;
        Ok(text)
    }

    pub(super) fn import_claim(&self, text: &str) -> Result<()> {
        if !self.claims_enabled {
            return Err("funded claims disabled pending protocol validation".into());
        }
        let envelope = Envelope::parse(text)?;
        let id = envelope.quote.terms.claim_id.clone();
        if self
            .services
            .journal
            .lock()
            .unwrap()
            .sent_claims
            .contains_key(&id)
        {
            return Err("redeem this claim in a different regtest wallet".into());
        }
        let existing = self
            .services
            .journal
            .lock()
            .unwrap()
            .received_claims
            .get(&id)
            .cloned();
        if let Some(saved) = existing {
            if saved.envelope.encode()? != text {
                return Err("claim identity changed".into());
            }
            return Ok(());
        }
        self.verify_claim_quote(&envelope.quote)?;
        if self.services.journal.lock().unwrap().received_claims.len() >= 128 {
            return Err("claim storage limit reached".into());
        }
        self.services.update(|j| {
            j.received_claims.insert(
                id,
                ReceivedClaim {
                    envelope,
                    redeeming: false,
                    last_error: None,
                },
            );
        })
    }

    pub(super) fn redeem_claim(&self, id: &str) -> Result<()> {
        if !self.claims_enabled {
            return Err("funded claims disabled pending protocol validation".into());
        }
        let received = self
            .services
            .journal
            .lock()
            .unwrap()
            .received_claims
            .get(id)
            .cloned()
            .ok_or("unknown claim")?;
        if !received.redeeming {
            self.verify_claim_quote(&received.envelope.quote)?;
            self.services.update(|j| {
                j.received_claims.get_mut(id).unwrap().redeeming = true;
            })?;
        }
        self.services.update(|j| {
            j.received_claims.get_mut(id).unwrap().last_error = None;
        })?;
        self.send_redemption(id)
    }

    fn send_redemption(&self, id: &str) -> Result<()> {
        let received = self
            .services
            .journal
            .lock()
            .unwrap()
            .received_claims
            .get(id)
            .cloned()
            .ok_or("unknown claim")?;
        let terms = &received.envelope.quote.terms;
        self.create_hash_invoice(
            format!("claim:{id}"),
            terms.amount_msat,
            terms.payment_hash.clone(),
            Some(received.envelope.preimage),
            protocol::LIFETIME_SECONDS,
            0,
            None,
        )?;
        let record = self
            .services
            .journal
            .lock()
            .unwrap()
            .hash_invoices
            .get(&terms.payment_hash)
            .cloned()
            .ok_or("missing recipient invoice")?;
        if record.state == "received" {
            return Ok(());
        }
        self.send_claim_message(
            &terms.provider_node_id,
            Message::Redeem {
                claim_id: id.into(),
                capability: received.envelope.capability,
                invoice: record.invoice.ok_or("recipient invoice unavailable")?,
            },
        )
    }

    fn handle_claim_message(&self, sender: PublicKey, message: Message) -> Result<()> {
        let peer = sender.to_string();
        if !self
            .services
            .journal
            .lock()
            .unwrap()
            .pins
            .contains_key(&peer)
        {
            return Err("unpinned claim peer".into());
        }
        match message {
            Message::Prepare {
                claim_id,
                payment_hash,
                capability_hash,
                amount_msat,
            } => {
                let provider = self.claim_provider.as_ref().ok_or("provider disabled")?;
                let existing = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .provider_claims
                    .get(&claim_id)
                    .cloned();
                let mut quote = if let Some(saved) = existing {
                    let terms = &saved.quote.terms;
                    if saved.sender != peer
                        || terms.payment_hash != payment_hash
                        || terms.capability_hash != capability_hash
                        || terms.amount_msat != amount_msat
                    {
                        return Err("provider claim request changed".into());
                    }
                    saved.quote
                } else {
                    let journal = self.services.journal.lock().unwrap().clone();
                    let channels = self.manager.list_channels();
                    if journal.hash_invoices.len() >= 128
                        || journal.provider_claims.values().any(|c| {
                            if c.sender != peer {
                                return false;
                            }
                            let hash = &c.quote.terms.payment_hash;
                            let quoted = journal
                                .hash_invoices
                                .get(hash)
                                .is_none_or(|h| h.state == "registered");
                            (quoted
                                && c.quote
                                    .terms
                                    .is_current(self.tip.height, now().unwrap_or(u64::MAX)))
                                || channels.iter().any(|channel| {
                                    channel
                                        .pending_inbound_htlcs
                                        .iter()
                                        .any(|h| h.payment_hash.to_string() == *hash)
                                })
                        })
                    {
                        return Err("provider claim limit reached".into());
                    }
                    let terms = Terms {
                        version: 1,
                        network: "regtest".into(),
                        claim_id: claim_id.clone(),
                        provider_node_id: self.manager.get_our_node_id().to_string(),
                        provider_host: provider.host.clone(),
                        provider_port: provider.port,
                        payment_hash,
                        capability_hash,
                        amount_msat,
                        fee_msat: protocol::PROVIDER_FEE_MSAT,
                        latest_claim_height: self
                            .tip
                            .height
                            .checked_add(protocol::CLAIM_BLOCKS)
                            .ok_or("height overflow")?,
                        expires_at_unix: now()?
                            .checked_add(u64::from(protocol::LIFETIME_SECONDS))
                            .ok_or("clock overflow")?,
                        hold_delta: protocol::HOLD_DELTA,
                    };
                    terms.validate()?;
                    if !self.manager.list_channels().iter().any(|c| {
                        c.counterparty.node_id == sender
                            && c.is_usable
                            && c.inbound_capacity_msat >= terms.debit().unwrap()
                            && c.pending_inbound_htlcs.is_empty()
                    }) {
                        return Err("sender needs available provider channel liquidity".into());
                    }
                    let quote = Quote {
                        terms,
                        invoice: String::new(),
                    };
                    // Save immutable quote terms before core registration. A
                    // crash must never choose a different timestamp/commitment.
                    self.services.update(|j| {
                        j.provider_claims.insert(
                            claim_id.clone(),
                            ProviderClaim {
                                sender: peer.clone(),
                                quote: quote.clone(),
                            },
                        );
                    })?;
                    quote
                };
                if quote.invoice.is_empty() {
                    let terms = &quote.terms;
                    self.create_hash_invoice(
                        claim_id.clone(),
                        terms.debit()?,
                        terms.payment_hash.clone(),
                        None,
                        protocol::LIFETIME_SECONDS,
                        terms.hold_delta,
                        Some(terms.commitment()?.to_string()),
                    )?;
                    quote.invoice = self
                        .services
                        .journal
                        .lock()
                        .unwrap()
                        .hash_invoices
                        .get(&terms.payment_hash)
                        .and_then(|h| h.invoice.clone())
                        .ok_or("provider invoice unavailable")?;
                    self.services.update(|j| {
                        j.provider_claims.get_mut(&claim_id).unwrap().quote = quote.clone();
                    })?;
                }
                self.send_claim_message(&peer, Message::Quoted { quote })?;
            }
            Message::Quoted { quote } => {
                let id = quote.terms.claim_id.clone();
                let record = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .sent_claims
                    .get(&id)
                    .cloned()
                    .ok_or("unsolicited quote")?;
                if record.phase == "cancelling" {
                    return Ok(());
                }
                if record.provider != peer
                    || quote.terms.provider_node_id != peer
                    || quote.terms.provider_host != record.host
                    || quote.terms.provider_port != record.port
                    || quote.terms.amount_msat != record.amount_msat
                    || quote.terms.payment_hash
                        != protocol::digest(&protocol::bytes32(&record.preimage)?)
                    || quote.terms.capability_hash
                        != protocol::digest(&protocol::bytes32(&record.capability)?)
                {
                    return Err("provider quote does not match request".into());
                }
                if let Some(saved) = record.quote {
                    if saved != quote {
                        return Err("provider quote changed".into());
                    }
                } else {
                    self.verify_claim_quote(&quote)?;
                    self.services.update(|j| {
                        let record = j.sent_claims.get_mut(&id).unwrap();
                        record.quote = Some(quote);
                        record.phase = "quoted".into();
                    })?;
                }
            }
            Message::Check { claim_id } => {
                let claim = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .provider_claims
                    .get(&claim_id)
                    .cloned()
                    .ok_or("unknown provider claim")?;
                if claim.sender != peer {
                    return Err("wrong claim sender".into());
                }
                let record = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .hash_invoices
                    .get(&claim.quote.terms.payment_hash)
                    .cloned()
                    .ok_or("unknown held invoice")?;
                if record.state == "held" {
                    self.send_claim_message(&peer, Message::Ready { claim_id })?;
                }
            }
            Message::Ready { claim_id } => {
                let record = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .sent_claims
                    .get(&claim_id)
                    .cloned()
                    .ok_or("unknown sent claim")?;
                if record.provider != peer {
                    return Err("wrong claim provider".into());
                }
                self.services.update(|j| {
                    j.sent_claims.get_mut(&claim_id).unwrap().provider_ready = true;
                })?;
            }
            Message::Redeem {
                claim_id,
                capability,
                invoice,
            } => {
                let claim = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .provider_claims
                    .get(&claim_id)
                    .cloned()
                    .ok_or("unknown provider claim")?;
                let terms = claim.quote.terms;
                if protocol::digest(&protocol::bytes32(&capability)?) != terms.capability_hash {
                    return Err("invalid redemption capability".into());
                }
                let parsed =
                    Bolt11Invoice::from_str(&invoice).map_err(|_| "invalid recipient invoice")?;
                if parsed.get_payee_pub_key() != sender
                    || parsed.amount_milli_satoshis() != Some(terms.amount_msat)
                {
                    return Err("recipient invoice identity or amount mismatch".into());
                }
                let already_bound = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .hash_invoices
                    .get(&terms.payment_hash)
                    .is_some_and(|h| h.forward.is_some());
                if !already_bound && !terms.is_current(self.tip.height, now()?) {
                    return Err("claim expired".into());
                }
                self.forward_held_payment(terms.payment_hash, invoice, terms.fee_msat)?;
            }
            Message::Cancel { claim_id } => {
                let record = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .provider_claims
                    .get(&claim_id)
                    .cloned();
                if let Some(record) = record {
                    if record.sender != peer {
                        return Err("wrong claim sender".into());
                    }
                    let hash = record.quote.terms.payment_hash;
                    let state = self
                        .services
                        .journal
                        .lock()
                        .unwrap()
                        .hash_invoices
                        .get(&hash)
                        .cloned();
                    let live = self.manager.list_channels().iter().any(|c| {
                        c.pending_inbound_htlcs
                            .iter()
                            .any(|h| h.payment_hash.to_string() == hash)
                    });
                    if live
                        || state.is_some_and(|h| h.state != "registered" && h.state != "cancelled")
                    {
                        return Err("funded claim cannot be cancelled".into());
                    }
                    self.services.update(|j| {
                        if let Some(invoice) = j.hash_invoices.get_mut(&hash) {
                            invoice.state = "cancelled".into();
                        }
                        j.provider_claims.remove(&claim_id);
                    })?;
                }
                self.send_claim_message(&peer, Message::Cancelled { claim_id })?;
            }
            Message::Cancelled { claim_id } => {
                let record = self
                    .services
                    .journal
                    .lock()
                    .unwrap()
                    .sent_claims
                    .get(&claim_id)
                    .cloned()
                    .ok_or("unknown claim")?;
                if record.provider != peer || record.phase != "cancelling" {
                    return Err("unexpected cancellation response".into());
                }
                self.services.update(|j| {
                    j.sent_claims.remove(&claim_id);
                })?;
            }
            Message::Rejected { claim_id, reason } => {
                // A provider response can report a request problem, never mark
                // money received, failed or refunded in place of channel state.
                if !matches!(
                    reason.as_str(),
                    "already_bound" | "expired" | "request_rejected"
                ) {
                    return Err("unknown rejection reason".into());
                }
                self.services.update(|j| {
                    if let Some(record) = j.sent_claims.get_mut(&claim_id) {
                        if record.provider == peer {
                            record.last_error = Some(reason.clone());
                        }
                    }
                    if let Some(record) = j.received_claims.get_mut(&claim_id) {
                        if record.envelope.quote.terms.provider_node_id == peer {
                            record.last_error = Some(reason.clone());
                        }
                    }
                })?;
                self.services.event(json!({"kind":"claim_request_rejected","claim_id":claim_id,"node_id":peer,"reason":reason}))?;
            }
        }
        Ok(())
    }

    pub(super) fn process_claim_messages(&self, retry: bool) -> Result<()> {
        for (peer, bytes) in self.claim_wire.take_incoming() {
            if !self.claims_enabled {
                continue;
            }
            let Ok(message) = serde_json::from_slice::<Message>(&bytes.0) else {
                continue;
            };
            let id = match &message {
                Message::Prepare { claim_id, .. }
                | Message::Check { claim_id }
                | Message::Redeem { claim_id, .. }
                | Message::Cancel { claim_id } => Some(claim_id.clone()),
                _ => None,
            };
            if let Err(error) = self.handle_claim_message(peer, message) {
                if self.services.failed.load(Ordering::Relaxed) {
                    return Err("claim persistence failed".into());
                }
                if let Some(claim_id) = id.filter(|id| protocol::bytes32(id).is_ok()) {
                    let reason = match error.as_str() {
                        "held payment already bound" => "already_bound",
                        "claim expired" => "expired",
                        _ => "request_rejected",
                    };
                    self.send_claim_message(
                        &peer.to_string(),
                        Message::Rejected {
                            claim_id,
                            reason: reason.into(),
                        },
                    )?;
                }
            }
        }
        if !retry || !self.claims_enabled {
            return Ok(());
        }
        let journal = self.services.journal.lock().unwrap().clone();
        for (id, record) in &journal.sent_claims {
            match self.sent_claim_phase(record, &journal).as_str() {
                "preparing" => self.send_claim_message(
                    &record.provider,
                    Message::Prepare {
                        claim_id: id.clone(),
                        payment_hash: protocol::digest(&protocol::bytes32(&record.preimage)?),
                        capability_hash: protocol::digest(&protocol::bytes32(&record.capability)?),
                        amount_msat: record.amount_msat,
                    },
                )?,
                "committing" => {
                    let _ = self.resume_claim_commit(id);
                }
                "cancelling" => self.send_claim_message(
                    &record.provider,
                    Message::Cancel {
                        claim_id: id.clone(),
                    },
                )?,
                "funding" => self.send_claim_message(
                    &record.provider,
                    Message::Check {
                        claim_id: id.clone(),
                    },
                )?,
                _ => {}
            }
        }
        for (id, record) in &journal.received_claims {
            if record.redeeming && record.last_error.is_none() {
                let _ = self.send_redemption(id);
            }
        }
        if self.services.failed.load(Ordering::Relaxed) {
            return Err("claim persistence failed".into());
        }
        Ok(())
    }

    pub(super) fn claim_snapshots(&self, journal: &Journal) -> Value {
        let mut records = BTreeMap::new();
        for (id, record) in &journal.sent_claims {
            records.insert(id.clone(), json!({"claim_id":id,"request_id":record.request_id,"direction":"sent",
                "amount_msat":record.amount_msat,"provider":record.provider,
                "state":self.sent_claim_phase(record, journal),"terms":record.quote.as_ref().map(|q| &q.terms),"last_error":record.last_error,
                "quote_commitment":record.quote.as_ref().and_then(|q| q.terms.commitment().ok()).map(|h|h.to_string())}));
        }
        for (id, record) in &journal.received_claims {
            let terms = &record.envelope.quote.terms;
            let received = journal
                .hash_invoices
                .get(&terms.payment_hash)
                .is_some_and(|h| h.state == "received");
            records.insert(id.clone(), json!({"claim_id":id,"direction":"received","amount_msat":terms.amount_msat,
                "provider":terms.provider_node_id,"terms":terms,"last_error":record.last_error,
                "state":if received {"received"} else if record.redeeming {"claiming"}
                    else if !terms.is_current(self.tip.height, now().unwrap_or(u64::MAX)) {"expired"} else {"ready"}}));
        }
        json!(records)
    }
}
