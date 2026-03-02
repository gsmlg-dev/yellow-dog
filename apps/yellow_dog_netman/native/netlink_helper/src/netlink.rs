//! Netlink socket management and multicast group subscription.

use std::sync::mpsc;

use netlink_packet_utils::traits::Parseable;
use netlink_packet_route::address::{
    AddressAttribute, AddressMessage, AddressMessageBuffer, AddressScope,
};
use netlink_packet_route::link::{LinkAttribute, LinkMessage, LinkMessageBuffer, State};
use netlink_packet_route::neighbour::{
    NeighbourAddress, NeighbourAttribute, NeighbourMessage, NeighbourMessageBuffer,
};
use netlink_packet_route::route::{
    RouteAddress, RouteAttribute, RouteMessage, RouteMessageBuffer, RouteProtocol, RouteScope,
};
use netlink_packet_route::rule::{RuleAction, RuleAttribute, RuleMessage, RuleMessageBuffer};
use netlink_packet_route::AddressFamily;
use netlink_sys::{protocols::NETLINK_ROUTE, Socket, SocketAddr};
use serde_json::{json, Value};

// Multicast groups
const RTNLGRP_LINK: u32 = 1;
const RTNLGRP_IPV4_IFADDR: u32 = 5;
const RTNLGRP_IPV4_ROUTE: u32 = 6;
const RTNLGRP_IPV6_IFADDR: u32 = 9;
const RTNLGRP_IPV6_ROUTE: u32 = 10;
const RTNLGRP_NEIGH: u32 = 13;
const RTNLGRP_IPV4_RULE: u32 = 14;
const RTNLGRP_IPV6_RULE: u32 = 19;

fn multicast_groups() -> u32 {
    (1 << (RTNLGRP_LINK - 1))
        | (1 << (RTNLGRP_IPV4_IFADDR - 1))
        | (1 << (RTNLGRP_IPV4_ROUTE - 1))
        | (1 << (RTNLGRP_IPV6_IFADDR - 1))
        | (1 << (RTNLGRP_IPV6_ROUTE - 1))
        | (1 << (RTNLGRP_NEIGH - 1))
        | (1 << (RTNLGRP_IPV4_RULE - 1))
        | (1 << (RTNLGRP_IPV6_RULE - 1))
}

/// Listen for netlink events and send them to the channel.
pub fn listen(tx: mpsc::Sender<Value>) -> Result<(), Box<dyn std::error::Error>> {
    let mut socket = Socket::new(NETLINK_ROUTE)?;
    let addr = SocketAddr::new(0, multicast_groups());
    socket.bind(&addr)?;

    let mut buf = vec![0u8; 65536];

    loop {
        let n = socket.recv(&mut buf, 0)?;
        if n == 0 {
            continue;
        }
        if n == buf.len() {
            eprintln!("warning: netlink recv filled buffer ({} bytes), message may be truncated", n);
        }

        // Parse netlink messages from the buffer
        let messages = parse_netlink_messages(&buf[..n]);
        for msg in messages {
            if tx.send(msg).is_err() {
                return Ok(());
            }
        }
    }
}

/// Parse raw netlink message buffer into JSON events.
///
/// Uses `netlink-packet-route` for RTM_NEWLINK/RTM_DELLINK and
/// RTM_NEWADDR/RTM_DELADDR to extract interface names, addresses, and
/// state fields expected by the Elixir kernel subsystem.
///
/// Events include:
/// - Link: `{"type": "link_change", "action": "add"|"del", "interface": "eth0",
///   "index": 2, "carrier": true, "mtu": 1500, "state": "up", "mac": "aa:bb:..."}`
/// - Address: `{"type": "address_change", "action": "add"|"del", "interface": "eth0",
///   "address": "10.0.0.1/24", "family": "inet", "scope": "global"}`
fn parse_netlink_messages(buf: &[u8]) -> Vec<Value> {
    let mut events = Vec::new();
    let mut offset = 0;

    while offset + 16 <= buf.len() {
        let len = u32::from_ne_bytes([buf[offset], buf[offset + 1], buf[offset + 2], buf[offset + 3]]) as usize;
        if len < 16 || offset + len > buf.len() {
            break;
        }

        let msg_type = u16::from_ne_bytes([buf[offset + 4], buf[offset + 5]]);
        // Netlink header is 16 bytes; payload follows
        let payload = &buf[offset + 16..offset + len];

        let event = match msg_type {
            // RTM_NEWLINK = 16, RTM_DELLINK = 17
            16 | 17 => parse_link_event(msg_type, payload),
            // RTM_NEWADDR = 20, RTM_DELADDR = 21
            20 | 21 => parse_address_event(msg_type, payload),
            // RTM_NEWROUTE = 24, RTM_DELROUTE = 25
            24 | 25 => parse_route_event(msg_type, payload),
            // RTM_NEWNEIGH = 28, RTM_DELNEIGH = 29
            28 | 29 => parse_neighbour_event(msg_type, payload),
            // RTM_NEWRULE = 32, RTM_DELRULE = 33
            32 | 33 => parse_rule_event(msg_type, payload),
            _ => None,
        };

        if let Some(e) = event {
            events.push(e);
        }

        // Align to 4 bytes
        offset += (len + 3) & !3;
    }

    events
}

/// Parse RTM_NEWLINK / RTM_DELLINK payload into a JSON event.
///
/// Extracts interface name, index, carrier, MTU, MAC address, and
/// operational state from the link message NLAs. If parsing fails
/// (e.g. empty payload in unit tests), returns a minimal event with
/// only `type` and `action`.
fn parse_link_event(msg_type: u16, payload: &[u8]) -> Option<Value> {
    let action = if msg_type == 16 { "add" } else { "del" };

    let mut event = json!({
        "type": "link_change",
        "action": action,
        "raw_type": msg_type
    });

    // LinkMessageBuffer requires &T where T: Sized — use Vec<u8> to satisfy this
    let payload_owned = payload.to_vec();
    if let Ok(buf) = LinkMessageBuffer::new_checked(&payload_owned) {
        if let Ok(msg) = LinkMessage::parse(&buf) {
            event["index"] = json!(msg.header.index);

            for attr in &msg.attributes {
                match attr {
                    LinkAttribute::IfName(name) => {
                        event["interface"] = json!(name);
                    }
                    LinkAttribute::Mtu(mtu) => {
                        event["mtu"] = json!(mtu);
                    }
                    LinkAttribute::Carrier(carrier) => {
                        event["carrier"] = json!(*carrier != 0);
                    }
                    LinkAttribute::OperState(state) => {
                        event["state"] = json!(format_link_state(state));
                    }
                    LinkAttribute::Address(mac) if mac.len() == 6 => {
                        event["mac"] = json!(format!(
                            "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
                            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]
                        ));
                    }
                    _ => {}
                }
            }
        }
    }

    Some(event)
}

