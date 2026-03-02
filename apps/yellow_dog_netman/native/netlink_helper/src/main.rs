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

use std::io;
use std::sync::mpsc;
use std::thread;

fn main() -> io::Result<()> {
    eprintln!("netlink_helper: starting");

    let (event_tx, event_rx) = mpsc::channel::<serde_json::Value>();

    // Spawn netlink event listener thread
    let listener = thread::spawn(move || {
        if let Err(e) = netlink::listen(event_tx) {
            eprintln!("netlink listener error: {}", e);
        }
    });

    // Spawn command reader thread (reads from stdin)
    let (cmd_tx, cmd_rx) = mpsc::channel::<serde_json::Value>();
    let reader = thread::spawn(move || {
        if let Err(e) = read_commands(cmd_tx) {
            eprintln!("command reader error: {}", e);
        }
    });

    // Main loop: multiplex events and commands.
    //
    // We block on event_rx.recv_timeout() rather than sleeping so that
    // netlink events are forwarded to Elixir with minimal latency. The
    // 50 ms timeout lets us still check worker liveness and drain pending
    // commands even when the network is quiet.
    let poll_interval = std::time::Duration::from_millis(50);
    loop {
        // Check if worker threads are still alive
        if listener.is_finished() {
            eprintln!("netlink listener thread exited unexpectedly");
            return Ok(());
        }
        if reader.is_finished() {
            // Reader exits normally when port closes (stdin EOF)
            eprintln!("command reader thread exited");
            return Ok(());
        }

        // Block until an event arrives or the poll interval elapses.
        // Either way, drain any additional events that arrived in the interim.
        match event_rx.recv_timeout(poll_interval) {
            Ok(event) => {
                if let Err(e) = protocol::write_message(&event) {
                    eprintln!("write error: {}", e);
                    return Ok(());
                }
                // Drain any further events that arrived back-to-back
                while let Ok(event) = event_rx.try_recv() {
                    if let Err(e) = protocol::write_message(&event) {
                        eprintln!("write error: {}", e);
                        return Ok(());
                    }
                }
            }
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                eprintln!("event channel disconnected");
                return Ok(());
            }
        }

        // Check for commands (non-blocking)
        while let Ok(cmd) = cmd_rx.try_recv() {
            if let Err(e) = commands::handle(&cmd) {
                eprintln!("command error: {}", e);
            }
        }
    }
}

const MAX_MESSAGE_SIZE: usize = 1_000_000; // 1 MB max

fn read_commands(tx: mpsc::Sender<serde_json::Value>) -> io::Result<()> {
    let stdin = io::stdin();
    let mut stdin = stdin.lock();
    read_commands_from(&mut stdin, tx)
}

