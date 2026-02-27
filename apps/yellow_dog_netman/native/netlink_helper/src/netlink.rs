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
