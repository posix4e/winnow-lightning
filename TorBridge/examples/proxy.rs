//! Manual proof harness: reports a loopback port only after Tor bootstraps.
fn main() {
    let path = std::env::args().nth(1).expect("provide an absolute private state directory");
    let path = std::ffi::CString::new(path).unwrap();
    assert_eq!(unsafe { winnow_tor::winnow_tor_start(path.as_ptr()) }, 0);
    loop {
        match winnow_tor::winnow_tor_state() {
            2 => { println!("SOCKS 127.0.0.1:{}", winnow_tor::winnow_tor_port()); break; }
            3 => { eprintln!("Tor bootstrap failed"); std::process::exit(1); }
            _ => std::thread::sleep(std::time::Duration::from_secs(1)),
        }
    }
    // EOF stops; keeps proof runs bounded and owned by their invoking process.
    let mut line = String::new();
    let _ = std::io::stdin().read_line(&mut line);
    winnow_tor::winnow_tor_stop();
}
