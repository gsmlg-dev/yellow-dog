//! Netlink socket management and multicast group subscription.

use std::sync::mpsc;

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
/// This is a simplified parser — in production, use netlink-packet-route
/// for full RTM_* message parsing. This stub extracts basic info.
fn parse_netlink_messages(buf: &[u8]) -> Vec<Value> {
    let mut events = Vec::new();
    let mut offset = 0;

    while offset + 16 <= buf.len() {
        let len = u32::from_ne_bytes([buf[offset], buf[offset + 1], buf[offset + 2], buf[offset + 3]]) as usize;
        if len < 16 || offset + len > buf.len() {
            break;
        }

        let msg_type = u16::from_ne_bytes([buf[offset + 4], buf[offset + 5]]);

        let event = match msg_type {
            // RTM_NEWLINK = 16, RTM_DELLINK = 17
            16 | 17 => Some(json!({
                "type": "link_change",
                "action": if msg_type == 16 { "add" } else { "del" },
                "raw_type": msg_type
            })),
            // RTM_NEWADDR = 20, RTM_DELADDR = 21
            20 | 21 => Some(json!({
                "type": "address_change",
                "action": if msg_type == 20 { "add" } else { "del" },
                "raw_type": msg_type
            })),
            // RTM_NEWROUTE = 24, RTM_DELROUTE = 25
            24 | 25 => Some(json!({
                "type": "route_change",
                "action": if msg_type == 24 { "add" } else { "del" },
                "raw_type": msg_type
            })),
            // RTM_NEWNEIGH = 28, RTM_DELNEIGH = 29
            28 | 29 => Some(json!({
                "type": "neighbor_change",
                "action": if msg_type == 28 { "add" } else { "del" },
                "raw_type": msg_type
            })),
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
}
