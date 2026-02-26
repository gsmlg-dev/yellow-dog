//! # ARP Probe Construction and Transmission
//!
//! Builds and sends ARP probe packets for Duplicate Address Detection (DAD)
//! as specified in RFC 5227.
//!
//! ## ARP Probe (RFC 5227 Section 2.1.1)
//!
//! - Sender HW address = client's MAC
//! - Sender protocol address = 0.0.0.0 (probe, not a claim)
//! - Target HW address = 00:00:00:00:00:00
//! - Target protocol address = IP address being probed
//!
//! ## Frame Layout (42 bytes)
//!
//! ```text
//! Offset  Size  Field
//! ------  ----  -----
//! Ethernet Header (14 bytes):
//!   0      6    Destination MAC (FF:FF:FF:FF:FF:FF)
//!   6      6    Source MAC (client's MAC)
//!  12      2    EtherType (0x0806 = ARP)
//! ARP Payload (28 bytes):
//!  14      2    Hardware type (0x0001 = Ethernet)
//!  16      2    Protocol type (0x0800 = IPv4)
//!  18      1    Hardware address length (6)
//!  19      1    Protocol address length (4)
//!  20      2    Operation (0x0001 = REQUEST)
//!  22      6    Sender hardware address
//!  28      4    Sender protocol address (0.0.0.0)
//!  32      6    Target hardware address (00:00:00:00:00:00)
//!  38      4    Target protocol address (probed IP)
//! ```

use std::os::unix::io::RawFd;

pub const BROADCAST_MAC: [u8; 6] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
pub const ZERO_MAC: [u8; 6] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
pub const ZERO_IP: [u8; 4] = [0x00, 0x00, 0x00, 0x00];
pub const ETHERTYPE_ARP: [u8; 2] = [0x08, 0x06];
pub const ARP_HW_ETHERNET: [u8; 2] = [0x00, 0x01];
pub const ARP_PROTO_IPV4: [u8; 2] = [0x08, 0x00];
pub const ARP_OP_REQUEST: [u8; 2] = [0x00, 0x01];
pub const ARP_OP_REPLY: [u8; 2] = [0x00, 0x02];
pub const ARP_FRAME_SIZE: usize = 42;

/// Build an ARP probe frame for Duplicate Address Detection.
pub fn build_probe(sender_mac: &[u8; 6], target_ip: (u8, u8, u8, u8)) -> [u8; ARP_FRAME_SIZE] {
    let mut frame = [0u8; ARP_FRAME_SIZE];

    // Ethernet header (14 bytes)
    frame[0..6].copy_from_slice(&BROADCAST_MAC);
    frame[6..12].copy_from_slice(sender_mac);
    frame[12..14].copy_from_slice(&ETHERTYPE_ARP);

    // ARP payload (28 bytes)
    frame[14..16].copy_from_slice(&ARP_HW_ETHERNET);
    frame[16..18].copy_from_slice(&ARP_PROTO_IPV4);
    frame[18] = 6; // hw addr len
    frame[19] = 4; // proto addr len
    frame[20..22].copy_from_slice(&ARP_OP_REQUEST);
    frame[22..28].copy_from_slice(sender_mac);
    frame[28..32].copy_from_slice(&ZERO_IP); // sender IP = 0.0.0.0 (probe)
    frame[32..38].copy_from_slice(&ZERO_MAC); // target MAC = zeros
    frame[38] = target_ip.0;
    frame[39] = target_ip.1;
    frame[40] = target_ip.2;
    frame[41] = target_ip.3;

    frame
}

