//! RTM_* command execution via netlink.

use serde_json::Value;
use std::io;
use std::process::Command;

/// Handle a command from the Elixir side.
///
/// In Phase 1, we delegate to `ip` commands for simplicity.
/// In future phases, this will use netlink directly.
pub fn handle(cmd: &Value) -> io::Result<()> {
    let cmd_type = cmd["cmd"].as_str().unwrap_or("");

    match cmd_type {
        "link_set" => handle_link_set(cmd),
        "addr_add" => handle_addr_add(cmd),
        "addr_del" => handle_addr_del(cmd),
        "route_add" => handle_route_add(cmd),
        "route_del" => handle_route_del(cmd),
        _ => {
            eprintln!("unknown command: {}", cmd_type);
            Ok(())
        }
    }
}

/// Validate that an interface name contains only safe characters.
fn validate_interface(name: &str) -> io::Result<&str> {
    if name.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "empty interface name",
        ));
    }
    if name.len() > 15 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "interface name too long",
        ));
    }
    if name
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'.')
    {
        Ok(name)
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid interface name: {}", name),
        ))
    }
}

/// Validate an IP address or CIDR notation (e.g., "10.0.0.1", "10.0.0.1/24", "fe80::1/64").
/// Prevents flag injection by ensuring the value doesn't start with '-'.
fn validate_address(addr: &str) -> io::Result<&str> {
    if addr.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "empty address",
        ));
    }
    if addr.starts_with('-') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "address must not start with '-'",
        ));
    }
    // Only allow characters valid in IPv4/IPv6 addresses with optional CIDR prefix
    if addr
        .bytes()
        .all(|b| b.is_ascii_hexdigit() || matches!(b, b'.' | b':' | b'/'))
    {
        Ok(addr)
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("invalid address: {}", addr),
        ))
    }
}

/// Validate a route destination (IP/CIDR or "default").
fn validate_destination(dest: &str) -> io::Result<&str> {
    if dest == "default" {
        return Ok(dest);
    }
    validate_address(dest)
}

/// Run an ip command and report failures via stderr.
fn run_ip(args: &[&str]) -> io::Result<()> {
    match Command::new("ip").args(args).output() {
        Ok(output) => {
            if output.status.success() {
                Ok(())
            } else {
                let stderr = String::from_utf8_lossy(&output.stderr);
                let msg = format!(
                    "ip {} failed ({}): {}",
                    args.join(" "),
                    output.status,
                    stderr.trim()
                );
                eprintln!("{}", msg);
                Err(io::Error::new(io::ErrorKind::Other, msg))
            }
        }
        Err(e) => {
            eprintln!("failed to execute ip command: {}", e);
            Err(e)
        }
    }
}

fn handle_link_set(cmd: &Value) -> io::Result<()> {
    let iface = validate_interface(cmd["interface"].as_str().unwrap_or(""))?;

    if let Some(mtu) = cmd["mtu"].as_u64() {
        let mtu_str = mtu.to_string();
        run_ip(&["link", "set", iface, "mtu", &mtu_str])?;
    }

    if let Some(state) = cmd["state"].as_str() {
        match state {
            "up" | "down" => run_ip(&["link", "set", iface, state])?,
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("invalid link state: {}", state),
                ));
            }
        }
    }

    Ok(())
}

fn handle_addr_add(cmd: &Value) -> io::Result<()> {
    let iface = validate_interface(cmd["interface"].as_str().unwrap_or(""))?;
    let addr = validate_address(cmd["address"].as_str().unwrap_or(""))?;
    run_ip(&["addr", "add", addr, "dev", iface])
}

fn handle_addr_del(cmd: &Value) -> io::Result<()> {
    let iface = validate_interface(cmd["interface"].as_str().unwrap_or(""))?;
    let addr = validate_address(cmd["address"].as_str().unwrap_or(""))?;
    run_ip(&["addr", "del", addr, "dev", iface])
}

fn handle_route_add(cmd: &Value) -> io::Result<()> {
    let dest = validate_destination(cmd["destination"].as_str().unwrap_or("default"))?;
    let mut args = vec!["route", "add", dest];

    if let Some(gw) = cmd["gateway"].as_str() {
        let gw = validate_address(gw)?;
        args.push("via");
        args.push(gw);
    }
    if let Some(iface) = cmd["interface"].as_str() {
        let iface = validate_interface(iface)?;
        args.push("dev");
        args.push(iface);
    }

    // Hoist metric_str so its lifetime covers the run_ip call
    let metric_str = cmd["metric"].as_u64().map(|m| m.to_string());
    if let Some(ref s) = metric_str {
        args.push("metric");
        args.push(s);
    }

    run_ip(&args)
}

fn handle_route_del(cmd: &Value) -> io::Result<()> {
    let dest = validate_destination(cmd["destination"].as_str().unwrap_or("default"))?;
    let mut args = vec!["route", "del", dest];

    if let Some(gw) = cmd["gateway"].as_str() {
        let gw = validate_address(gw)?;
        args.push("via");
        args.push(gw);
    }
    if let Some(iface) = cmd["interface"].as_str() {
        let iface = validate_interface(iface)?;
        args.push("dev");
        args.push(iface);
    }

    run_ip(&args)
}
