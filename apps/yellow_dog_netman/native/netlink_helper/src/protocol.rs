//! Length-prefixed JSON protocol for Elixir port communication.

use std::io::{self, Write};

/// Write a JSON message with 4-byte big-endian length prefix to the given writer.
fn write_message_to(writer: &mut dyn Write, value: &serde_json::Value) -> io::Result<()> {
    let json = serde_json::to_vec(value)?;
    let len = (json.len() as u32).to_be_bytes();

    writer.write_all(&len)?;
    writer.write_all(&json)?;
    writer.flush()?;

    Ok(())
}

/// Write a JSON message with 4-byte length prefix to stdout.
pub fn write_message(value: &serde_json::Value) -> io::Result<()> {
    let stdout = io::stdout();
    let mut stdout = stdout.lock();
    write_message_to(&mut stdout, value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn write_message_produces_length_prefixed_json() {
        let value = json!({"type": "link", "interface": "eth0"});
        let mut buf = Vec::new();

        write_message_to(&mut buf, &value).unwrap();

        // First 4 bytes are the big-endian length prefix
        let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        assert_eq!(len, buf.len() - 4);

        // Remaining bytes are valid JSON
        let parsed: serde_json::Value = serde_json::from_slice(&buf[4..]).unwrap();
        assert_eq!(parsed["type"], "link");
        assert_eq!(parsed["interface"], "eth0");
    }

    #[test]
    fn write_message_empty_object() {
        let value = json!({});
        let mut buf = Vec::new();

        write_message_to(&mut buf, &value).unwrap();

        let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        assert_eq!(len, 2); // "{}" is 2 bytes
        assert_eq!(&buf[4..], b"{}");
    }

    #[test]
    fn write_message_nested_object() {
        let value = json!({"event": "addr_add", "attrs": {"address": "10.0.0.1", "prefix": 24}});
        let mut buf = Vec::new();

        write_message_to(&mut buf, &value).unwrap();

        let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        assert_eq!(len, buf.len() - 4);

        let parsed: serde_json::Value = serde_json::from_slice(&buf[4..]).unwrap();
        assert_eq!(parsed["event"], "addr_add");
        assert_eq!(parsed["attrs"]["prefix"], 24);
    }

    #[test]
    fn write_message_round_trips_with_read_protocol() {
        // Simulate what main.rs read_commands would do: read 4-byte len, then payload
        let value = json!({"cmd": "link_set", "interface": "eth0", "state": "up"});
        let mut buf = Vec::new();

        write_message_to(&mut buf, &value).unwrap();

        // Read the length prefix
        let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;

        // Read that many bytes of payload
        let payload = &buf[4..4 + len];
        let decoded: serde_json::Value = serde_json::from_slice(payload).unwrap();

        assert_eq!(decoded, value);
    }

    #[test]
    fn write_message_with_unicode() {
        let value = json!({"name": "eth\u{00fc}0"});
        let mut buf = Vec::new();

        write_message_to(&mut buf, &value).unwrap();

        let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
        let parsed: serde_json::Value = serde_json::from_slice(&buf[4..4 + len]).unwrap();
        assert_eq!(parsed["name"], "eth\u{00fc}0");
    }
}
