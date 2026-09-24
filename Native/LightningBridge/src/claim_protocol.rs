//! Private Winnow regtest claim v1. Canonical encoding is deliberately simple:
//! lowercase hex of fixed-field JSON after the `wlnclaim1:` prefix. No generic
//! URL, public invoice key or payload field is allowed to establish trust.
use bitcoin::hashes::{sha256, Hash};
use lightning::chain::channelmonitor::HTLC_FAIL_BACK_BUFFER;
use serde::{Deserialize, Serialize};

pub const MAX_TEXT_BYTES: usize = 32_768;
pub const CLAIM_BLOCKS: u32 = 72;
pub const MAX_ROUTE_CLTV: u32 = 144;
// Core adds three more blocks to the advertised final delta. Keeping that
// buffer here as well tolerates block arrival while creating/funding the quote.
pub const HOLD_DELTA: u16 = (CLAIM_BLOCKS + MAX_ROUTE_CLTV + 2 * HTLC_FAIL_BACK_BUFFER + 3) as u16;
pub const LIFETIME_SECONDS: u32 = 3600;
pub const PROVIDER_FEE_MSAT: u64 = 100_000;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Terms {
    pub version: u8,
    pub network: String,
    pub claim_id: String,
    pub provider_node_id: String,
    pub provider_host: String,
    pub provider_port: u16,
    pub payment_hash: String,
    pub capability_hash: String,
    pub amount_msat: u64,
    pub fee_msat: u64,
    pub latest_claim_height: u32,
    pub expires_at_unix: u64,
    pub hold_delta: u16,
}

pub fn bytes32(value: &str) -> Result<[u8; 32], &'static str> {
    let bytes: [u8; 32] = hex::decode(value)
        .map_err(|_| "invalid claim field")?
        .try_into()
        .map_err(|_| "invalid claim field length")?;
    if hex::encode(bytes) != value {
        return Err("noncanonical claim field");
    }
    Ok(bytes)
}
pub fn digest(bytes: &[u8]) -> String {
    sha256::Hash::hash(bytes).to_string()
}

