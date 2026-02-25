//! # ARP Probe Construction and Transmission
//!
//! This module handles building and sending ARP probe packets for Duplicate
//! Address Detection (DAD) as specified in RFC 5227.
//!
//! ## Background
//!
//! Before a DHCP client can use a newly offered IP address, it SHOULD verify
//! that the address is not already in use on the local network. This is done
//! by sending ARP probes:
//!
//! 1. **ARP Probe** (RFC 5227 Section 2.1.1):
//!    - Sender HW address = client's MAC
//!    - Sender protocol address = 0.0.0.0 (indicates this is a probe, not a
//!      gratuitous ARP or normal request)
//!    - Target HW address = 00:00:00:00:00:00
//!    - Target protocol address = the IP address being probed
//!
//! 2. If no ARP reply is received within the probe period (typically 1-2
//!    seconds, 3 probes), the address is considered available.
//!
//! 3. If a reply IS received, the client must send a DHCPDECLINE to the
//!    server and restart the discovery process.
//!
//! ## Frame Layout
//!
//! An ARP probe on Ethernet has the following layout (42 bytes total):
//!
//! ```text
//! Offset  Size  Field
//! ------  ----  -----
//! Ethernet Header (14 bytes):
//!   0      6    Destination MAC (FF:FF:FF:FF:FF:FF = broadcast)
//!   6      6    Source MAC (client's interface MAC)
//!  12      2    EtherType (0x0806 = ARP)
//!
//! ARP Payload (28 bytes):
//!  14      2    Hardware type (0x0001 = Ethernet)
//!  16      2    Protocol type (0x0800 = IPv4)
//!  18      1    Hardware address length (6)
//!  19      1    Protocol address length (4)
//!  20      2    Operation (0x0001 = REQUEST)
//!  22      6    Sender hardware address (client's MAC)
//!  28      4    Sender protocol address (0.0.0.0 for probe)
//!  32      6    Target hardware address (00:00:00:00:00:00)
//!  38      4    Target protocol address (IP being probed)
//! ```

/// Ethernet broadcast address (FF:FF:FF:FF:FF:FF).
pub const BROADCAST_MAC: [u8; 6] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff];

/// Zero MAC address, used as the target hardware address in ARP probes.
pub const ZERO_MAC: [u8; 6] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

/// Zero IPv4 address, used as the sender protocol address in ARP probes
/// to indicate "I don't have an IP yet, I'm just checking if this one is free."
pub const ZERO_IP: [u8; 4] = [0x00, 0x00, 0x00, 0x00];

/// EtherType for ARP (network byte order).
pub const ETHERTYPE_ARP: [u8; 2] = [0x08, 0x06];

/// ARP hardware type: Ethernet.
pub const ARP_HW_ETHERNET: [u8; 2] = [0x00, 0x01];

/// ARP protocol type: IPv4.
pub const ARP_PROTO_IPV4: [u8; 2] = [0x08, 0x00];

/// ARP operation: REQUEST.
pub const ARP_OP_REQUEST: [u8; 2] = [0x00, 0x01];

/// ARP operation: REPLY (used for parsing incoming ARP frames).
pub const ARP_OP_REPLY: [u8; 2] = [0x00, 0x02];

/// Total size of an ARP probe frame (Ethernet header + ARP payload).
pub const ARP_FRAME_SIZE: usize = 42;

