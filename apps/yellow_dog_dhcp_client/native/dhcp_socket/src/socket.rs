//! # Platform-Specific Socket Creation
//!
//! Creates UDP broadcast sockets and raw ARP sockets for the DHCP client.
//!
//! ## Platform Differences
//!
//! | Feature               | Linux                    | FreeBSD / macOS           |
//! |-----------------------|--------------------------|---------------------------|
//! | Interface binding     | `SO_BINDTODEVICE`        | `IP_BOUND_IF` (ifindex)   |
//! | ARP socket            | `AF_PACKET` + `SOCK_RAW` | BPF (`/dev/bpfN`)         |
//! | Interface MAC lookup  | `SIOCGIFHWADDR` ioctl    | `getifaddrs` + `AF_LINK`  |

use std::net::{Ipv4Addr, SocketAddrV4};
use std::os::unix::io::{AsRawFd, IntoRawFd, RawFd};

use socket2::{Domain, Protocol, Socket, Type};

// ============================================================================
// UDP Socket
// ============================================================================

/// Create a UDP broadcast socket bound to port 68 on the specified interface.
///
/// Sets `SO_REUSEADDR`, `SO_BROADCAST`, and binds to the interface via the
/// platform-specific mechanism. Returns the raw file descriptor.
pub fn create_udp_socket(interface: &str) -> Result<RawFd, String> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))
        .map_err(|e| format!("socket(AF_INET, SOCK_DGRAM): {e}"))?;

    socket
        .set_reuse_address(true)
        .map_err(|e| format!("SO_REUSEADDR: {e}"))?;

    socket
        .set_broadcast(true)
        .map_err(|e| format!("SO_BROADCAST: {e}"))?;

    bind_to_interface(socket.as_raw_fd(), interface)?;

    let addr = SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 68);
    socket
        .bind(&addr.into())
        .map_err(|e| format!("bind(0.0.0.0:68): {e}"))?;

    Ok(socket.into_raw_fd())
}

