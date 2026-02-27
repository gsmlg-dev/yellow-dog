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

fn handle_link_set(cmd: &Value) -> io::Result<()> {
    let iface = cmd["interface"].as_str().unwrap_or("");
    let mut args = vec!["link", "set", iface];

    if let Some(state) = cmd["state"].as_str() {
        args.push(state);
    }
    if let Some(mtu) = cmd["mtu"].as_u64() {
        args.push("mtu");
        let mtu_str = mtu.to_string();
        // Use ip command
        let _ = Command::new("ip")
            .args(&["link", "set", iface, "mtu", &mtu_str])
            .output();
        return Ok(());
    }

    let _ = Command::new("ip").args(&args).output();
    Ok(())
}

fn handle_addr_add(cmd: &Value) -> io::Result<()> {
    let iface = cmd["interface"].as_str().unwrap_or("");
    let addr = cmd["address"].as_str().unwrap_or("");

    let _ = Command::new("ip")
        .args(&["addr", "add", addr, "dev", iface])
        .output();
    Ok(())
}

fn handle_addr_del(cmd: &Value) -> io::Result<()> {
    let iface = cmd["interface"].as_str().unwrap_or("");
    let addr = cmd["address"].as_str().unwrap_or("");

    let _ = Command::new("ip")
        .args(&["addr", "del", addr, "dev", iface])
        .output();
    Ok(())
}

fn handle_route_add(cmd: &Value) -> io::Result<()> {
    let dest = cmd["destination"].as_str().unwrap_or("default");
    let mut args = vec!["route", "add", dest];

    if let Some(gw) = cmd["gateway"].as_str() {
        args.push("via");
        args.push(gw);
    }
    if let Some(iface) = cmd["interface"].as_str() {
        args.push("dev");
        args.push(iface);
    }
    if let Some(metric) = cmd["metric"].as_u64() {
        args.push("metric");
        let metric_str = metric.to_string();
        let mut full_args = args.clone();
        full_args.push(&metric_str);
        let _ = Command::new("ip").args(&full_args).output();
        return Ok(());
    }

    let _ = Command::new("ip").args(&args).output();
    Ok(())
}

fn handle_route_del(cmd: &Value) -> io::Result<()> {
    let dest = cmd["destination"].as_str().unwrap_or("default");
    let mut args = vec!["route", "del", dest];

    if let Some(gw) = cmd["gateway"].as_str() {
        args.push("via");
        args.push(gw);
    }
    if let Some(iface) = cmd["interface"].as_str() {
        args.push("dev");
        args.push(iface);
    }

    let _ = Command::new("ip").args(&args).output();
    Ok(())
}
