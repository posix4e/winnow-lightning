//! Low-level PQLN bridge. Winnow owns the Bitcoin wallet and chain source.
pub const CORE_REVISION: &str = "1d7dda453dd385f3ede84c39eed5d20afe34e02a";
pub mod engine;
mod worker;

use engine::{Command, Config};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
};
use worker::Worker;

#[repr(C)]
pub struct Buffer {
    pub bytes: *mut u8,
    pub length: usize,
}
static ENGINES: OnceLock<Mutex<BTreeMap<u64, Worker>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
fn engines() -> &'static Mutex<BTreeMap<u64, Worker>> {
    ENGINES.get_or_init(Default::default)
}

unsafe fn input<'a>(bytes: *const u8, length: usize) -> Result<&'a [u8], String> {
    if bytes.is_null() || length == 0 || length > 9_000_000 {
        return Err("invalid input buffer".into());
    }
    // C callers provide a live buffer of exactly `length` bytes for the call.
    Ok(unsafe { std::slice::from_raw_parts(bytes, length) })
}

unsafe fn respond(output: *mut Buffer, result: Result<Value, String>) -> i32 {
    if output.is_null() {
        return -1;
    }
    let (code, value) = match result {
        Ok(value) => (0, json!({"ok":true, "result":value})),
        Err(error) => (1, json!({"ok":false, "error":error})),
    };
    let bytes = serde_json::to_vec(&value)
        .expect("JSON response")
        .into_boxed_slice();
    let length = bytes.len();
    let bytes = Box::into_raw(bytes) as *mut u8;
    unsafe {
        *output = Buffer { bytes, length };
    }
    code
}

/// See the C header for pointer ownership and serialization requirements.
#[no_mangle]
pub unsafe extern "C" fn wln_create(
    config: *const u8,
    config_length: usize,
    seed: *const u8,
    seed_length: usize,
    output: *mut Buffer,
) -> i32 {
    if output.is_null() {
        return -1;
    }
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<Value, String> {
        let config: Config = serde_json::from_slice(unsafe { input(config, config_length)? })
            .map_err(|_| "invalid engine configuration")?;
        let seed: &[u8; 32] = unsafe { input(seed, seed_length)? }
            .try_into()
            .map_err(|_| "seed must be 32 bytes")?;
        let mut registry = engines()
            .lock()
            .map_err(|_| "engine registry unavailable")?;
        if registry.len() >= 16 {
            return Err("too many engine handles".into());
        }
        let (engine, snapshot) = Worker::new(config, seed)?;
        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        if handle == 0 {
            return Err("engine handle exhausted".into());
        }
        let result = json!({"handle":handle, "snapshot":snapshot});
        registry.insert(handle, engine);
        Ok(result)
    }))
    .unwrap_or_else(|_| Err("native initialization failed".into()));
    unsafe { respond(output, result) }
}

#[no_mangle]
pub unsafe extern "C" fn wln_call(
    handle: u64,
    command: *const u8,
    command_length: usize,
    output: *mut Buffer,
) -> i32 {
    if output.is_null() {
        return -1;
    }
    let result = (|| -> Result<Value, String> {
        let command: Command = serde_json::from_slice(unsafe { input(command, command_length)? })
            .map_err(|_| "invalid engine command")?;
        let registry = engines()
            .lock()
            .map_err(|_| "engine registry unavailable")?;
        registry
            .get(&handle)
            .ok_or("unknown or closed engine")?
            .call(command)
    })();
    unsafe { respond(output, result) }
}

#[no_mangle]
pub extern "C" fn wln_destroy(handle: u64) {
    if let Ok(mut registry) = engines().lock() {
        registry.remove(&handle);
    }
}

/// Free exactly once with the pointer and length returned by this library.
#[no_mangle]
pub unsafe extern "C" fn wln_buffer_free(buffer: Buffer) {
    if !buffer.bytes.is_null() {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                buffer.bytes,
                buffer.length,
            )));
        }
    }
}