/// Parse RTM_NEWADDR / RTM_DELADDR payload into a JSON event.
///
/// Extracts interface name (from Label NLA), IP address with prefix
/// length, address family (inet/inet6), and scope. If parsing fails,
/// returns a minimal event with only `type` and `action`.
fn parse_address_event(msg_type: u16, payload: &[u8]) -> Option<Value> {
    let action = if msg_type == 20 { "add" } else { "del" };

    let mut event = json!({
        "type": "address_change",
        "action": action,
        "raw_type": msg_type
    });

    // AddressMessageBuffer requires &T where T: Sized — use Vec<u8> to satisfy this
    let payload_owned = payload.to_vec();
    if let Ok(buf) = AddressMessageBuffer::new_checked(&payload_owned) {
        if let Ok(msg) = AddressMessage::parse(&buf) {
            let prefix_len = msg.header.prefix_len;

            event["family"] = json!(format_address_family(&msg.header.family));
            event["prefix_len"] = json!(prefix_len);
            event["scope"] = json!(format_address_scope(&msg.header.scope));

            for attr in &msg.attributes {
                match attr {
                    AddressAttribute::Address(ip) => {
                        event["address"] = json!(format!("{}/{}", ip, prefix_len));
                    }
                    AddressAttribute::Label(label) => {
                        event["interface"] = json!(label);
                    }
                    _ => {}
                }
            }
        }
    }

    Some(event)
}

fn format_link_state(state: &State) -> &'static str {
    match state {
        State::Up => "up",
        State::Down => "down",
        State::Dormant => "dormant",
        State::LowerLayerDown => "lowerlayerdown",
        State::Testing => "testing",
        State::NotPresent => "notpresent",
        State::Unknown | _ => "unknown",
    }
}

fn format_address_family(family: &AddressFamily) -> &'static str {
    match family {
        AddressFamily::Inet => "inet",
        AddressFamily::Inet6 => "inet6",
        _ => "unknown",
    }
}

/// Parse RTM_NEWROUTE / RTM_DELROUTE payload into a JSON event.
///
/// Extracts destination (as IP/prefix or "default"), gateway, interface name
/// (resolved from Oif index via libc::if_indextoname), metric, table, scope,
/// and protocol from the route message. If parsing fails, returns a minimal
/// event with only `type` and `action`.
fn parse_route_event(msg_type: u16, payload: &[u8]) -> Option<Value> {
    let action = if msg_type == 24 { "add" } else { "del" };

    let mut event = json!({
        "type": "route_change",
        "action": action,
        "raw_type": msg_type
    });

    let payload_owned = payload.to_vec();
    if let Ok(buf) = RouteMessageBuffer::new_checked(&payload_owned) {
        if let Ok(msg) = RouteMessage::parse(&buf) {
            let prefix_len = msg.header.destination_prefix_length;
            event["table"] = json!(msg.header.table as u32);
            event["scope"] = json!(format_route_scope(&msg.header.scope));
            event["protocol"] = json!(format_route_protocol(&msg.header.protocol));

            let mut destination: Option<String> = None;
            let mut gateway: Option<String> = None;

            for attr in &msg.attributes {
                match attr {
                    RouteAttribute::Destination(addr) => {
                        destination = Some(format!("{}/{}", format_route_address(addr), prefix_len));
                    }
                    RouteAttribute::Gateway(addr) => {
                        gateway = Some(format_route_address(addr));
                    }
                    RouteAttribute::Oif(idx) => {
                        if let Some(name) = ifindex_to_name(*idx) {
                            event["interface"] = json!(name);
                        }
                    }
                    RouteAttribute::Priority(metric) => {
                        event["metric"] = json!(metric);
                    }
                    RouteAttribute::Table(t) => {
                        // Extended table attribute overrides the header's u8 table field
                        event["table"] = json!(t);
                    }
                    _ => {}
                }
            }

            // Emit "default" when prefix_len == 0 and no Destination attribute
            event["destination"] = match destination {
                Some(dest) => json!(dest),
                None => json!("default"),
            };

            if let Some(gw) = gateway {
                event["gateway"] = json!(gw);
            }
        }
    }

    Some(event)
}

/// Parse RTM_NEWRULE / RTM_DELRULE payload into a JSON event.
///
/// Extracts priority, routing table, source prefix, destination prefix,
/// incoming interface name, and action from the rule message.
fn parse_rule_event(msg_type: u16, payload: &[u8]) -> Option<Value> {
    let action = if msg_type == 32 { "add" } else { "del" };

    let mut event = json!({
        "type": "rule_change",
        "action": action,
        "raw_type": msg_type,
        "table": 254  // RT_TABLE_MAIN default
    });

    let payload_owned = payload.to_vec();
    if let Ok(buf) = RuleMessageBuffer::new_checked(&payload_owned) {
        if let Ok(msg) = RuleMessage::parse(&buf) {
            // Header table field (u8 — for table IDs ≤ 255)
            event["table"] = json!(msg.header.table as u32);

            // Emit the rule action as a string
            event["rule_action"] = json!(format_rule_action(&msg.header.action));

            let dst_len = msg.header.dst_len;
            let src_len = msg.header.src_len;

            for attr in &msg.attributes {
                match attr {
                    RuleAttribute::Priority(p) => {
                        event["priority"] = json!(p);
                    }
                    RuleAttribute::Table(t) => {
                        // Extended table attribute overrides the header's u8 table field
                        event["table"] = json!(t);
                    }
                    RuleAttribute::Source(addr) => {
                        event["source"] = json!(format!("{}/{}", format_rule_address(addr), src_len));
                    }
                    RuleAttribute::Destination(addr) => {
                        event["destination"] = json!(format!("{}/{}", format_rule_address(addr), dst_len));
                    }
                    RuleAttribute::Iifname(name) => {
                        event["interface"] = json!(name);
                    }
                    RuleAttribute::Oifname(name) => {
                        event["oif"] = json!(name);
                    }
                    _ => {}
                }
            }
        }
    }

    Some(event)
}

fn format_rule_action(action: &RuleAction) -> &'static str {
    match action {
        RuleAction::ToTable => "to_table",
        RuleAction::Blackhole => "blackhole",
        RuleAction::Unreachable => "unreachable",
        RuleAction::Prohibit => "prohibit",
        _ => "unspec",
    }
}

fn format_rule_address(addr: &std::net::IpAddr) -> String {
    addr.to_string()
}

// NUD (Neighbour Unreachability Detection) state bit flags
const NUD_INCOMPLETE: u16 = 0x01;
const NUD_REACHABLE: u16 = 0x02;
const NUD_STALE: u16 = 0x04;
const NUD_DELAY: u16 = 0x08;
const NUD_PROBE: u16 = 0x10;
const NUD_FAILED: u16 = 0x20;
const NUD_PERMANENT: u16 = 0x80;

