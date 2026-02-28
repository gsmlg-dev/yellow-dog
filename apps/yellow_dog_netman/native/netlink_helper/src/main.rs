//! Netlink helper for YellowDog NetMan.
//!
//! Communicates with the Elixir port owner via length-prefixed JSON
//! over stdin/stdout.
//!
//! - Events → Elixir: kernel network state changes
//! - Commands ← Elixir: link/address/route operations

mod commands;
mod netlink;
mod protocol;

use std::io::{self, Read};
use std::sync::mpsc;
use std::thread;

fn main() -> io::Result<()> {
    eprintln!("netlink_helper: starting");

    let (event_tx, event_rx) = mpsc::channel::<serde_json::Value>();

    // Spawn netlink event listener thread
    let _listener = thread::spawn(move || {
        if let Err(e) = netlink::listen(event_tx) {
            eprintln!("netlink listener error: {}", e);
        }
    });

    // Spawn command reader thread (reads from stdin)
    let (cmd_tx, cmd_rx) = mpsc::channel::<serde_json::Value>();
    let _reader = thread::spawn(move || {
        if let Err(e) = read_commands(cmd_tx) {
            eprintln!("command reader error: {}", e);
        }
    });

    // Main loop: multiplex events and commands
    loop {
        // Check for events (non-blocking)
        while let Ok(event) = event_rx.try_recv() {
            if let Err(e) = protocol::write_message(&event) {
                eprintln!("write error: {}", e);
                return Ok(());
            }
        }

        // Check for commands (non-blocking)
        while let Ok(cmd) = cmd_rx.try_recv() {
            if let Err(e) = commands::handle(&cmd) {
                eprintln!("command error: {}", e);
            }
        }

        // Small sleep to avoid busy-waiting
        thread::sleep(std::time::Duration::from_millis(10));
    }
}

const MAX_MESSAGE_SIZE: usize = 1_000_000; // 1 MB max

fn read_commands(tx: mpsc::Sender<serde_json::Value>) -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdin = stdin.lock();

    loop {
        // Read 4-byte length prefix
        let mut len_buf = [0u8; 4];
        if stdin.read_exact(&mut len_buf).is_err() {
            return Ok(()); // Port closed
        }

        let len = u32::from_be_bytes(len_buf) as usize;
        if len > MAX_MESSAGE_SIZE {
            eprintln!("message too large: {} bytes (max {})", len, MAX_MESSAGE_SIZE);
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "message too large"));
        }

        let mut buf = vec![0u8; len];
        stdin.read_exact(&mut buf)?;

        match serde_json::from_slice::<serde_json::Value>(&buf) {
            Ok(cmd) => {
                if tx.send(cmd).is_err() {
                    return Ok(());
                }
            }
            Err(e) => {
                eprintln!("json parse error: {}", e);
            }
        }
    }
}