/// Bind a socket to a specific network interface (Linux: SO_BINDTODEVICE).
#[cfg(target_os = "linux")]
fn bind_to_interface(fd: RawFd, interface: &str) -> Result<(), String> {
    let c_iface = std::ffi::CString::new(interface)
        .map_err(|_| format!("invalid interface name: {interface}"))?;
    // SAFETY: Setting SO_BINDTODEVICE with a valid CString interface name.
    let ret = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_BINDTODEVICE,
            c_iface.as_ptr() as *const libc::c_void,
            c_iface.to_bytes_with_nul().len() as libc::socklen_t,
        )
    };
    if ret < 0 {
        return Err(format!(
            "SO_BINDTODEVICE({interface}): {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

/// Bind a socket to a specific network interface (FreeBSD/macOS: IP_BOUND_IF).
#[cfg(any(target_os = "freebsd", target_os = "macos"))]
fn bind_to_interface(fd: RawFd, interface: &str) -> Result<(), String> {
    let c_iface = std::ffi::CString::new(interface)
        .map_err(|_| format!("invalid interface name: {interface}"))?;
    let ifindex = unsafe { libc::if_nametoindex(c_iface.as_ptr()) };
    if ifindex == 0 {
        return Err(format!(
            "if_nametoindex({interface}): {}",
            std::io::Error::last_os_error()
        ));
    }
    // SAFETY: Setting IP_BOUND_IF with a valid interface index.
    let ret = unsafe {
        libc::setsockopt(
            fd,
            libc::IPPROTO_IP,
            libc::IP_BOUND_IF,
            &ifindex as *const _ as *const libc::c_void,
            std::mem::size_of_val(&ifindex) as libc::socklen_t,
        )
    };
    if ret < 0 {
        return Err(format!(
            "IP_BOUND_IF({interface}): {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

#[cfg(not(any(target_os = "linux", target_os = "freebsd", target_os = "macos")))]
fn bind_to_interface(_fd: RawFd, interface: &str) -> Result<(), String> {
    Err(format!(
        "interface binding not supported on this platform for {interface}"
    ))
}

// ============================================================================
// ARP Socket
// ============================================================================

/// Create a raw ARP socket bound to the given interface (Linux: AF_PACKET).
#[cfg(target_os = "linux")]
pub fn create_arp_socket(interface: &str) -> Result<RawFd, String> {
    // SAFETY: Creating a raw packet socket for ARP. Requires CAP_NET_RAW.
    let fd = unsafe {
        libc::socket(
            libc::AF_PACKET,
            libc::SOCK_RAW | libc::SOCK_CLOEXEC,
            (libc::ETH_P_ARP as u16).to_be() as i32,
        )
    };
    if fd < 0 {
        return Err(format!(
            "socket(AF_PACKET, SOCK_RAW, ETH_P_ARP): {}",
            std::io::Error::last_os_error()
        ));
    }

    let ifindex = get_interface_index(interface).map_err(|e| {
        unsafe { libc::close(fd); }
        e
    })?;

    let mut sll: libc::sockaddr_ll = unsafe { std::mem::zeroed() };
    sll.sll_family = libc::AF_PACKET as u16;
    sll.sll_protocol = (libc::ETH_P_ARP as u16).to_be();
    sll.sll_ifindex = ifindex as i32;

    // SAFETY: Binding the AF_PACKET socket to the interface.
    let ret = unsafe {
        libc::bind(
            fd,
            &sll as *const libc::sockaddr_ll as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_ll>() as libc::socklen_t,
        )
    };
    if ret < 0 {
        let err = std::io::Error::last_os_error();
        unsafe { libc::close(fd); }
        return Err(format!("bind(AF_PACKET, {interface}): {err}"));
    }

    Ok(fd)
}

/// ARP socket creation placeholder for non-Linux platforms (BPF not yet implemented).
#[cfg(not(target_os = "linux"))]
pub fn create_arp_socket(_interface: &str) -> Result<RawFd, String> {
    Err("ARP socket: BPF not yet implemented on this platform".to_string())
}

// ============================================================================
// Send Helpers
// ============================================================================

/// Send a UDP packet to 255.255.255.255:67 (DHCP server broadcast).
pub fn sendto_broadcast(fd: RawFd, packet: &[u8]) -> Result<(), String> {
    let dest = libc::sockaddr_in {
        sin_family: libc::AF_INET as libc::sa_family_t,
        sin_port: 67u16.to_be(),
        sin_addr: libc::in_addr {
            s_addr: u32::from_ne_bytes([255, 255, 255, 255]),
        },
        sin_zero: [0; 8],
    };

    // SAFETY: Sending UDP broadcast. Socket must have SO_BROADCAST set.
    let ret = unsafe {
        libc::sendto(
            fd,
            packet.as_ptr() as *const libc::c_void,
            packet.len(),
            0,
            &dest as *const libc::sockaddr_in as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
        )
    };
    if ret < 0 {
        return Err(format!(
            "sendto(255.255.255.255:67): {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

/// Send a UDP packet to a specific DHCP server (unicast) on port 67.
pub fn sendto_unicast(fd: RawFd, dest: &Ipv4Addr, packet: &[u8]) -> Result<(), String> {
    let octets = dest.octets();
    let dest_addr = libc::sockaddr_in {
        sin_family: libc::AF_INET as libc::sa_family_t,
        sin_port: 67u16.to_be(),
        sin_addr: libc::in_addr {
            s_addr: u32::from_ne_bytes(octets),
        },
        sin_zero: [0; 8],
    };

    // SAFETY: Sending unicast UDP to a specific server.
    let ret = unsafe {
        libc::sendto(
            fd,
            packet.as_ptr() as *const libc::c_void,
            packet.len(),
            0,
            &dest_addr as *const libc::sockaddr_in as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
        )
    };
    if ret < 0 {
        return Err(format!(
            "sendto({dest}:67): {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(())
}

// ============================================================================
// Interface Utilities
// ============================================================================

/// Get the OS index of a network interface by name.
pub fn get_interface_index(interface: &str) -> Result<u32, String> {
    let c_name = std::ffi::CString::new(interface)
        .map_err(|_| format!("invalid interface name: {interface}"))?;
    let idx = unsafe { libc::if_nametoindex(c_name.as_ptr()) };
    if idx == 0 {
        return Err(format!(
            "if_nametoindex({interface}): {}",
            std::io::Error::last_os_error()
        ));
    }
    Ok(idx)
}

/// Get the hardware (MAC) address of a network interface.
///
/// Linux: Uses `SIOCGIFHWADDR` ioctl on a temporary socket.
#[cfg(target_os = "linux")]
pub fn get_interface_mac(interface: &str) -> Result<[u8; 6], String> {
    // SAFETY: Creating a temporary DGRAM socket solely for the ioctl call.
    let sock = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM, 0) };
    if sock < 0 {
        return Err(format!(
            "socket for ioctl: {}",
            std::io::Error::last_os_error()
        ));
    }

    let mut ifr: libc::ifreq = unsafe { std::mem::zeroed() };
    let iface_bytes = interface.as_bytes();
    if iface_bytes.len() >= libc::IFNAMSIZ {
        unsafe { libc::close(sock); }
        return Err(format!("interface name too long: {interface}"));
    }

    // Copy interface name into the ifreq struct.
    // SAFETY: iface_bytes.len() < IFNAMSIZ, so this won't overflow.
    unsafe {
        std::ptr::copy_nonoverlapping(
            iface_bytes.as_ptr(),
            ifr.ifr_name.as_mut_ptr() as *mut u8,
            iface_bytes.len(),
        );
    }

    // SAFETY: ioctl with SIOCGIFHWADDR reads the interface's MAC address.
    let ret = unsafe { libc::ioctl(sock, libc::SIOCGIFHWADDR, &mut ifr as *mut libc::ifreq) };
    unsafe { libc::close(sock); }

    if ret < 0 {
        return Err(format!(
            "SIOCGIFHWADDR({interface}): {}",
            std::io::Error::last_os_error()
        ));
    }

    let mut mac = [0u8; 6];
    // SAFETY: SIOCGIFHWADDR succeeded; ifru_hwaddr.sa_data contains the MAC.
    unsafe {
        let data = ifr.ifr_ifru.ifru_hwaddr.sa_data;
        for (i, byte) in mac.iter_mut().enumerate() {
            *byte = data[i] as u8;
        }
    }
    Ok(mac)
}

/// MAC address lookup placeholder for non-Linux platforms.
#[cfg(not(target_os = "linux"))]
pub fn get_interface_mac(_interface: &str) -> Result<[u8; 6], String> {
    Err("MAC address lookup: getifaddrs not yet implemented on this platform".to_string())
}