/// Build an ARP probe frame for Duplicate Address Detection.
///
/// ## Parameters
/// - `sender_mac` - The MAC address of the client's network interface.
/// - `target_ip`  - The IPv4 address to probe, as a 4-tuple `(a, b, c, d)`.
///
/// ## Returns
/// A 42-byte ARP probe frame ready to be sent on the raw socket.
///
/// ## RFC 5227 Compliance
///
/// The sender protocol address is set to `0.0.0.0` as required by RFC 5227
/// Section 2.1.1. This distinguishes a probe from a gratuitous ARP (where
/// sender and target protocol addresses are the same) and from a normal ARP
/// request (where sender protocol address is the sender's current IP).
pub fn build_probe(sender_mac: &[u8; 6], target_ip: (u8, u8, u8, u8)) -> [u8; ARP_FRAME_SIZE] {
    let mut frame = [0u8; ARP_FRAME_SIZE];

    // -- Ethernet header (14 bytes) --
    // Destination: broadcast
    frame[0..6].copy_from_slice(&BROADCAST_MAC);
    // Source: client MAC
    frame[6..12].copy_from_slice(sender_mac);
    // EtherType: ARP
    frame[12..14].copy_from_slice(&ETHERTYPE_ARP);

    // -- ARP payload (28 bytes) --
    // Hardware type: Ethernet
    frame[14..16].copy_from_slice(&ARP_HW_ETHERNET);
    // Protocol type: IPv4
    frame[16..18].copy_from_slice(&ARP_PROTO_IPV4);
    // Hardware address length: 6
    frame[18] = 6;
    // Protocol address length: 4
    frame[19] = 4;
    // Operation: REQUEST
    frame[20..22].copy_from_slice(&ARP_OP_REQUEST);
    // Sender hardware address
    frame[22..28].copy_from_slice(sender_mac);
    // Sender protocol address: 0.0.0.0 (probe)
    frame[28..32].copy_from_slice(&ZERO_IP);
    // Target hardware address: 00:00:00:00:00:00
    frame[32..38].copy_from_slice(&ZERO_MAC);
    // Target protocol address
    frame[38] = target_ip.0;
    frame[39] = target_ip.1;
    frame[40] = target_ip.2;
    frame[41] = target_ip.3;

    frame
}

/// Send a raw ARP frame on the given socket.
///
/// ## Linux Implementation
///
/// Uses `sendto(2)` with a `sockaddr_ll` structure:
///
/// ```text
/// sockaddr_ll {
///     sll_family   = AF_PACKET,
///     sll_protocol = htons(ETH_P_ARP),   // 0x0806
///     sll_ifindex  = <interface index>,
///     sll_halen    = 6,
///     sll_addr     = FF:FF:FF:FF:FF:FF,  // broadcast destination
/// }
/// ```
///
/// ## FreeBSD / macOS Implementation
///
/// Simply writes the frame to the BPF file descriptor. BPF handles the
/// link-layer encapsulation.
///
/// ## Parameters
/// - `arp_fd`    - The raw ARP socket file descriptor.
/// - `interface` - Interface name (needed to look up the interface index on Linux).
/// - `frame`     - The complete 42-byte ARP frame to send.
pub fn send_raw(_arp_fd: i32, _interface: &str, _frame: &[u8; ARP_FRAME_SIZE]) -> Result<(), String> {
    // TODO: Implement platform-specific ARP frame transmission.
    //
    // #[cfg(target_os = "linux")]
    // {
    //     let ifindex = crate::socket::get_interface_index(interface)?;
    //     let dest = nix::sys::socket::LinkAddr::new(
    //         ifindex as u32,
    //         &BROADCAST_MAC,
    //     );
    //     // Or construct sockaddr_ll manually:
    //     // let mut sll: libc::sockaddr_ll = unsafe { std::mem::zeroed() };
    //     // sll.sll_family = libc::AF_PACKET as u16;
    //     // sll.sll_protocol = (ETH_P_ARP as u16).to_be();
    //     // sll.sll_ifindex = ifindex as i32;
    //     // sll.sll_halen = 6;
    //     // sll.sll_addr[..6].copy_from_slice(&BROADCAST_MAC);
    //     //
    //     // nix::sys::socket::sendto(arp_fd, frame, &dest, MsgFlags::empty())
    //     //     .map_err(|e| format!("ARP sendto: {}", e))?;
    // }
    //
    // #[cfg(any(target_os = "freebsd", target_os = "macos"))]
    // {
    //     nix::unistd::write(arp_fd, frame)
    //         .map_err(|e| format!("BPF write: {}", e))?;
    // }
    //
    // Ok(())
    Err("not implemented".to_string())
}

