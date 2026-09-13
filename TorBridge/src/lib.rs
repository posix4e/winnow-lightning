//! App-owned Tor runtime. No direct destination sockets or OS name resolution.
use std::{ffi::CStr, os::raw::c_char, path::PathBuf, sync::{Arc, Mutex, atomic::{AtomicU16, AtomicU8, Ordering}}};
use arti_client::{TorClient, TorClientConfig};
use tokio::{io::{AsyncReadExt, AsyncWriteExt}, net::{TcpListener, TcpStream}, runtime::Runtime, sync::Semaphore};
use tokio_util::compat::FuturesAsyncReadCompatExt;
use tor_rtcompat::PreferredRuntime;
use tor_socksproto::{Buffer, Handshake, NextStep, SocksCmd, SocksProxyHandshake, SocksRequest, SocksStatus};

struct Engine { runtime: Runtime, state: Arc<AtomicU8>, port: Arc<AtomicU16> }
static ENGINE: Mutex<Option<Engine>> = Mutex::new(None);

/// Start once. Path must be an absolute, NUL-terminated UTF-8 app-owned directory.
/// Returns 0 on accepted start, -1 on invalid configuration. Poll state for readiness.
/// # Safety
/// `path` must point to a readable NUL-terminated string for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn winnow_tor_start(path: *const c_char) -> i32 {
    if path.is_null() { return -1; }
    // Arti dependencies may enable more than one rustls backend. Select one
    // explicitly before bootstrap instead of letting rustls panic at runtime.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let Ok(path) = (unsafe { CStr::from_ptr(path) }).to_str() else { return -1; };
    let root = PathBuf::from(path);
    if !root.is_absolute() { return -1; }
    let Ok(mut guard) = ENGINE.lock() else { return -1; };
    if guard.is_some() { return -1; }
    let Ok(runtime) = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() else { return -1; };
    let state = Arc::new(AtomicU8::new(1));
    let port = Arc::new(AtomicU16::new(0));
    let task_state = state.clone(); let task_port = port.clone();
    runtime.spawn(async move {
        if serve(root, task_state.clone(), task_port.clone()).await.is_err() {
            task_port.store(0, Ordering::Release);
            task_state.store(3, Ordering::Release);
        }
    });
    *guard = Some(Engine { runtime, state, port });
    0
}

/// 0 stopped, 1 bootstrapping, 2 ready, 3 failed. Never falls back to direct.
#[unsafe(no_mangle)]
pub extern "C" fn winnow_tor_state() -> u8 {
    ENGINE.lock().ok().and_then(|g| g.as_ref().map(|e| e.state.load(Ordering::Acquire))).unwrap_or(0)
}
#[unsafe(no_mangle)]
pub extern "C" fn winnow_tor_port() -> u16 {
    ENGINE.lock().ok().and_then(|g| g.as_ref().map(|e| e.port.load(Ordering::Acquire))).unwrap_or(0)
}
/// Cancel all Tor tasks, connections and the listener. Call off the UI thread.
#[unsafe(no_mangle)]
pub extern "C" fn winnow_tor_stop() {
    if let Ok(mut guard) = ENGINE.lock() {
        if let Some(engine) = guard.take() {
            engine.port.store(0, Ordering::Release);
            engine.state.store(0, Ordering::Release);
            engine.runtime.shutdown_timeout(std::time::Duration::from_secs(5));
        }
    }
}

async fn serve(root: PathBuf, state: Arc<AtomicU8>, port: Arc<AtomicU16>) -> anyhow::Result<()> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&root)?;
    let mut config = TorClientConfig::builder();
    config.storage().cache_dir(arti_client::config::CfgPath::new_literal(root.join("cache")))
        .state_dir(arti_client::config::CfgPath::new_literal(root.join("state")));
    let client = tokio::time::timeout(std::time::Duration::from_secs(300),
        TorClient::create_bootstrapped(config.build()?)).await??;
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0)).await?;
    port.store(listener.local_addr()?.port(), Ordering::Release);
    state.store(2, Ordering::Release);
    let permits = Arc::new(Semaphore::new(64));
    loop {
        let (socket, address) = listener.accept().await?;
        if !address.ip().is_loopback() { continue; }
        let Ok(permit) = permits.clone().try_acquire_owned() else { continue; };
        let client = client.isolated_client();
        tokio::spawn(async move {
            let _permit = permit;
            let _ = proxy(socket, client).await;
        });
    }
}

async fn request(socket: &mut TcpStream) -> anyhow::Result<SocksRequest> {
    let mut hs = SocksProxyHandshake::new();
    let mut buf = Buffer::new_precise();
    loop {
        match hs.step(&mut buf)? {
            NextStep::Send(bytes) => socket.write_all(&bytes).await?,
            NextStep::Recv(mut recv) => {
                let count = socket.read(recv.buf()).await?;
                anyhow::ensure!(count > 0, "SOCKS client closed");
                recv.note_received(count)?;
            }
            NextStep::Finished(done) => return Ok(done.into_output()?),
        }
    }
}

async fn proxy(mut socket: TcpStream, client: Arc<TorClient<PreferredRuntime>>) -> anyhow::Result<()> {
    let req = tokio::time::timeout(std::time::Duration::from_secs(30), request(&mut socket)).await??;
    let host = req.addr().to_string().to_lowercase();
    // Arti also rejects local destination addresses by default. I2P is never
    // handed to Tor, and only CONNECT is supported (no resolver command).
    if req.command() != SocksCmd::CONNECT || req.port() == 0 || host.trim_end_matches('.').ends_with(".i2p") {
        socket.write_all(&req.reply(SocksStatus::COMMAND_NOT_SUPPORTED, None)?).await?;
        return Ok(());
    }
    let remote = tokio::time::timeout(std::time::Duration::from_secs(120), client.connect((host.as_str(), req.port()))).await;
    match remote {
        Ok(Ok(stream)) => {
            socket.write_all(&req.reply(SocksStatus::SUCCEEDED, None)?).await?;
            let mut remote = stream.compat();
            tokio::io::copy_bidirectional(&mut socket, &mut remote).await?;
        }
        _ => socket.write_all(&req.reply(SocksStatus::GENERAL_FAILURE, None)?).await?,
    }
    Ok(())
}
