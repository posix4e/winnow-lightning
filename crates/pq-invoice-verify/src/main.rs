use pq_invoice_verify::verify;
use std::fs;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: pq-invoice-verify INVOICE_FILE TRUSTED_ML_DSA_KEY_HEX_FILE");
        return ExitCode::FAILURE;
    }
    let result = fs::read_to_string(&args[1])
        .map_err(|error| error.to_string())
        .and_then(|invoice| {
            fs::read_to_string(&args[2])
                .map_err(|error| error.to_string())
                .and_then(|key| verify(&invoice, &key))
        });
    match result {
        Ok(message) => { println!("{message}"); ExitCode::SUCCESS },
        Err(error) => { eprintln!("{error}"); ExitCode::FAILURE },
    }
}
