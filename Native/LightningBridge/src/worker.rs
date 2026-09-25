use crate::engine::{Command, Config, Engine};
use serde_json::Value;
use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    sync::mpsc,
    thread::{self, JoinHandle},
};
use zeroize::Zeroizing;

enum Message {
    Call(Command, mpsc::SyncSender<Result<Value, String>>),
    Stop,
}

/// Swift's cooperative executor has a small stack. ML-DSA's reference
/// implementation needs more, including during KeysManager construction.
/// Keep the entire engine on one explicitly sized thread, not just signing.
/// Calls never enter Swift, so waiting here cannot form an actor/callback cycle.
pub struct Worker {
    sender: mpsc::SyncSender<Message>,
    thread: Option<JoinHandle<()>>,
}

impl Worker {
    pub fn new(config: Config, seed: &[u8; 32]) -> Result<(Self, Value), String> {
        let seed = Zeroizing::new(*seed);
        let (sender, receiver) = mpsc::sync_channel(1);
        let (started, startup) = mpsc::sync_channel(1);
        let thread = thread::Builder::new()
            .name("winnow-lightning".into())
            .stack_size(8 * 1024 * 1024)
            .spawn(move || {
                let initialized = catch_unwind(AssertUnwindSafe(|| Engine::new(config, &seed)));
                drop(seed);
                let mut engine = match initialized {
                    Ok(Ok(engine)) => engine,
                    Ok(Err(error)) => {
                        let _ = started.send(Err(error));
                        return;
                    }
                    Err(_) => {
                        let _ = started.send(Err("native initialization failed".into()));
                        return;
                    }
                };
                if started.send(Ok(engine.status())).is_err() {
                    return;
                }
                while let Ok(message) = receiver.recv() {
                    match message {
                        Message::Stop => break,
                        Message::Call(command, reply) => {
                            let result =
                                match catch_unwind(AssertUnwindSafe(|| engine.call(command))) {
                                    Ok(result) => result,
                                    Err(_) => {
                                        engine.poisoned = true;
                                        Err("native failure; engine stopped".into())
                                    }
                                };
                            if reply.send(result).is_err() {
                                break;
                            }
                        }
                    }
                }
            })
            .map_err(|_| "could not start native worker")?;
        let worker = Self {
            sender,
            thread: Some(thread),
        };
        let snapshot = startup
            .recv()
            .map_err(|_| "native worker stopped during initialization")??;
        Ok((worker, snapshot))
    }

    pub fn call(&self, command: Command) -> Result<Value, String> {
        let (reply, receiver) = mpsc::sync_channel(1);
        self.sender
            .send(Message::Call(command, reply))
            .map_err(|_| "native worker stopped")?;
        receiver.recv().map_err(|_| "native worker stopped")?
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.sender.send(Message::Stop);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
