//! Length-prefixed JSON protocol for Elixir port communication.

use std::io::{self, Write};

/// Write a JSON message with 4-byte length prefix to stdout.
pub fn write_message(value: &serde_json::Value) -> io::Result<()> {
    let json = serde_json::to_vec(value)?;
    let len = (json.len() as u32).to_be_bytes();

    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    stdout.write_all(&len)?;
    stdout.write_all(&json)?;
    stdout.flush()?;

    Ok(())
}