/// Parse an incoming ARP frame and check if it is a reply relevant to our probe.
///
/// ## Parameters
/// - `frame`     - The raw received frame bytes.
/// - `target_ip` - The IPv4 address we are probing for.
///
/// ## Returns
/// - `Some((sender_mac, sender_ip))` if the frame is an ARP reply for our
///   target IP, indicating the address is already in use.
/// - `None` if the frame is not relevant (wrong opcode, wrong target, etc.).
///
/// ## Conflict Detection Logic (RFC 5227 Section 2.1.1)
///
/// A conflict is detected if we receive an ARP packet (request OR reply) where:
/// - The sender protocol address matches the IP we are probing, OR
/// - It is an ARP reply with the target protocol address matching our probe
///   and the sender protocol address is non-zero.
pub fn parse_reply(
    frame: &[u8],
    target_ip: (u8, u8, u8, u8),
) -> Option<([u8; 6], [u8; 4])> {
    // Minimum frame size check
    if frame.len() < ARP_FRAME_SIZE {
        return None;
    }

    // Verify EtherType is ARP
    if frame[12..14] != ETHERTYPE_ARP {
        return None;
    }

    // Verify it is an ARP reply or request (both can indicate conflict)
    let opcode = &frame[20..22];
    if opcode != ARP_OP_REPLY && opcode != ARP_OP_REQUEST {
        return None;
    }

    // Extract sender protocol address (bytes 28-31)
    let sender_proto = &frame[28..32];
    let target = [target_ip.0, target_ip.1, target_ip.2, target_ip.3];

    // Check if sender is claiming the IP we are probing
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

        // Ethernet header
        assert_eq!(&frame[0..6], &BROADCAST_MAC);
        assert_eq!(&frame[6..12], &mac);
        assert_eq!(&frame[12..14], &ETHERTYPE_ARP);

        // ARP header
        assert_eq!(&frame[14..16], &ARP_HW_ETHERNET);
        assert_eq!(&frame[16..18], &ARP_PROTO_IPV4);
        assert_eq!(frame[18], 6); // hw addr len
        assert_eq!(frame[19], 4); // proto addr len
        assert_eq!(&frame[20..22], &ARP_OP_REQUEST);

        // ARP addresses
        assert_eq!(&frame[22..28], &mac);           // sender MAC
        assert_eq!(&frame[28..32], &ZERO_IP);        // sender IP = 0.0.0.0
        assert_eq!(&frame[32..38], &ZERO_MAC);       // target MAC = zeros
        assert_eq!(&frame[38..42], &[192, 168, 1, 100]); // target IP
    }

    #[test]
    fn test_parse_reply_detects_conflict() {
        let mac = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55];
        let target_ip = (192, 168, 1, 100);

        // Build a fake ARP reply claiming 192.168.1.100
        let mut frame = [0u8; ARP_FRAME_SIZE];
        frame[12..14].copy_from_slice(&ETHERTYPE_ARP);
        frame[20..22].copy_from_slice(&ARP_OP_REPLY);
        frame[22..28].copy_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]); // sender MAC
        frame[28..32].copy_from_slice(&[192, 168, 1, 100]); // sender IP = our target

        let result = parse_reply(&frame, target_ip);
        assert!(result.is_some());
        let (conflict_mac, conflict_ip) = result.unwrap();
        assert_eq!(conflict_mac, [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]);
        assert_eq!(conflict_ip, [192, 168, 1, 100]);
    }

    #[test]
    fn test_parse_reply_ignores_different_ip() {
        let target_ip = (192, 168, 1, 100);

        // ARP reply for a different IP
        let mut frame = [0u8; ARP_FRAME_SIZE];
        frame[12..14].copy_from_slice(&ETHERTYPE_ARP);
        frame[20..22].copy_from_slice(&ARP_OP_REPLY);
        frame[28..32].copy_from_slice(&[192, 168, 1, 200]); // different IP

        assert!(parse_reply(&frame, target_ip).is_none());
    }

    #[test]
    fn test_parse_reply_rejects_short_frame() {
        let target_ip = (192, 168, 1, 100);
        let short_frame = [0u8; 20]; // too short
        assert!(parse_reply(&short_frame, target_ip).is_none());
    }

    #[test]
    fn test_parse_reply_detects_conflict_from_request() {
        // RFC 5227: conflict is also detected from ARP requests where the
        // sender protocol address matches our probe target.
        let target_ip = (10, 0, 0, 50);

        let mut frame = [0u8; ARP_FRAME_SIZE];
        frame[12..14].copy_from_slice(&ETHERTYPE_ARP);
        frame[20..22].copy_from_slice(&ARP_OP_REQUEST); // request, not reply
        frame[22..28].copy_from_slice(&[0x01, 0x02, 0x03, 0x04, 0x05, 0x06]);
        frame[28..32].copy_from_slice(&[10, 0, 0, 50]); // sender claims our target IP

        let result = parse_reply(&frame, target_ip);
        assert!(result.is_some());
    }
}