impl Terms {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.version != 1 || self.network != "regtest" {
            return Err("unsupported claim version or network");
        }
        bytes32(&self.claim_id)?;
        bytes32(&self.payment_hash)?;
        bytes32(&self.capability_hash)?;
        use std::str::FromStr;
        let node = bitcoin::secp256k1::PublicKey::from_str(&self.provider_node_id)
            .map_err(|_| "invalid provider identity")?;
        if node.to_string() != self.provider_node_id {
            return Err("noncanonical provider identity");
        }
        if self.provider_host.is_empty()
            || self.provider_host.len() > 253
            || !self
                .provider_host
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b".:-".contains(&c))
            || self.provider_port == 0
        {
            return Err("invalid provider address");
        }
        // Keep every accepted payment non-dust at the fixture fee policy. The
        // actual channel's non-dust HTLC checks remain mandatory after funding.
        if !(5_000_000..=100_000_000).contains(&self.amount_msat)
            || self.fee_msat != PROVIDER_FEE_MSAT
            || self.hold_delta != HOLD_DELTA
            || self.latest_claim_height == 0
            || self.expires_at_unix == 0
        {
            return Err("unsupported claim terms");
        }
        Ok(())
    }
    pub fn commitment(&self) -> Result<sha256::Hash, &'static str> {
        self.validate()?;
        let mut bytes = b"winnow-regtest-funded-claim-v1\0".to_vec();
        bytes.extend(serde_json::to_vec(self).map_err(|_| "claim encoding failed")?);
        Ok(sha256::Hash::hash(&bytes))
    }
    pub fn debit(&self) -> Result<u64, &'static str> {
        self.amount_msat
            .checked_add(self.fee_msat)
            .ok_or("claim amount overflow")
    }
    pub fn is_current(&self, height: u32, unix: u64) -> bool {
        height < self.latest_claim_height && unix < self.expires_at_unix
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Quote {
    pub terms: Terms,
    // The pinned provider's hybrid BOLT11 signature authenticates the terms
    // commitment in description_hash, as well as amount and payment hash.
    pub invoice: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub quote: Quote,
    pub capability: String,
    pub preimage: String,
}

impl Envelope {
    pub fn validate(&self) -> Result<(), &'static str> {
        self.quote.terms.validate()?;
        if self.quote.invoice.len() > 12_000 || self.quote.invoice.is_empty() {
            return Err("invalid quote invoice length");
        }
        if digest(&bytes32(&self.preimage)?) != self.quote.terms.payment_hash
            || digest(&bytes32(&self.capability)?) != self.quote.terms.capability_hash
        {
            return Err("claim secret commitment mismatch");
        }
        Ok(())
    }
    pub fn encode(&self) -> Result<String, &'static str> {
        self.validate()?;
        let bytes = serde_json::to_vec(self).map_err(|_| "claim encoding failed")?;
        let text = format!("wlnclaim1:{}", hex::encode(bytes));
        if text.len() > MAX_TEXT_BYTES {
            return Err("claim exceeds text limit");
        }
        Ok(text)
    }
    pub fn parse(text: &str) -> Result<Self, &'static str> {
        if text.len() > MAX_TEXT_BYTES {
            return Err("claim exceeds text limit");
        }
        let encoded = text
            .strip_prefix("wlnclaim1:")
            .ok_or("unsupported claim prefix")?;
        let bytes = hex::decode(encoded).map_err(|_| "invalid claim encoding")?;
        let value: Self = serde_json::from_slice(&bytes).map_err(|_| "invalid claim schema")?;
        if value.encode()? != text {
            return Err("noncanonical claim encoding");
        }
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample() -> Envelope {
        Envelope {
            quote: Quote {
                terms: Terms {
                    version: 1,
                    network: "regtest".into(),
                    claim_id: hex::encode([3; 32]),
                    provider_node_id:
                        "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798".into(),
                    provider_host: "127.0.0.1".into(),
                    provider_port: 9735,
                    payment_hash: digest(&[4; 32]),
                    capability_hash: digest(&[5; 32]),
                    amount_msat: 5_000_000,
                    fee_msat: PROVIDER_FEE_MSAT,
                    latest_claim_height: 200,
                    expires_at_unix: 1_800_000_000,
                    hold_delta: HOLD_DELTA,
                },
                invoice: "parser-only-fixture; signature checked separately".into(),
            },
            capability: hex::encode([5; 32]),
            preimage: hex::encode([4; 32]),
        }
    }
    #[test]
    fn canonical_round_trip_and_secret_binding() {
        let value = sample();
        let text = value.encode().unwrap();
        assert_eq!(Envelope::parse(&text).unwrap().encode().unwrap(), text);
        let mut changed = value.clone();
        changed.preimage = hex::encode([6; 32]);
        assert!(changed.encode().is_err());
        changed = value.clone();
        changed.capability = hex::encode([6; 32]);
        assert!(changed.encode().is_err());
        assert!(Envelope::parse(&text.to_uppercase()).is_err());
        assert!(Envelope::parse(&"a".repeat(MAX_TEXT_BYTES + 1)).is_err());
    }
    #[test]
    fn every_public_term_changes_authentication_commitment() {
        let value = sample();
        let original = value.quote.terms.commitment().unwrap();
        let fields = serde_json::to_value(&value.quote.terms).unwrap();
        for (key, field) in fields.as_object().unwrap() {
            let mut changed = fields.clone();
            changed[key] = match field {
                serde_json::Value::String(s) => serde_json::json!(format!("{s}a")),
                serde_json::Value::Number(n) => serde_json::json!(n.as_u64().unwrap() + 1),
                _ => unreachable!(),
            };
            let terms: Result<Terms, _> = serde_json::from_value(changed);
            assert!(
                terms.map_or(true, |t| t.commitment() != Ok(original)),
                "{key}"
            );
        }
    }
    #[test]
    fn stricter_deadline_and_route_margin_are_explicit() {
        let terms = sample().quote.terms;
        assert!(terms.is_current(199, 1_799_999_999));
        assert!(!terms.is_current(200, 1_799_999_999));
        assert!(!terms.is_current(199, 1_800_000_000));
        assert!(u32::from(HOLD_DELTA) - CLAIM_BLOCKS - 2 * HTLC_FAIL_BACK_BUFFER > MAX_ROUTE_CLTV);
        assert_eq!(terms.debit().unwrap(), 5_100_000);
    }
}
