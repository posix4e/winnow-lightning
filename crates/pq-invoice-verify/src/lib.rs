use lightning::ln::invoice_utils::{verify_bolt11_pq_signature, Bolt11PqVerification};
use lightning::sign::pq::PQ_PUBLIC_KEY_LEN;
use lightning::util::logger::{Logger, Record};
use lightning_invoice::Bolt11Invoice;
use std::str::FromStr;

struct QuietLogger;

impl Logger for QuietLogger {
    fn log(&self, _record: Record) {}
}

fn decode_trusted_key(input: &str) -> Result<[u8; PQ_PUBLIC_KEY_LEN], String> {
    let hex = input.trim();
    if hex.len() != PQ_PUBLIC_KEY_LEN * 2 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(format!(
            "trusted ML-DSA key must be {} hex characters",
            PQ_PUBLIC_KEY_LEN * 2
        ));
    }
    let mut key = [0u8; PQ_PUBLIC_KEY_LEN];
    for (index, pair) in hex.as_bytes().chunks_exact(2).enumerate() {
        let text = std::str::from_utf8(pair).map_err(|error| error.to_string())?;
        key[index] = u8::from_str_radix(text, 16).map_err(|error| error.to_string())?;
    }
    Ok(key)
}

pub fn verify(invoice_text: &str, key_text: &str) -> Result<String, String> {
    let invoice = Bolt11Invoice::from_str(invoice_text.trim())
        .map_err(|error| format!("invalid BOLT 11 invoice: {error}"))?;
    if invoice.is_expired() {
        return Err("invoice expired".into());
    }
    let trusted_key = decode_trusted_key(&key_text)?;
    match verify_bolt11_pq_signature(&invoice, Some(&trusted_key), &QuietLogger) {
        Bolt11PqVerification::Verified => Ok(format!(
            "verified PQLN invoice for {}",
            invoice.get_payee_pub_key()
        )),
        Bolt11PqVerification::Absent => Err("invoice has no PQLN signature (downgrade)".into()),
        Bolt11PqVerification::Unanchored => {
            Err("PQLN signature is not bound to the trusted key".into())
        }
        Bolt11PqVerification::Invalid => Err("PQLN signature or trusted key is invalid".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lightning::sign::{KeysManager, NodeSigner, Recipient};
    use lightning_invoice::{Currency, InvoiceBuilder, PaymentHash, PaymentSecret};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn signed_invoice(with_pq: bool) -> (String, String) {
        let keys = KeysManager::new(&[42; 32], 0, 0, false);
        let key = keys.get_pq_node_id().expect("PQ identity");
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let mut raw = InvoiceBuilder::new(Currency::Regtest)
            .description("research invoice".into())
            .payment_hash(PaymentHash([0; 32]))
            .payment_secret(PaymentSecret([42; 32]))
            .duration_since_epoch(Duration::from_secs(now.as_secs()))
            .build_raw()
            .unwrap();
        if with_pq {
            lightning_invoice::pq::append_chunks(
                &mut raw.data.tagged_fields,
                lightning_invoice::pq::TAG_PQ_PUBLIC_KEY,
                &key,
            );
            let signature = keys
                .sign_pq_bolt11_invoice(&raw.pq_signable_bytes())
                .unwrap();
            lightning_invoice::pq::append_chunks(
                &mut raw.data.tagged_fields,
                lightning_invoice::pq::TAG_PQ_SIGNATURE,
                &signature,
            );
        }
        let signature = keys.sign_invoice(&raw, Recipient::Node);
        let invoice = Bolt11Invoice::from_signed(raw.sign(|_| signature).unwrap()).unwrap();
        let key_hex: String = key.iter().map(|byte| format!("{byte:02x}")).collect();
        (invoice.to_string(), key_hex)
    }

    #[test]
    fn key_parser_requires_exact_length_and_hex() {
        assert!(decode_trusted_key(&"ab".repeat(PQ_PUBLIC_KEY_LEN)).is_ok());
        assert!(decode_trusted_key("ab").is_err());
        assert!(decode_trusted_key(&"zz".repeat(PQ_PUBLIC_KEY_LEN)).is_err());
    }

    #[test]
    fn accepts_only_invoice_bound_to_trusted_key() {
        let (invoice, key) = signed_invoice(true);
        assert!(verify(&invoice, &key)
            .unwrap()
            .starts_with("verified PQLN invoice"));
        let wrong_key = "00".repeat(PQ_PUBLIC_KEY_LEN);
        assert!(verify(&invoice, &wrong_key)
            .unwrap_err()
            .contains("invalid"));
        let (classical, _) = signed_invoice(false);
        assert!(verify(&classical, &key).unwrap_err().contains("downgrade"));
    }
}
