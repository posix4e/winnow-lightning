//! Low-level supplied-hash forwarding experiment. This is not a shareable claim
//! protocol: authentication, quoting and bearer authorization must be layered on
//! it only after the regtest recovery gates pass.
use super::*;
use lightning::chain::channelmonitor::HTLC_FAIL_BACK_BUFFER;

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct HeldForward {
    invoice: String,
    amount_msat: u64,
    max_fee_msat: u64,
    // An absolute limit, so restarting cannot extend an accepted route budget.
    latest_outgoing_expiry: u32,
}

impl Engine {
    pub(super) fn verify_claim_quote(&self, quote: &crate::claim_protocol::Quote) -> Result<()> {
        use lightning_invoice::Bolt11InvoiceDescriptionRef;
        quote.terms.validate()?;
        if quote.invoice.len() > 12_000 {
            return Err("quote invoice too large".into());
        }
        let invoice =
            Bolt11Invoice::from_str(&quote.invoice).map_err(|_| "invalid quote invoice")?;
        self.verify_invoice(&invoice, quote.terms.debit()?)?;
        if invoice.get_payee_pub_key().to_string() != quote.terms.provider_node_id
            || invoice.payment_hash().to_string() != quote.terms.payment_hash
            || invoice.min_final_cltv_expiry_delta() != u64::from(quote.terms.hold_delta) + 3
        {
            return Err("quote invoice terms mismatch".into());
        }
        match invoice.description() {
            Bolt11InvoiceDescriptionRef::Hash(hash) if hash.0 == quote.terms.commitment()? => {}
            _ => return Err("quote commitment mismatch".into()),
        }
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "clock before epoch")?
            .as_secs();
        if !quote.terms.is_current(self.tip.height, now)
            || invoice
                .expires_at()
                .is_none_or(|expiry| expiry.as_secs() < quote.terms.expires_at_unix)
        {
            return Err("claim expired".into());
        }
        Ok(())
    }

    pub(super) fn forward_held_payment(
        &self,
        hash: String,
        invoice: String,
        max_fee_msat: u64,
    ) -> Result<()> {
        if invoice.len() > 32768 {
            return Err("invoice too large".into());
        }
        let parsed = Bolt11Invoice::from_str(&invoice).map_err(|_| "invalid invoice")?;
        if parsed.payment_hash().to_string() != hash || parsed.currency() != Currency::Regtest {
            return Err("held payment hash or network mismatch".into());
        }
        let record = self
            .services
            .journal
            .lock()
            .unwrap()
            .hash_invoices
            .get(&hash)
            .cloned()
            .ok_or("unknown held payment")?;
        if let Some(bound) = &record.forward {
            if bound.invoice != invoice || bound.max_fee_msat != max_fee_msat {
                return Err("held payment already bound".into());
            }
            return self.reconcile_held_payments();
        }
        if record.state != "held" || record.preimage.is_some() {
            return Err("payment is not held".into());
        }
        let amount = parsed.amount_milli_satoshis().ok_or("amount required")?;
        if amount == 0
            || amount
                .checked_add(max_fee_msat)
                .is_none_or(|n| n > record.amount_msat)
        {
            return Err("payout exceeds held amount".into());
        }
        // The core automatically fails an unclaimed inbound at claim_deadline.
        // Leave its full published fail-back margin before that boundary, also
        // bounding route randomization and the single downstream HTLC's expiry.
        let latest = record
            .claim_deadline
            .and_then(|h| h.checked_sub(HTLC_FAIL_BACK_BUFFER))
            .ok_or("missing held payment deadline")?;
        if latest
            <= self
                .tip
                .height
                .saturating_add(parsed.min_final_cltv_expiry_delta() as u32)
        {
            return Err("insufficient held payment lifetime".into());
        }
        // A journal label alone is insufficient after timeout or force close.
        let held = self.manager.list_channels().iter().any(|channel| {
            channel.pending_inbound_htlcs.iter().any(|htlc| {
                htlc.payment_hash.to_string() == hash
                    && !htlc.is_dust
                    && htlc.amount_msat == record.amount_msat
                    && matches!(
                        htlc.state,
                        Some(lightning::ln::channel_state::InboundHTLCStateDetails::Committed)
                    )
            })
        });
        if !held {
            return Err("no live non-dust incoming HTLC".into());
        }
        // Validation, including the independently pinned PQ signature, happens
        // before irrevocably choosing the recipient invoice.
        self.verify_invoice(&parsed, amount)?;
        self.services.update(|j| {
            j.hash_invoices.get_mut(&hash).unwrap().forward = Some(HeldForward {
                invoice,
                amount_msat: amount,
                max_fee_msat,
                latest_outgoing_expiry: latest,
            });
        })?;
        self.reconcile_held_payments()
    }

    pub(super) fn reconcile_held_payments(&self) -> Result<()> {
        // Persisted bindings and core payment IDs make every restart/replay use
        // the same attempt. A receipt is persisted before fulfilling upstream.
        let journal = self.services.journal.lock().unwrap().clone();
        for (hash, record) in journal.hash_invoices {
            let Some(bound) = record.forward else {
                continue;
            };
            if record.state == "received" || record.state == "failing" {
                continue;
            }
            let bytes: [u8; 32] = hex::decode(&hash)
                .map_err(|_| "invalid saved hash")?
                .try_into()
                .map_err(|_| "invalid saved hash length")?;
            if let Some(preimage) = journal.receipts.get(&hash) {
                let secret: [u8; 32] = hex::decode(preimage)
                    .map_err(|_| "invalid saved receipt")?
                    .try_into()
                    .map_err(|_| "invalid saved receipt length")?;
                self.manager.claim_funds(PaymentPreimage(secret));
            } else if journal
                .payments
                .get(&hash)
                .is_some_and(|p| p["state"] == "failed")
            {
                self.manager.fail_htlc_backwards(&PaymentHash(bytes));
                self.services.update(|j| {
                    j.hash_invoices.get_mut(&hash).unwrap().state = "failing".into();
                })?;
            } else {
                let tracked = self.manager.list_recent_payments().iter().any(|p| {
                    let id = match p {
                        RecentPaymentDetails::AwaitingInvoice { payment_id }
                        | RecentPaymentDetails::Pending { payment_id, .. }
                        | RecentPaymentDetails::Fulfilled { payment_id, .. }
                        | RecentPaymentDetails::Abandoned { payment_id, .. } => payment_id,
                    };
                    id.0 == bytes
                });
                if tracked {
                    continue;
                }
                let remaining = bound.latest_outgoing_expiry.saturating_sub(self.tip.height);
                if remaining == 0 {
                    self.manager.fail_htlc_backwards(&PaymentHash(bytes));
                    self.services.update(|j| {
                        j.hash_invoices.get_mut(&hash).unwrap().state = "failing".into();
                    })?;
                } else if remaining > 0 {
                    // A route rejection is recorded by pay_invoice. Leave it
                    // for the next pass to fail upstream, without a new payout.
                    if let Err(error) = self.pay_invoice(
                        bound.invoice.clone(),
                        bound.amount_msat,
                        bound.max_fee_msat,
                        Some(remaining),
                    ) {
                        if self.services.failed.load(Ordering::Relaxed) {
                            return Err(error);
                        }
                        // Validation may fail after a restart (e.g. the invoice
                        // expired). This is a failed payout, not storage loss.
                        self.services.update(|j| {
                            j.payments.entry(hash.clone()).or_insert_with(|| {
                                json!({
                                    "invoice":bound.invoice,"amount_msat":bound.amount_msat,
                                    "max_fee_msat":bound.max_fee_msat,"state":"failed"
                                })
                            })["state"] = json!("failed");
                        })?;
                    }
                }
            }
        }
        Ok(())
    }
}
