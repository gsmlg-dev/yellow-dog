//! RTM_* command execution via netlink.

use serde_json::Value;
use std::io;
use std::process::Command;

// Linux IFNAMSIZ limit (excluding null terminator)
const MAX_INTERFACE_NAME_LEN: usize = 15;

// Valid MTU range per RFC 791 (IPv4 minimum) and Linux maximum
const MIN_MTU: u64 = 68;
const MAX_MTU: u64 = 65535;

// Linux route metrics are u32
const MAX_ROUTE_METRIC: u64 = u32::MAX as u64;

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
    if name.len() > MAX_INTERFACE_NAME_LEN {
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
    if addr.starts_with('-') || addr.contains('\0') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "address contains invalid characters",
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
                Err(io::Error::other(msg))
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
        if !(MIN_MTU..=MAX_MTU).contains(&mtu) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("MTU out of valid range ({}-{}): {}", MIN_MTU, MAX_MTU, mtu),
            ));
        }
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
    let metric_str = if let Some(m) = cmd["metric"].as_u64() {
        if m > MAX_ROUTE_METRIC {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("route metric exceeds maximum ({}): {}", MAX_ROUTE_METRIC, m),
            ));
        }
        Some(m.to_string())
    } else {
        None
    };
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

#[cfg(test)]
mod tests {
    use super::*;

    // --- validate_interface ---

    #[test]
    fn interface_empty_is_rejected() {
        assert!(validate_interface("").is_err());
    }

    #[test]
    fn interface_too_long_is_rejected() {
        let long = "a".repeat(16);
        assert!(validate_interface(&long).is_err());
    }

    #[test]
    fn interface_exactly_15_chars_is_accepted() {
        let name = "a".repeat(15);
        assert!(validate_interface(&name).is_ok());
    }

    #[test]
    fn interface_alphanumeric_underscore_hyphen_dot_accepted() {
        assert!(validate_interface("eth0").is_ok());
        assert!(validate_interface("eth0.100").is_ok());
        assert!(validate_interface("br-lan").is_ok());
        assert!(validate_interface("veth_abc").is_ok());
    }

    #[test]
    fn interface_with_space_is_rejected() {
        assert!(validate_interface("eth 0").is_err());
    }

    #[test]
    fn interface_with_slash_is_rejected() {
        assert!(validate_interface("../../etc").is_err());
    }

    #[test]
    fn interface_with_null_byte_is_rejected() {
        assert!(validate_interface("eth\x000").is_err());
    }

    #[test]
    fn interface_with_semicolon_is_rejected() {
        assert!(validate_interface("eth0;rm").is_err());
    }

    // --- validate_address ---

    #[test]
    fn address_empty_is_rejected() {
        assert!(validate_address("").is_err());
    }

    #[test]
    fn address_starting_with_dash_is_rejected() {
        assert!(validate_address("-n").is_err());
    }

    #[test]
    fn ipv4_address_accepted() {
        assert!(validate_address("192.168.1.1").is_ok());
    }

    #[test]
    fn ipv4_cidr_accepted() {
        assert!(validate_address("10.0.0.0/24").is_ok());
    }

    #[test]
    fn ipv6_address_accepted() {
        assert!(validate_address("fe80::1").is_ok());
    }

    #[test]
    fn ipv6_cidr_accepted() {
        assert!(validate_address("2001:db8::/32").is_ok());
    }

    #[test]
    fn address_with_shell_metachar_is_rejected() {
        assert!(validate_address("10.0.0.1;whoami").is_err());
    }

    #[test]
    fn address_with_space_is_rejected() {
        assert!(validate_address("10.0.0.1 ").is_err());
    }

    #[test]
    fn address_with_null_byte_is_rejected() {
        assert!(validate_address("10.0.0\x001").is_err());
    }

    // --- validate_destination ---

    #[test]
    fn destination_default_is_accepted() {
        assert!(validate_destination("default").is_ok());
    }

    #[test]
    fn destination_ip_cidr_is_accepted() {
        assert!(validate_destination("0.0.0.0/0").is_ok());
    }

    #[test]
    fn destination_invalid_is_rejected() {
        assert!(validate_destination("$(evil)").is_err());
    }

    // --- handle command dispatch ---

    #[test]
    fn unknown_command_returns_ok() {
        let cmd = serde_json::json!({"cmd": "unknown_cmd_xyz"});
        // Unknown commands log to stderr and return Ok — no panic
        assert!(handle(&cmd).is_ok());
    }