/// Parse RTM_NEWNEIGH / RTM_DELNEIGH payload into a JSON event.
///
/// Extracts interface name (resolved from ifindex), IP address, MAC address
/// (as colon-separated hex), and NUD state string. If parsing fails, returns
/// a minimal event with only `type` and `action`.
fn parse_neighbour_event(msg_type: u16, payload: &[u8]) -> Option<Value> {
    let action = if msg_type == 28 { "add" } else { "del" };

    let mut event = json!({
        "type": "neighbor_change",
        "action": action,
        "raw_type": msg_type
    });

    let payload_owned = payload.to_vec();
    if let Ok(buf) = NeighbourMessageBuffer::new_checked(&payload_owned) {
        if let Ok(msg) = NeighbourMessage::parse(&buf) {
            if let Some(name) = ifindex_to_name(msg.header.ifindex) {
                event["interface"] = json!(name);
            }
            event["state"] = json!(format_nud_state(msg.header.state.into()));

            for attr in &msg.attributes {
                match attr {
                    NeighbourAttribute::Destination(addr) => {
                        event["address"] = json!(format_neighbour_address(addr));
                    }
                    NeighbourAttribute::LinkLocalAddress(mac) if mac.len() == 6 => {
                        event["mac"] = json!(format!(
                            "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
                            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]
                        ));
                    }
                    _ => {}
                }
            }
        }
    }

    Some(event)
}

fn format_neighbour_address(addr: &NeighbourAddress) -> String {
    match addr {
        NeighbourAddress::Inet(ip) => ip.to_string(),
        NeighbourAddress::Inet6(ip) => ip.to_string(),
        _ => format!("{:?}", addr),
    }
}

fn format_nud_state(state: u16) -> &'static str {
    if state & NUD_REACHABLE != 0 {
        "reachable"
    } else if state & NUD_STALE != 0 {
        "stale"
    } else if state & NUD_DELAY != 0 {
        "delay"
    } else if state & NUD_PROBE != 0 {
        "probe"
    } else if state & NUD_FAILED != 0 {
        "failed"
    } else if state & NUD_PERMANENT != 0 {
        "permanent"
    } else if state & NUD_INCOMPLETE != 0 {
        "incomplete"
    } else {
        "none"
    }
}

/// Format a RouteAddress (IPv4 or IPv6) as a dotted-decimal / colon-hex string.
fn format_route_address(addr: &RouteAddress) -> String {
    match addr {
        RouteAddress::Inet(ip) => ip.to_string(),
        RouteAddress::Inet6(ip) => ip.to_string(),
        _ => format!("{:?}", addr),
    }
}

/// Resolve a network interface index to its name via libc.
///
/// # Safety
/// Uses `libc::if_indextoname` which writes a null-terminated C string into
/// `buf`. On success (non-null return), POSIX guarantees the buffer contains
/// a valid interface name of at most IFNAMSIZ-1 chars plus a null terminator.
/// The `CStr::from_ptr` call is safe because the null check above ensures the
/// buffer was written successfully.
fn ifindex_to_name(index: u32) -> Option<String> {
    let mut buf = [0i8; libc::IFNAMSIZ];
    // SAFETY: buf is IFNAMSIZ bytes, which is the required minimum for if_indextoname
    let result = unsafe { libc::if_indextoname(index, buf.as_mut_ptr()) };
    if result.is_null() {
        return None;
    }
    // SAFETY: if_indextoname succeeded, so buf contains a valid null-terminated string
    let cstr = unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) };
    Some(cstr.to_string_lossy().into_owned())
}

fn format_route_scope(scope: &RouteScope) -> &'static str {
    match scope {
        RouteScope::Universe => "universe",
        RouteScope::Site => "site",
        RouteScope::Link => "link",
        RouteScope::Host => "host",
        RouteScope::NoWhere => "nowhere",
        _ => "unknown",
    }
}

fn format_route_protocol(protocol: &RouteProtocol) -> &'static str {
    match protocol {
        RouteProtocol::Kernel => "kernel",
        RouteProtocol::Boot => "boot",
        RouteProtocol::Static => "static",
        RouteProtocol::Dhcp => "dhcp",
        _ => "unspec",
    }
}

