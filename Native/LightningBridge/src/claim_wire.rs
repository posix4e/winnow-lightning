//! Bounded private control messages over the existing authenticated Lightning
//! connection. Requests are retried from the durable claim journal; this queue
//! never acts as a payment ledger and contains no preimages.
use bitcoin::secp256k1::PublicKey;
use lightning::{
    io,
    ln::{
        msgs::{DecodeError, Init, LightningError},
        peer_handler::CustomMessageHandler,
        wire::{CustomMessageReader, Type},
    },
    types::features::{InitFeatures, NodeFeatures},
    util::ser::{LengthLimitedRead, Readable, Writeable, Writer},
};
use std::sync::Mutex;

const WIRE_TYPE: u16 = 39_001; // Private experimental odd type; not a BOLT assignment.
const MAX_MESSAGE: usize = 16_384;
const MAX_QUEUE: usize = 32;

#[derive(Clone)]
pub struct Message(pub Vec<u8>);
impl std::fmt::Debug for Message {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PrivateClaimMessage")
            .field("bytes", &self.0.len())
            .finish()
    }
}
impl Type for Message {
    fn type_id(&self) -> u16 {
        WIRE_TYPE
    }
}
impl Writeable for Message {
    fn write<W: Writer>(&self, writer: &mut W) -> Result<(), io::Error> {
        (self.0.len() as u16).write(writer)?;
        writer.write_all(&self.0)
    }
}
#[derive(Default)]
pub struct Handler {
    incoming: Mutex<Vec<(PublicKey, Message)>>,
    outgoing: Mutex<Vec<(PublicKey, Message)>>,
}
impl Handler {
    pub fn take_incoming(&self) -> Vec<(PublicKey, Message)> {
        std::mem::take(&mut *self.incoming.lock().unwrap())
    }
    pub fn send(&self, node: PublicKey, bytes: Vec<u8>) -> Result<(), &'static str> {
        if bytes.len() > MAX_MESSAGE {
            return Err("claim control message exceeds limit");
        }
        let mut queue = self.outgoing.lock().unwrap();
        if queue.len() >= MAX_QUEUE {
            return Ok(());
        }
        queue.push((node, Message(bytes)));
        Ok(())
    }
}
impl CustomMessageReader for Handler {
    type CustomMessage = Message;
    fn read<R: LengthLimitedRead>(
        &self,
        kind: u16,
        reader: &mut R,
    ) -> Result<Option<Message>, DecodeError> {
        if kind != WIRE_TYPE {
            return Ok(None);
        }
        let length = u16::read(reader)? as usize;
        if length == 0 || length > MAX_MESSAGE {
            return Err(DecodeError::InvalidValue);
        }
        let mut bytes = vec![0; length];
        reader.read_exact(&mut bytes)?;
        Ok(Some(Message(bytes)))
    }
}
impl CustomMessageHandler for Handler {
    fn handle_custom_message(
        &self,
        message: Message,
        node: PublicKey,
    ) -> Result<(), LightningError> {
        let mut queue = self.incoming.lock().unwrap();
        // Dropping excess control requests is safe: no acknowledgement or
        // financial action occurred and the durable sender retries the same ID.
        if queue.len() < MAX_QUEUE {
            queue.push((node, message));
        }
        Ok(())
    }
    fn get_and_clear_pending_msg(&self) -> Vec<(PublicKey, Message)> {
        std::mem::take(&mut *self.outgoing.lock().unwrap())
    }
    fn peer_disconnected(&self, _: PublicKey) {}
    fn peer_connected(&self, _: PublicKey, _: &Init, _: bool) -> Result<(), ()> {
        Ok(())
    }
    fn provided_node_features(&self) -> NodeFeatures {
        NodeFeatures::empty()
    }
    fn provided_init_features(&self, _: PublicKey) -> InitFeatures {
        InitFeatures::empty()
    }
}