    #[test]
    fn link_set_with_empty_interface_returns_err() {
        let cmd = serde_json::json!({"cmd": "link_set", "interface": "", "state": "up"});
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn addr_add_with_invalid_interface_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "addr_add",
            "interface": "../../etc",
            "address": "10.0.0.1/24"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn addr_add_with_invalid_address_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "addr_add",
            "interface": "eth0",
            "address": "-n 10.0.0.1"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn link_set_with_invalid_state_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0",
            "state": "destroy"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn route_add_with_invalid_gateway_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "route_add",
            "destination": "default",
            "gateway": "-flag_inject"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn route_del_with_invalid_destination_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "route_del",
            "destination": "$(rm -rf /)"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn addr_del_with_empty_address_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "addr_del",
            "interface": "eth0",
            "address": ""
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn missing_cmd_field_returns_ok() {
        // No "cmd" field → empty string → unknown command → Ok
        let cmd = serde_json::json!({"interface": "eth0"});
        assert!(handle(&cmd).is_ok());
    }

    #[test]
    fn mtu_below_minimum_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0",
            "mtu": 67
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn mtu_above_maximum_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0",
            "mtu": 65536
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn mtu_at_minimum_boundary_is_valid() {
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0",
            "mtu": 68
        });
        // This will fail due to ip command not finding eth0, but the
        // MTU validation itself should pass. We test it doesn't return
        // an InvalidInput error about MTU range.
        let result = handle(&cmd);
        if let Err(ref e) = result {
            assert!(!e.to_string().contains("MTU out of valid range"));
        }
    }

    #[test]
    fn mtu_at_maximum_boundary_is_valid() {
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0",
            "mtu": 65535
        });
        let result = handle(&cmd);
        if let Err(ref e) = result {
            assert!(!e.to_string().contains("MTU out of valid range"));
        }
    }

    // --- route_add with optional params ---

    #[test]
    fn route_add_with_invalid_interface_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "route_add",
            "destination": "10.0.0.0/24",
            "interface": "eth0;whoami"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn route_del_with_invalid_interface_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "route_del",
            "destination": "10.0.0.0/24",
            "interface": "../etc"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn route_del_with_invalid_gateway_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "route_del",
            "destination": "default",
            "gateway": "-flag"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn addr_del_with_invalid_interface_returns_err() {
        let cmd = serde_json::json!({
            "cmd": "addr_del",
            "interface": "eth0 && rm -rf",
            "address": "10.0.0.1/24"
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn link_set_with_no_mtu_or_state_returns_ok() {
        // link_set with only interface, no mtu or state — valid no-op
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0"
        });
        assert!(handle(&cmd).is_ok());
    }

    #[test]
    fn address_with_only_colons_is_valid() {
        // IPv6 shorthand like "::" should be valid
        assert!(validate_address("::").is_ok());
        assert!(validate_address("::1").is_ok());
    }

    // --- constant boundary tests ---

    #[test]
    fn interface_at_max_length_is_accepted() {
        let name = "a".repeat(MAX_INTERFACE_NAME_LEN);
        assert!(validate_interface(&name).is_ok());
    }

    #[test]
    fn interface_over_max_length_is_rejected() {
        let name = "a".repeat(MAX_INTERFACE_NAME_LEN + 1);
        assert!(validate_interface(&name).is_err());
    }

    #[test]
    fn mtu_at_min_constant_is_valid_input() {
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0",
            "mtu": MIN_MTU
        });
        let result = handle(&cmd);
        if let Err(ref e) = result {
            assert!(!e.to_string().contains("MTU out of valid range"));
        }
    }

    #[test]
    fn mtu_below_min_constant_is_rejected() {
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0",
            "mtu": MIN_MTU - 1
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn mtu_above_max_constant_is_rejected() {
        let cmd = serde_json::json!({
            "cmd": "link_set",
            "interface": "eth0",
            "mtu": MAX_MTU + 1
        });
        assert!(handle(&cmd).is_err());
    }

    // --- route metric validation ---

    #[test]
    fn route_metric_at_u32_max_is_valid_input() {
        let cmd = serde_json::json!({
            "cmd": "route_add",
            "destination": "10.0.0.0/24",
            "interface": "eth0",
            "metric": MAX_ROUTE_METRIC
        });
        let result = handle(&cmd);
        if let Err(ref e) = result {
            assert!(!e.to_string().contains("route metric exceeds maximum"));
        }
    }

    #[test]
    fn route_metric_above_u32_max_is_rejected() {
        let cmd = serde_json::json!({
            "cmd": "route_add",
            "destination": "10.0.0.0/24",
            "interface": "eth0",
            "metric": MAX_ROUTE_METRIC + 1
        });
        assert!(handle(&cmd).is_err());
    }

    #[test]
    fn route_metric_zero_is_valid_input() {
        let cmd = serde_json::json!({
            "cmd": "route_add",
            "destination": "10.0.0.0/24",
            "interface": "eth0",
            "metric": 0
        });
        let result = handle(&cmd);
        if let Err(ref e) = result {
            assert!(!e.to_string().contains("route metric exceeds maximum"));
        }
    }
}