fn format_address_scope(scope: &AddressScope) -> &'static str {
    match scope {
        AddressScope::Universe => "global",
        AddressScope::Link => "link",
        AddressScope::Host => "host",
        AddressScope::Site => "site",
        AddressScope::Nowhere => "nowhere",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a minimal valid netlink message header (16 bytes).
    fn make_nlmsghdr(len: u32, msg_type: u16) -> Vec<u8> {
        let mut buf = vec![0u8; len as usize];
        buf[0..4].copy_from_slice(&(len as u32).to_ne_bytes());
        buf[4..6].copy_from_slice(&msg_type.to_ne_bytes());
        buf
    }

    #[test]
    fn empty_buffer_produces_no_events() {
        let events = parse_netlink_messages(&[]);
        assert!(events.is_empty());
    }

    #[test]
    fn buffer_shorter_than_header_produces_no_events() {
        let events = parse_netlink_messages(&[0u8; 10]);
        assert!(events.is_empty());
    }

    #[test]
    fn rtm_newlink_produces_link_change_add() {
        let msg = make_nlmsghdr(16, 16); // RTM_NEWLINK
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "link_change");
        assert_eq!(events[0]["action"], "add");
    }

    #[test]
    fn rtm_dellink_produces_link_change_del() {
        let msg = make_nlmsghdr(16, 17); // RTM_DELLINK
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "link_change");
        assert_eq!(events[0]["action"], "del");
    }

    #[test]
    fn rtm_newaddr_produces_address_change_add() {
        let msg = make_nlmsghdr(16, 20); // RTM_NEWADDR
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "address_change");
        assert_eq!(events[0]["action"], "add");
    }

    #[test]
    fn rtm_deladdr_produces_address_change_del() {
        let msg = make_nlmsghdr(16, 21); // RTM_DELADDR
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "address_change");
        assert_eq!(events[0]["action"], "del");
    }

    #[test]
    fn rtm_newroute_produces_route_change_add() {
        let msg = make_nlmsghdr(16, 24); // RTM_NEWROUTE
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "route_change");
        assert_eq!(events[0]["action"], "add");
    }

    #[test]
    fn rtm_newneigh_produces_neighbor_change_add() {
        let msg = make_nlmsghdr(16, 28); // RTM_NEWNEIGH
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "neighbor_change");
        assert_eq!(events[0]["action"], "add");
    }

    #[test]
    fn rtm_newrule_produces_rule_change_add() {
        let msg = make_nlmsghdr(16, 32); // RTM_NEWRULE
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "rule_change");
        assert_eq!(events[0]["action"], "add");
    }

    #[test]
    fn unknown_message_type_produces_no_event() {
        let msg = make_nlmsghdr(16, 999);
        let events = parse_netlink_messages(&msg);
        assert!(events.is_empty());
    }

    #[test]
    fn multiple_messages_in_buffer_all_parsed() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&make_nlmsghdr(16, 16)); // RTM_NEWLINK
        buf.extend_from_slice(&make_nlmsghdr(16, 20)); // RTM_NEWADDR
        let events = parse_netlink_messages(&buf);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["type"], "link_change");
        assert_eq!(events[1]["type"], "address_change");
    }

    #[test]
    fn message_with_len_zero_breaks_loop() {
        // A length of 0 (< 16) should break the parsing loop
        let mut buf = vec![0u8; 16];
        // len field = 0
        buf[0..4].copy_from_slice(&0u32.to_ne_bytes());
        let events = parse_netlink_messages(&buf);
        assert!(events.is_empty());
    }

    #[test]
    fn message_len_exceeding_buffer_breaks_loop() {
        // Message claims length beyond the buffer
        let mut buf = vec![0u8; 16];
        buf[0..4].copy_from_slice(&100u32.to_ne_bytes()); // len=100 but buf is only 16 bytes
        buf[4..6].copy_from_slice(&16u16.to_ne_bytes()); // RTM_NEWLINK — would match if parsed
        let events = parse_netlink_messages(&buf);
        assert!(events.is_empty());
    }

    /// Build a real RTM_NEWLINK message with ifinfomsg header + IfName NLA.
    ///
    /// ifinfomsg layout (16 bytes):
    ///   u8  ifi_family, u8 pad, u16 ifi_type, u32 ifi_index, u32 ifi_flags, u32 ifi_change
    ///
    /// NLA layout: u16 nla_len, u16 nla_type, [data]
    fn make_rtm_newlink_with_ifname(index: u32, name: &str) -> Vec<u8> {
        // ifinfomsg (16 bytes)
        let mut payload = vec![0u8; 16];
        payload[4..8].copy_from_slice(&index.to_ne_bytes()); // ifi_index

        // IFLA_IFNAME = 3, NLA format: u16 len + u16 type + name + null
        let name_bytes = name.as_bytes();
        let nla_data_len = name_bytes.len() + 1; // +1 for null terminator
        let nla_len = (4 + nla_data_len) as u16; // 4 = nla header
        let nla_len_aligned = (nla_len as usize + 3) & !3;

        let mut nla = vec![0u8; nla_len_aligned];
        nla[0..2].copy_from_slice(&nla_len.to_ne_bytes());
        nla[2..4].copy_from_slice(&3u16.to_ne_bytes()); // IFLA_IFNAME = 3
        nla[4..4 + name_bytes.len()].copy_from_slice(name_bytes);
        // null terminator at nla[4 + name_bytes.len()] is already 0

        payload.extend_from_slice(&nla);

        // Build complete netlink message
        let total_len = 16 + payload.len();
        let mut msg = vec![0u8; total_len];
        msg[0..4].copy_from_slice(&(total_len as u32).to_ne_bytes());
        msg[4..6].copy_from_slice(&16u16.to_ne_bytes()); // RTM_NEWLINK
        msg[16..].copy_from_slice(&payload);
        msg
    }

    #[test]
    fn rtm_newlink_with_ifname_extracts_interface() {
        let msg = make_rtm_newlink_with_ifname(2, "eth0");
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "link_change");
        assert_eq!(events[0]["action"], "add");
        assert_eq!(events[0]["interface"], "eth0");
        assert_eq!(events[0]["index"], 2);
    }

    /// Build a real RTM_NEWADDR message with ifaddrmsg header + Label NLA + Address NLA.
    ///
    /// ifaddrmsg layout (8 bytes):
    ///   u8 ifa_family, u8 ifa_prefixlen, u8 ifa_flags, u8 ifa_scope, u32 ifa_index
    fn make_rtm_newaddr_with_label(
        family: u8,
        prefix_len: u8,
        scope: u8,
        label: &str,
        addr_bytes: &[u8],
    ) -> Vec<u8> {
        // ifaddrmsg (8 bytes)
        let mut payload = vec![0u8; 8];
        payload[0] = family;
        payload[1] = prefix_len;
        payload[3] = scope;

        // IFA_LABEL = 3, NLA format
        let label_bytes = label.as_bytes();
        let label_nla_data_len = label_bytes.len() + 1;
        let label_nla_len = (4 + label_nla_data_len) as u16;
        let label_nla_aligned = (label_nla_len as usize + 3) & !3;
        let mut label_nla = vec![0u8; label_nla_aligned];
        label_nla[0..2].copy_from_slice(&label_nla_len.to_ne_bytes());
        label_nla[2..4].copy_from_slice(&3u16.to_ne_bytes()); // IFA_LABEL = 3
        label_nla[4..4 + label_bytes.len()].copy_from_slice(label_bytes);
        payload.extend_from_slice(&label_nla);

        // IFA_ADDRESS = 1, NLA format
        let addr_nla_len = (4 + addr_bytes.len()) as u16;
        let addr_nla_aligned = (addr_nla_len as usize + 3) & !3;
        let mut addr_nla = vec![0u8; addr_nla_aligned];
        addr_nla[0..2].copy_from_slice(&addr_nla_len.to_ne_bytes());
        addr_nla[2..4].copy_from_slice(&1u16.to_ne_bytes()); // IFA_ADDRESS = 1
        addr_nla[4..4 + addr_bytes.len()].copy_from_slice(addr_bytes);
        payload.extend_from_slice(&addr_nla);

        // Build complete netlink message
        let total_len = 16 + payload.len();
        let mut msg = vec![0u8; total_len];
        msg[0..4].copy_from_slice(&(total_len as u32).to_ne_bytes());
        msg[4..6].copy_from_slice(&20u16.to_ne_bytes()); // RTM_NEWADDR
        msg[16..].copy_from_slice(&payload);
        msg
    }

    #[test]
    fn rtm_newaddr_with_label_extracts_interface_and_address() {
        // IPv4: family=2 (AF_INET), prefix=24, scope=0 (Universe/global)
        let addr_bytes = [10u8, 0, 0, 1]; // 10.0.0.1
        let msg = make_rtm_newaddr_with_label(2, 24, 0, "eth0", &addr_bytes);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "address_change");
        assert_eq!(events[0]["action"], "add");
        assert_eq!(events[0]["interface"], "eth0");
        assert_eq!(events[0]["address"], "10.0.0.1/24");
        assert_eq!(events[0]["family"], "inet");
        assert_eq!(events[0]["scope"], "global");
    }

    #[test]
    fn rtm_newaddr_link_scope_is_reported() {
        // scope=253 = RT_SCOPE_LINK → "link"
        let addr_bytes = [169u8, 254, 1, 1]; // 169.254.1.1 (link-local)
        let msg = make_rtm_newaddr_with_label(2, 16, 253, "eth0", &addr_bytes);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["scope"], "link");
    }

    /// Build a real RTM_NEWROUTE message.
    ///
    /// rtmsg layout (12 bytes):
    ///   u8 family, u8 dst_len, u8 src_len, u8 tos,
    ///   u8 table, u8 protocol, u8 scope, u8 type, u32 flags
    ///
    /// NLAs: RTA_DST=1, RTA_GATEWAY=5, RTA_OIF=4, RTA_PRIORITY=6
    fn make_rtm_newroute(
        family: u8,
        dst_len: u8,
        protocol: u8,
        scope: u8,
        dst_bytes: Option<&[u8]>,
        gw_bytes: Option<&[u8]>,
        metric: Option<u32>,
    ) -> Vec<u8> {
        // rtmsg (12 bytes)
        let mut payload = vec![0u8; 12];
        payload[0] = family;
        payload[1] = dst_len;
        payload[5] = protocol;
        payload[6] = scope;

        // Helper to append a u32 NLA
        let append_u32_nla = |buf: &mut Vec<u8>, nla_type: u16, val: u32| {
            let nla_len = 8u16; // 4 header + 4 data
            buf.extend_from_slice(&nla_len.to_ne_bytes());
            buf.extend_from_slice(&nla_type.to_ne_bytes());
            buf.extend_from_slice(&val.to_ne_bytes());
        };

        // Helper to append a bytes NLA
        let append_bytes_nla = |buf: &mut Vec<u8>, nla_type: u16, data: &[u8]| {
            let nla_len = (4 + data.len()) as u16;
            let nla_aligned = (nla_len as usize + 3) & !3;
            let mut nla = vec![0u8; nla_aligned];
            nla[0..2].copy_from_slice(&nla_len.to_ne_bytes());
            nla[2..4].copy_from_slice(&nla_type.to_ne_bytes());
            nla[4..4 + data.len()].copy_from_slice(data);
            buf.extend_from_slice(&nla);
        };

        if let Some(dst) = dst_bytes {
            append_bytes_nla(&mut payload, 1, dst); // RTA_DST = 1
        }
        if let Some(gw) = gw_bytes {
            append_bytes_nla(&mut payload, 5, gw); // RTA_GATEWAY = 5
        }
        if let Some(m) = metric {
            append_u32_nla(&mut payload, 6, m); // RTA_PRIORITY = 6
        }

        let total_len = 16 + payload.len();
        let mut msg = vec![0u8; total_len];
        msg[0..4].copy_from_slice(&(total_len as u32).to_ne_bytes());
        msg[4..6].copy_from_slice(&24u16.to_ne_bytes()); // RTM_NEWROUTE
        msg[16..].copy_from_slice(&payload);
        msg
    }

    #[test]
    fn rtm_newroute_with_destination_extracts_dst_and_scope() {
        // IPv4: family=2, dst_len=24, protocol=3 (RTPROT_BOOT=3), scope=253 (RT_SCOPE_LINK)
        let dst = [10u8, 0, 0, 0]; // 10.0.0.0
        let msg = make_rtm_newroute(2, 24, 3, 253, Some(&dst), None, None);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "route_change");
        assert_eq!(events[0]["action"], "add");
        assert_eq!(events[0]["destination"], "10.0.0.0/24");
        assert_eq!(events[0]["scope"], "link");
        assert_eq!(events[0]["protocol"], "boot");
    }

    #[test]
    fn rtm_newroute_with_gateway_extracts_gw() {
        let dst = [192u8, 168, 0, 0];
        let gw = [192u8, 168, 0, 1];
        let msg = make_rtm_newroute(2, 16, 4, 0, Some(&dst), Some(&gw), None);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["destination"], "192.168.0.0/16");
        assert_eq!(events[0]["gateway"], "192.168.0.1");
    }

    #[test]
    fn rtm_newroute_with_metric_extracts_priority() {
        let dst = [10u8, 0, 0, 0];
        let msg = make_rtm_newroute(2, 8, 4, 0, Some(&dst), None, Some(100));
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["metric"], 100);
    }

    #[test]
    fn rtm_newroute_no_destination_emits_default() {
        // prefix_len=0 and no RTA_DST → destination="default"
        let msg = make_rtm_newroute(2, 0, 4, 0, None, None, None);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["destination"], "default");
    }

    #[test]
    fn rtm_delroute_produces_route_change_del() {
        let mut msg = make_rtm_newroute(2, 24, 4, 0, None, None, None);
        // Change msg_type to RTM_DELROUTE=25
        msg[4..6].copy_from_slice(&25u16.to_ne_bytes());
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["action"], "del");
    }

    /// Build a real RTM_NEWNEIGH message.
    ///
    /// ndmsg layout (12 bytes):
    ///   u8 family, u8 pad1, u16 pad2, u32 ifindex, u16 state, u8 flags, u8 type
    ///
    /// NLAs: NDA_DST=1, NDA_LLADDR=2
    fn make_rtm_newneigh(
        family: u8,
        ifindex: u32,
        state: u16,
        dst_bytes: &[u8],
        mac: Option<[u8; 6]>,
    ) -> Vec<u8> {
        // ndmsg (12 bytes)
        let mut payload = vec![0u8; 12];
        payload[0] = family;
        payload[4..8].copy_from_slice(&ifindex.to_ne_bytes());
        payload[8..10].copy_from_slice(&state.to_ne_bytes());

        // NDA_DST = 1
        let dst_nla_len = (4 + dst_bytes.len()) as u16;
        let dst_nla_aligned = (dst_nla_len as usize + 3) & !3;
        let mut dst_nla = vec![0u8; dst_nla_aligned];
        dst_nla[0..2].copy_from_slice(&dst_nla_len.to_ne_bytes());
        dst_nla[2..4].copy_from_slice(&1u16.to_ne_bytes()); // NDA_DST
        dst_nla[4..4 + dst_bytes.len()].copy_from_slice(dst_bytes);
        payload.extend_from_slice(&dst_nla);

        // NDA_LLADDR = 2 (optional)
        if let Some(m) = mac {
            let mac_nla_len = (4 + 6) as u16; // 10 bytes
            let mac_nla_aligned = (mac_nla_len as usize + 3) & !3;
            let mut mac_nla = vec![0u8; mac_nla_aligned];
            mac_nla[0..2].copy_from_slice(&mac_nla_len.to_ne_bytes());
            mac_nla[2..4].copy_from_slice(&2u16.to_ne_bytes()); // NDA_LLADDR
            mac_nla[4..10].copy_from_slice(&m);
            payload.extend_from_slice(&mac_nla);
        }

        let total_len = 16 + payload.len();
        let mut msg = vec![0u8; total_len];
        msg[0..4].copy_from_slice(&(total_len as u32).to_ne_bytes());
        msg[4..6].copy_from_slice(&28u16.to_ne_bytes()); // RTM_NEWNEIGH
        msg[16..].copy_from_slice(&payload);
        msg
    }

    #[test]
    fn rtm_newneigh_with_ip_extracts_address_and_state() {
        let dst = [192u8, 168, 1, 10];
        // ifindex=0 (no real interface → interface field absent)
        // state=NUD_REACHABLE=2
        let msg = make_rtm_newneigh(2, 0, 2, &dst, None);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "neighbor_change");
        assert_eq!(events[0]["action"], "add");
        assert_eq!(events[0]["address"], "192.168.1.10");
        assert_eq!(events[0]["state"], "reachable");
    }

    #[test]
    fn rtm_newneigh_with_mac_extracts_formatted_mac() {
        let dst = [10u8, 0, 0, 1];
        let mac = [0xaau8, 0xbb, 0xcc, 0xdd, 0xee, 0xff];
        let msg = make_rtm_newneigh(2, 0, 2, &dst, Some(mac));
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["mac"], "aa:bb:cc:dd:ee:ff");
    }

    #[test]
    fn rtm_delneigh_produces_neighbor_change_del() {
        let dst = [10u8, 0, 0, 1];
        let mut msg = make_rtm_newneigh(2, 0, 2, &dst, None);
        msg[4..6].copy_from_slice(&29u16.to_ne_bytes()); // RTM_DELNEIGH
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["action"], "del");
    }

    // --- format_nud_state unit tests ---

    #[test]
    fn nud_state_reachable() {
        assert_eq!(format_nud_state(NUD_REACHABLE), "reachable");
    }

    #[test]
    fn nud_state_stale() {
        assert_eq!(format_nud_state(NUD_STALE), "stale");
    }

    #[test]
    fn nud_state_delay() {
        assert_eq!(format_nud_state(NUD_DELAY), "delay");
    }

    #[test]
    fn nud_state_probe() {
        assert_eq!(format_nud_state(NUD_PROBE), "probe");
    }

    #[test]
    fn nud_state_failed() {
        assert_eq!(format_nud_state(NUD_FAILED), "failed");
    }

    #[test]
    fn nud_state_permanent() {
        assert_eq!(format_nud_state(NUD_PERMANENT), "permanent");
    }

    #[test]
    fn nud_state_incomplete() {
        assert_eq!(format_nud_state(NUD_INCOMPLETE), "incomplete");
    }

    #[test]
    fn nud_state_none() {
        assert_eq!(format_nud_state(0), "none");
    }

    #[test]
    fn nud_state_reachable_beats_stale_when_both_set() {
        // When multiple bits set, REACHABLE takes priority (checked first)
        assert_eq!(format_nud_state(NUD_REACHABLE | NUD_STALE), "reachable");
    }

    #[test]
    fn rtm_delrule_produces_rule_change_del() {
        let msg = make_nlmsghdr(16, 33); // RTM_DELRULE
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "rule_change");
        assert_eq!(events[0]["action"], "del");
    }

    #[test]
    fn multicast_groups_includes_rule_groups() {
        let groups = multicast_groups();
        // RTNLGRP_IPV4_RULE=14, RTNLGRP_IPV6_RULE=19
        assert_ne!(groups & (1 << (RTNLGRP_IPV4_RULE - 1)), 0);
        assert_ne!(groups & (1 << (RTNLGRP_IPV6_RULE - 1)), 0);
    }

    #[test]
    fn multicast_groups_includes_all_required_groups() {
        let groups = multicast_groups();
        let required = [
            RTNLGRP_LINK,
            RTNLGRP_IPV4_IFADDR,
            RTNLGRP_IPV4_ROUTE,
            RTNLGRP_IPV6_IFADDR,
            RTNLGRP_IPV6_ROUTE,
            RTNLGRP_NEIGH,
            RTNLGRP_IPV4_RULE,
            RTNLGRP_IPV6_RULE,
        ];
        for grp in required {
            assert_ne!(
                groups & (1 << (grp - 1)),
                0,
                "RTNLGRP_{} missing from multicast groups",
                grp
            );
        }
    }

    // --- format_link_state unit tests ---

    #[test]
    fn link_state_up() {
        assert_eq!(format_link_state(&State::Up), "up");
    }

    #[test]
    fn link_state_down() {
        assert_eq!(format_link_state(&State::Down), "down");
    }

    #[test]
    fn link_state_dormant() {
        assert_eq!(format_link_state(&State::Dormant), "dormant");
    }

    #[test]
    fn link_state_lower_layer_down() {
        assert_eq!(format_link_state(&State::LowerLayerDown), "lowerlayerdown");
    }

    #[test]
    fn link_state_testing() {
        assert_eq!(format_link_state(&State::Testing), "testing");
    }

    #[test]
    fn link_state_not_present() {
        assert_eq!(format_link_state(&State::NotPresent), "notpresent");
    }

    #[test]
    fn link_state_unknown() {
        assert_eq!(format_link_state(&State::Unknown), "unknown");
    }

    // --- format_address_family unit tests ---

    #[test]
    fn address_family_inet() {
        assert_eq!(format_address_family(&AddressFamily::Inet), "inet");
    }

    #[test]
    fn address_family_inet6() {
        assert_eq!(format_address_family(&AddressFamily::Inet6), "inet6");
    }

    // --- format_route_scope unit tests ---

    #[test]
    fn route_scope_universe() {
        assert_eq!(format_route_scope(&RouteScope::Universe), "universe");
    }

    #[test]
    fn route_scope_site() {
        assert_eq!(format_route_scope(&RouteScope::Site), "site");
    }

    #[test]
    fn route_scope_link() {
        assert_eq!(format_route_scope(&RouteScope::Link), "link");
    }

    #[test]
    fn route_scope_host() {
        assert_eq!(format_route_scope(&RouteScope::Host), "host");
    }

    #[test]
    fn route_scope_nowhere() {
        assert_eq!(format_route_scope(&RouteScope::NoWhere), "nowhere");
    }

    // --- format_route_protocol unit tests ---

    #[test]
    fn route_protocol_kernel() {
        assert_eq!(format_route_protocol(&RouteProtocol::Kernel), "kernel");
    }

    #[test]
    fn route_protocol_boot() {
        assert_eq!(format_route_protocol(&RouteProtocol::Boot), "boot");
    }

    #[test]
    fn route_protocol_static() {
        assert_eq!(format_route_protocol(&RouteProtocol::Static), "static");
    }

    #[test]
    fn route_protocol_dhcp() {
        assert_eq!(format_route_protocol(&RouteProtocol::Dhcp), "dhcp");
    }

    // --- format_address_scope unit tests ---

    #[test]
    fn address_scope_universe() {
        assert_eq!(format_address_scope(&AddressScope::Universe), "global");
    }

    #[test]
    fn address_scope_link() {
        assert_eq!(format_address_scope(&AddressScope::Link), "link");
    }

    #[test]
    fn address_scope_host() {
        assert_eq!(format_address_scope(&AddressScope::Host), "host");
    }

    #[test]
    fn address_scope_site() {
        assert_eq!(format_address_scope(&AddressScope::Site), "site");
    }

    #[test]
    fn address_scope_nowhere() {
        assert_eq!(format_address_scope(&AddressScope::Nowhere), "nowhere");
    }

    // --- format_rule_action unit tests ---

    #[test]
    fn rule_action_to_table() {
        assert_eq!(format_rule_action(&RuleAction::ToTable), "to_table");
    }

    #[test]
    fn rule_action_blackhole() {
        assert_eq!(format_rule_action(&RuleAction::Blackhole), "blackhole");
    }

    #[test]
    fn rule_action_unreachable() {
        assert_eq!(format_rule_action(&RuleAction::Unreachable), "unreachable");
    }

    #[test]
    fn rule_action_prohibit() {
        assert_eq!(format_rule_action(&RuleAction::Prohibit), "prohibit");
    }

    // --- default/unknown branch tests for format_* functions ---

    #[test]
    fn address_family_unknown_returns_unknown() {
        assert_eq!(format_address_family(&AddressFamily::Other(99)), "unknown");
    }

    #[test]
    fn route_scope_unknown_returns_unknown() {
        assert_eq!(format_route_scope(&RouteScope::Other(250)), "unknown");
    }

    #[test]
    fn route_protocol_unknown_returns_unspec() {
        assert_eq!(format_route_protocol(&RouteProtocol::Other(200)), "unspec");
    }

    #[test]
    fn address_scope_unknown_returns_unknown() {
        assert_eq!(format_address_scope(&AddressScope::Other(254)), "unknown");
    }

    #[test]
    fn rule_action_unknown_returns_unspec() {
        assert_eq!(format_rule_action(&RuleAction::Other(255)), "unspec");
    }

    #[test]
    fn route_address_unknown_uses_debug_format() {
        let addr = RouteAddress::Other(vec![1, 2, 3]);
        let result = format_route_address(&addr);
        assert!(result.contains("Other"), "expected Debug format, got: {}", result);
    }

    // --- ifindex_to_name with invalid index ---

    #[test]
    fn ifindex_to_name_zero_returns_none() {
        // Interface index 0 is invalid
        assert!(ifindex_to_name(0).is_none());
    }

    #[test]
    fn ifindex_to_name_nonexistent_returns_none() {
        // Very large index that doesn't correspond to any interface
        assert!(ifindex_to_name(999999).is_none());
    }

    // --- format_neighbour_address ---

    #[test]
    fn neighbour_address_ipv4_formats_correctly() {
        let addr = NeighbourAddress::Inet(std::net::Ipv4Addr::new(10, 0, 0, 1));
        assert_eq!(format_neighbour_address(&addr), "10.0.0.1");
    }

    #[test]
    fn neighbour_address_ipv6_formats_correctly() {
        let addr = NeighbourAddress::Inet6(std::net::Ipv6Addr::LOCALHOST);
        assert_eq!(format_neighbour_address(&addr), "::1");
    }

    #[test]
    fn neighbour_address_unknown_uses_debug_format() {
        let addr = NeighbourAddress::Other(vec![0xde, 0xad]);
        let result = format_neighbour_address(&addr);
        assert!(result.contains("Other"), "expected Debug format, got: {}", result);
    }

    // --- format_rule_address ---

    #[test]
    fn rule_address_ipv4_formats_correctly() {
        let addr = std::net::IpAddr::V4(std::net::Ipv4Addr::new(192, 168, 1, 1));
        assert_eq!(format_rule_address(&addr), "192.168.1.1");
    }

    #[test]
    fn rule_address_ipv6_formats_correctly() {
        let addr = std::net::IpAddr::V6(std::net::Ipv6Addr::LOCALHOST);
        assert_eq!(format_rule_address(&addr), "::1");
    }

    // --- Non-Ethernet MAC tests (mac.len() != 6) ---

    /// Build a RTM_NEWNEIGH with variable-length MAC (NDA_LLADDR).
    fn make_rtm_newneigh_var_mac(
        family: u8,
        ifindex: u32,
        state: u16,
        dst_bytes: &[u8],
        mac: &[u8],
    ) -> Vec<u8> {
        let mut payload = vec![0u8; 12];
        payload[0] = family;
        payload[4..8].copy_from_slice(&ifindex.to_ne_bytes());
        payload[8..10].copy_from_slice(&state.to_ne_bytes());

        // NDA_DST = 1
        let dst_nla_len = (4 + dst_bytes.len()) as u16;
        let dst_nla_aligned = (dst_nla_len as usize + 3) & !3;
        let mut dst_nla = vec![0u8; dst_nla_aligned];
        dst_nla[0..2].copy_from_slice(&dst_nla_len.to_ne_bytes());
        dst_nla[2..4].copy_from_slice(&1u16.to_ne_bytes());
        dst_nla[4..4 + dst_bytes.len()].copy_from_slice(dst_bytes);
        payload.extend_from_slice(&dst_nla);

        // NDA_LLADDR = 2 with variable-length MAC
        let mac_nla_len = (4 + mac.len()) as u16;
        let mac_nla_aligned = (mac_nla_len as usize + 3) & !3;
        let mut mac_nla = vec![0u8; mac_nla_aligned];
        mac_nla[0..2].copy_from_slice(&mac_nla_len.to_ne_bytes());
        mac_nla[2..4].copy_from_slice(&2u16.to_ne_bytes());
        mac_nla[4..4 + mac.len()].copy_from_slice(mac);
        payload.extend_from_slice(&mac_nla);

        let total_len = 16 + payload.len();
        let mut msg = vec![0u8; total_len];
        msg[0..4].copy_from_slice(&(total_len as u32).to_ne_bytes());
        msg[4..6].copy_from_slice(&28u16.to_ne_bytes()); // RTM_NEWNEIGH
        msg[16..].copy_from_slice(&payload);
        msg
    }

    #[test]
    fn rtm_newneigh_with_4byte_mac_omits_mac_field() {
        // PPP-like interfaces may have 4-byte link-layer addresses
        let dst = [10u8, 0, 0, 1];
        let short_mac = [0xaa, 0xbb, 0xcc, 0xdd];
        let msg = make_rtm_newneigh_var_mac(2, 0, 2, &dst, &short_mac);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "neighbor_change");
        assert_eq!(events[0]["address"], "10.0.0.1");
        // Non-6-byte MAC should be silently ignored
        assert!(events[0].get("mac").is_none() || events[0]["mac"].is_null());
    }

    #[test]
    fn rtm_newneigh_with_8byte_mac_omits_mac_field() {
        // InfiniBand has 20-byte link-layer addresses; test with 8 bytes
        let dst = [192u8, 168, 1, 1];
        let long_mac = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08];
        let msg = make_rtm_newneigh_var_mac(2, 0, 4, &dst, &long_mac);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert!(events[0].get("mac").is_none() || events[0]["mac"].is_null());
    }

    /// Build a RTM_NEWLINK with a variable-length IFLA_ADDRESS NLA.
    fn make_rtm_newlink_with_mac(index: u32, name: &str, mac: &[u8]) -> Vec<u8> {
        // ifinfomsg (16 bytes)
        let mut payload = vec![0u8; 16];
        payload[4..8].copy_from_slice(&index.to_ne_bytes());

        // IFLA_IFNAME = 3
        let name_bytes = name.as_bytes();
        let nla_data_len = name_bytes.len() + 1;
        let nla_len = (4 + nla_data_len) as u16;
        let nla_len_aligned = (nla_len as usize + 3) & !3;
        let mut nla = vec![0u8; nla_len_aligned];
        nla[0..2].copy_from_slice(&nla_len.to_ne_bytes());
        nla[2..4].copy_from_slice(&3u16.to_ne_bytes());
        nla[4..4 + name_bytes.len()].copy_from_slice(name_bytes);
        payload.extend_from_slice(&nla);

        // IFLA_ADDRESS = 1 (variable-length MAC)
        let mac_nla_len = (4 + mac.len()) as u16;
        let mac_nla_aligned = (mac_nla_len as usize + 3) & !3;
        let mut mac_nla = vec![0u8; mac_nla_aligned];
        mac_nla[0..2].copy_from_slice(&mac_nla_len.to_ne_bytes());
        mac_nla[2..4].copy_from_slice(&1u16.to_ne_bytes()); // IFLA_ADDRESS = 1
        mac_nla[4..4 + mac.len()].copy_from_slice(mac);
        payload.extend_from_slice(&mac_nla);

        let total_len = 16 + payload.len();
        let mut msg = vec![0u8; total_len];
        msg[0..4].copy_from_slice(&(total_len as u32).to_ne_bytes());
        msg[4..6].copy_from_slice(&16u16.to_ne_bytes()); // RTM_NEWLINK
        msg[16..].copy_from_slice(&payload);
        msg
    }

    #[test]
    fn rtm_newlink_with_6byte_mac_includes_mac_field() {
        let mac = [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff];
        let msg = make_rtm_newlink_with_mac(1, "eth0", &mac);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["mac"], "aa:bb:cc:dd:ee:ff");
    }

    #[test]
    fn rtm_newlink_with_4byte_mac_omits_mac_field() {
        // PPP or tunnel interface with non-Ethernet address
        let mac = [0xaa, 0xbb, 0xcc, 0xdd];
        let msg = make_rtm_newlink_with_mac(1, "ppp0", &mac);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["interface"], "ppp0");
        // Non-6-byte address should be silently ignored
        assert!(events[0].get("mac").is_none() || events[0]["mac"].is_null());
    }

    #[test]
    fn rtm_newlink_with_empty_mac_omits_mac_field() {
        // Loopback has empty address
        let msg = make_rtm_newlink_with_mac(1, "lo", &[]);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["interface"], "lo");
        assert!(events[0].get("mac").is_none() || events[0]["mac"].is_null());
    }

    // --- IPv6 route tests ---

    #[test]
    fn rtm_newroute_ipv6_with_destination() {
        // IPv6: family=10 (AF_INET6), dst_len=64, protocol=2 (RTPROT_KERNEL)
        // 2001:db8:: = [0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        let dst = [0x20u8, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        let msg = make_rtm_newroute(10, 64, 2, 0, Some(&dst), None, None);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["destination"], "2001:db8::/64");
        assert_eq!(events[0]["protocol"], "kernel");
    }

    #[test]
    fn rtm_newroute_with_all_attributes() {
        // Route with destination, gateway, and metric
        let dst = [10u8, 0, 0, 0];
        let gw = [10u8, 0, 0, 1];
        let msg = make_rtm_newroute(2, 24, 16, 0, Some(&dst), Some(&gw), Some(600));
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["destination"], "10.0.0.0/24");
        assert_eq!(events[0]["gateway"], "10.0.0.1");
        assert_eq!(events[0]["metric"], 600);
        assert_eq!(events[0]["protocol"], "dhcp"); // protocol=16 is RTPROT_DHCP
    }

    // --- IPv6 address test ---

    // --- Rule event with attributes ---

    /// Build an RTM_NEWRULE message with fib_rule_hdr and NLAs.
    ///
    /// fib_rule_hdr (12 bytes):
    ///   u8 family, u8 dst_len, u8 src_len, u8 tos,
    ///   u8 table, u8 res1, u8 res2, u8 action, u32 flags
    ///
    /// NLA types: FRA_PRIORITY=6, FRA_TABLE=15
    fn make_rtm_newrule(
        family: u8,
        dst_len: u8,
        src_len: u8,
        table: u8,
        action: u8,
        priority: Option<u32>,
    ) -> Vec<u8> {
        let mut payload = vec![0u8; 12];
        payload[0] = family;
        payload[1] = dst_len;
        payload[2] = src_len;
        payload[4] = table;
        payload[7] = action;

        // FRA_PRIORITY = 6 (u32 NLA)
        if let Some(p) = priority {
            let nla_len = 8u16;
            payload.extend_from_slice(&nla_len.to_ne_bytes());
            payload.extend_from_slice(&6u16.to_ne_bytes());
            payload.extend_from_slice(&p.to_ne_bytes());
        }

        let total_len = 16 + payload.len();
        let mut msg = vec![0u8; total_len];
        msg[0..4].copy_from_slice(&(total_len as u32).to_ne_bytes());
        msg[4..6].copy_from_slice(&32u16.to_ne_bytes()); // RTM_NEWRULE
        msg[16..].copy_from_slice(&payload);
        msg
    }

    #[test]
    fn rtm_newrule_with_priority_extracts_fields() {
        let msg = make_rtm_newrule(2, 0, 0, 254, 1, Some(32766));
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "rule_change");
        assert_eq!(events[0]["action"], "add");
        assert_eq!(events[0]["table"], 254);
        assert_eq!(events[0]["priority"], 32766);
        assert_eq!(events[0]["rule_action"], "to_table"); // action=1 is FR_ACT_TO_TBL
    }

    #[test]
    fn rtm_newrule_blackhole_action() {
        // action=6 is FR_ACT_BLACKHOLE
        let msg = make_rtm_newrule(2, 0, 0, 0, 6, None);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events[0]["rule_action"], "blackhole");
    }

    #[test]
    fn rtm_newaddr_ipv6_link_local() {
        // family=10 (AF_INET6), prefix_len=64, scope=253 (link)
        // fe80::1 = [0xfe, 0x80, 0,0,0,0,0,0, 0,0,0,0,0,0,0,1]
        let addr = [0xfeu8, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1];
        let msg = make_rtm_newaddr_with_label(10, 64, 253, "eth0", &addr);
        let events = parse_netlink_messages(&msg);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "address_change");
        assert_eq!(events[0]["family"], "inet6");
        assert_eq!(events[0]["scope"], "link");
        assert_eq!(events[0]["interface"], "eth0");
    }
}
