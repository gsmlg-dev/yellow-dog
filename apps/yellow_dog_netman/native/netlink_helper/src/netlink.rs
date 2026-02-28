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

fn multicast_groups() -> u32 {
    (1 << (RTNLGRP_LINK - 1))
        | (1 << (RTNLGRP_IPV4_IFADDR - 1))
        | (1 << (RTNLGRP_IPV4_ROUTE - 1))
        | (1 << (RTNLGRP_IPV6_IFADDR - 1))
        | (1 << (RTNLGRP_IPV6_ROUTE - 1))
        | (1 << (RTNLGRP_NEIGH - 1))
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
            32 | 33 => Some(json!({
                "type": "rule_change",
                "action": if msg_type == 32 { "add" } else { "del" },
                "raw_type": msg_type
            })),
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
fn ifindex_to_name(index: u32) -> Option<String> {
    let mut buf = [0i8; libc::IFNAMSIZ];
    let result = unsafe { libc::if_indextoname(index, buf.as_mut_ptr()) };
    if result.is_null() {
        return None;
    }
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
}