/// Send a raw ARP frame on the given socket.
///
/// Linux: Uses `sendto(2)` with `sockaddr_ll` to send on the AF_PACKET socket.
/// FreeBSD/macOS: Writes to BPF fd (not yet implemented).
#[cfg(target_os = "linux")]
pub fn send_raw(arp_fd: RawFd, interface: &str, frame: &[u8; ARP_FRAME_SIZE]) -> Result<(), String> {
    let ifindex = crate::socket::get_interface_index(interface)?;

    let mut sll: libc::sockaddr_ll = unsafe { std::mem::zeroed() };
    sll.sll_family = libc::AF_PACKET as u16;
    sll.sll_protocol = (libc::ETH_P_ARP as u16).to_be();
    sll.sll_ifindex = ifindex as i32;
    sll.sll_halen = 6;
    sll.sll_addr[..6].copy_from_slice(&BROADCAST_MAC);

    // SAFETY: sendto with a valid AF_PACKET socket and sockaddr_ll.
    let ret = unsafe {
        libc::sendto(
            arp_fd,
            frame.as_ptr() as *const libc::c_void,
            frame.len(),
            0,
            &sll as *const libc::sockaddr_ll as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_ll>() as libc::socklen_t,
        )
    };

    if ret < 0 {
        return Err(format!(
            "ARP sendto({interface}): {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
pub fn send_raw(_arp_fd: RawFd, _interface: &str, _frame: &[u8; ARP_FRAME_SIZE]) -> Result<(), String> {
    Err("ARP send: BPF not yet implemented on this platform".to_string())
}

/// Parse an incoming ARP frame and check if it indicates an address conflict.
///
/// Returns `Some((sender_mac, sender_ip))` if the frame is an ARP
/// request/reply where the sender claims the IP we are probing.
/// Returns `None` if the frame is irrelevant.
///
/// Per RFC 5227 Section 2.1.1, a conflict is detected if the sender
/// protocol address matches the IP being probed.
pub fn parse_reply(
    frame: &[u8],
    target_ip: (u8, u8, u8, u8),
) -> Option<([u8; 6], [u8; 4])> {
    if frame.len() < ARP_FRAME_SIZE {
        return None;
    }

    if frame[12..14] != ETHERTYPE_ARP {
        return None;
    }

    let opcode = &frame[20..22];
    if opcode != ARP_OP_REPLY && opcode != ARP_OP_REQUEST {
        return None;
    }

    let sender_proto = &frame[28..32];
    let target = [target_ip.0, target_ip.1, target_ip.2, target_ip.3];

    if sender_proto == target {
        let mut sender_mac = [0u8; 6];
        sender_mac.copy_from_slice(&frame[22..28]);
        let mut sender_ip = [0u8; 4];
        sender_ip.copy_from_slice(sender_proto);
        return Some((sender_mac, sender_ip));
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_probe_layout() {
        let mac = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55];
        let ip = (192, 168, 1, 100);
        let frame = build_probe(&mac, ip);

        assert_eq!(&frame[0..6], &BROADCAST_MAC);
        assert_eq!(&frame[6..12], &mac);
        assert_eq!(&frame[12..14], &ETHERTYPE_ARP);
        assert_eq!(&frame[14..16], &ARP_HW_ETHERNET);
        assert_eq!(&frame[16..18], &ARP_PROTO_IPV4);
        assert_eq!(frame[18], 6);
        assert_eq!(frame[19], 4);
        assert_eq!(&frame[20..22], &ARP_OP_REQUEST);
        assert_eq!(&frame[22..28], &mac);
        assert_eq!(&frame[28..32], &ZERO_IP);
        assert_eq!(&frame[32..38], &ZERO_MAC);
        assert_eq!(&frame[38..42], &[192, 168, 1, 100]);
    }

    #[test]
    fn test_parse_reply_detects_conflict() {
        let target_ip = (192, 168, 1, 100);

        let mut frame = [0u8; ARP_FRAME_SIZE];
        frame[12..14].copy_from_slice(&ETHERTYPE_ARP);
        frame[20..22].copy_from_slice(&ARP_OP_REPLY);
        frame[22..28].copy_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
        frame[28..32].copy_from_slice(&[192, 168, 1, 100]);

        let result = parse_reply(&frame, target_ip);
        assert!(result.is_some());
        let (conflict_mac, conflict_ip) = result.unwrap();
        assert_eq!(conflict_mac, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
        assert_eq!(conflict_ip, [192, 168, 1, 100]);
    }

    #[test]
    fn test_parse_reply_ignores_different_ip() {
        let target_ip = (192, 168, 1, 100);
        let mut frame = [0u8; ARP_FRAME_SIZE];
        frame[12..14].copy_from_slice(&ETHERTYPE_ARP);
        frame[20..22].copy_from_slice(&ARP_OP_REPLY);
        frame[28..32].copy_from_slice(&[192, 168, 1, 200]);
        assert!(parse_reply(&frame, target_ip).is_none());
    }

    #[test]
    fn test_parse_reply_rejects_short_frame() {
        let target_ip = (192, 168, 1, 100);
        let short_frame = [0u8; 20];
        assert!(parse_reply(&short_frame, target_ip).is_none());
    }

    #[test]
    fn test_parse_reply_detects_conflict_from_request() {
        let target_ip = (10, 0, 0, 50);
        let mut frame = [0u8; ARP_FRAME_SIZE];
        frame[12..14].copy_from_slice(&ETHERTYPE_ARP);
        frame[20..22].copy_from_slice(&ARP_OP_REQUEST);
        frame[22..28].copy_from_slice(&[0x01, 0x02, 0x03, 0x04, 0x05, 0x06]);
        frame[28..32].copy_from_slice(&[10, 0, 0, 50]);

        let result = parse_reply(&frame, target_ip);
        assert!(result.is_some());
    }
}