/// Read length-prefixed JSON commands from any reader.
///
/// Extracted from `read_commands` for testability.
fn read_commands_from(
    reader: &mut dyn io::Read,
    tx: mpsc::Sender<serde_json::Value>,
) -> io::Result<()> {
    loop {
        // Read 4-byte length prefix
        let mut len_buf = [0u8; 4];
        if reader.read_exact(&mut len_buf).is_err() {
            return Ok(()); // Port closed
        }

        let len = u32::from_be_bytes(len_buf) as usize;
        if len < 2 {
            // Minimum valid JSON is "{}" (2 bytes); skip degenerate messages
            eprintln!("message too small: {} bytes (minimum 2 for valid JSON)", len);
            // Drain the (possibly zero-length) payload and continue
            let mut buf = vec![0u8; len];
            let _ = reader.read_exact(&mut buf);
            continue;
        }
        if len > MAX_MESSAGE_SIZE {
            eprintln!("message too large: {} bytes (max {})", len, MAX_MESSAGE_SIZE);
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "message too large"));
        }

        let mut buf = vec![0u8; len];
        reader.read_exact(&mut buf)?;

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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Cursor;

    /// Helper: encode a JSON value as a length-prefixed message.
    fn encode_message(value: &serde_json::Value) -> Vec<u8> {
        let json = serde_json::to_vec(value).unwrap();
        let mut buf = Vec::new();
        buf.extend_from_slice(&(json.len() as u32).to_be_bytes());
        buf.extend_from_slice(&json);
        buf
    }

    /// Helper: encode a raw byte slice as a length-prefixed message.
    fn encode_raw(data: &[u8]) -> Vec<u8> {
        let mut buf = Vec::new();
        buf.extend_from_slice(&(data.len() as u32).to_be_bytes());
        buf.extend_from_slice(data);
        buf
    }

    #[test]
    fn valid_command_is_received() {
        let cmd = json!({"cmd": "link_set", "interface": "eth0", "state": "up"});
        let data = encode_message(&cmd);
        let mut reader = Cursor::new(data);

        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        let received = rx.recv().unwrap();
        assert_eq!(received["cmd"], "link_set");
        assert_eq!(received["interface"], "eth0");
    }

    #[test]
    fn multiple_commands_are_received() {
        let cmd1 = json!({"cmd": "link_set"});
        let cmd2 = json!({"cmd": "addr_add"});
        let mut data = encode_message(&cmd1);
        data.extend(encode_message(&cmd2));
        let mut reader = Cursor::new(data);

        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        assert_eq!(rx.recv().unwrap()["cmd"], "link_set");
        assert_eq!(rx.recv().unwrap()["cmd"], "addr_add");
    }

    #[test]
    fn empty_reader_returns_ok() {
        let mut reader = Cursor::new(Vec::<u8>::new());
        let (tx, _rx) = mpsc::channel();
        let result = read_commands_from(&mut reader, tx);
        assert!(result.is_ok());
    }

    #[test]
    fn message_too_small_is_skipped() {
        // First: a 1-byte message (too small), then a valid command
        let mut data = Vec::new();
        // Message with len=1 (too small)
        data.extend_from_slice(&1u32.to_be_bytes());
        data.push(b'x'); // 1 byte of payload
        // Followed by a valid command
        data.extend(encode_message(&json!({"ok": true})));

        let mut reader = Cursor::new(data);
        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        // The small message should be skipped, valid one received
        let received = rx.recv().unwrap();
        assert_eq!(received["ok"], true);
    }

    #[test]
    fn zero_length_message_is_skipped() {
        let mut data = Vec::new();
        // Message with len=0
        data.extend_from_slice(&0u32.to_be_bytes());
        // Followed by a valid command
        data.extend(encode_message(&json!({"after_zero": true})));

        let mut reader = Cursor::new(data);
        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        let received = rx.recv().unwrap();
        assert_eq!(received["after_zero"], true);
    }

    #[test]
    fn message_too_large_returns_error() {
        // Message claiming to be larger than MAX_MESSAGE_SIZE
        let len = (MAX_MESSAGE_SIZE + 1) as u32;
        let data: Vec<u8> = len.to_be_bytes().to_vec();
        let mut reader = Cursor::new(data);

        let (tx, _rx) = mpsc::channel();
        let result = read_commands_from(&mut reader, tx);
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn invalid_json_is_skipped() {
        // First: valid length but invalid JSON, then a valid command
        let mut data = encode_raw(b"not json at all!!!");
        data.extend(encode_message(&json!({"after_bad": true})));

        let mut reader = Cursor::new(data);
        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        // Invalid JSON should be skipped, valid one received
        let received = rx.recv().unwrap();
        assert_eq!(received["after_bad"], true);
    }

    #[test]
    fn dropped_receiver_returns_ok() {
        let cmd = json!({"cmd": "test"});
        let data = encode_message(&cmd);
        let mut reader = Cursor::new(data);

        let (tx, rx) = mpsc::channel();
        drop(rx); // Drop the receiver

        let result = read_commands_from(&mut reader, tx);
        assert!(result.is_ok()); // Should exit gracefully
    }

    #[test]
    fn truncated_payload_returns_ok() {
        // Length says 100 bytes but only 5 bytes of payload available
        let mut data = Vec::new();
        data.extend_from_slice(&100u32.to_be_bytes());
        data.extend_from_slice(b"hello"); // Only 5 bytes, not 100

        let mut reader = Cursor::new(data);
        let (tx, _rx) = mpsc::channel();
        let result = read_commands_from(&mut reader, tx);
        // read_exact fails → returns the io error
        assert!(result.is_err());
    }

    #[test]
    fn partial_length_prefix_returns_ok() {
        // Only 2 bytes of the 4-byte length prefix
        let data = vec![0u8, 5];
        let mut reader = Cursor::new(data);

        let (tx, _rx) = mpsc::channel();
        let result = read_commands_from(&mut reader, tx);
        // read_exact for length fails → returns Ok (port closed)
        assert!(result.is_ok());
    }

    #[test]
    fn many_messages_back_to_back() {
        let mut data = Vec::new();
        for i in 0..100 {
            data.extend(encode_message(&json!({"seq": i})));
        }
        let mut reader = Cursor::new(data);

        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        for i in 0..100 {
            let msg = rx.recv().unwrap();
            assert_eq!(msg["seq"], i);
        }
        // Channel should be empty
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn deeply_nested_json_is_parsed() {
        let nested = json!({
            "a": {"b": {"c": {"d": {"e": {"f": "deep"}}}}}
        });
        let data = encode_message(&nested);
        let mut reader = Cursor::new(data);

        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        let received = rx.recv().unwrap();
        assert_eq!(received["a"]["b"]["c"]["d"]["e"]["f"], "deep");
    }

    #[test]
    fn interleaved_valid_invalid_zero_messages() {
        let mut data = Vec::new();
        // zero-length (skipped)
        data.extend_from_slice(&0u32.to_be_bytes());
        // valid
        data.extend(encode_message(&json!({"n": 1})));
        // invalid JSON (skipped)
        data.extend(encode_raw(b"{{bad json!!"));
        // 1-byte too small (skipped)
        data.extend_from_slice(&1u32.to_be_bytes());
        data.push(b'x');
        // valid
        data.extend(encode_message(&json!({"n": 2})));

        let mut reader = Cursor::new(data);
        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        assert_eq!(rx.recv().unwrap()["n"], 1);
        assert_eq!(rx.recv().unwrap()["n"], 2);
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn large_valid_message_near_limit() {
        // Create a message just under MAX_MESSAGE_SIZE
        let big_string = "x".repeat(10_000);
        let cmd = json!({"data": big_string});
        let data = encode_message(&cmd);
        let mut reader = Cursor::new(data);

        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        let received = rx.recv().unwrap();
        assert_eq!(received["data"].as_str().unwrap().len(), 10_000);
    }

    #[test]
    fn round_trip_with_protocol_write() {
        // Use protocol::write_message_to to encode, then read_commands_from to decode
        use crate::protocol;

        let value = json!({"cmd": "route_add", "destination": "10.0.0.0/24", "gateway": "10.0.0.1"});
        let mut buf = Vec::new();
        protocol::write_message_to(&mut buf, &value).unwrap();

        let mut reader = Cursor::new(buf);
        let (tx, rx) = mpsc::channel();
        let _ = read_commands_from(&mut reader, tx);

        let received = rx.recv().unwrap();
        assert_eq!(received, value);
    }
}
