// cdylib NIF: pub items used across modules are not "dead code"
#![allow(dead_code)]

//! # DHCP Client Socket NIF
//!
//! Provides low-level socket operations for the YellowDog DHCP client:
//!
//! - **Broadcast UDP sockets** bound to a specific network interface via
//!   `SO_BINDTODEVICE` (Linux) or `IP_BOUND_IF` (FreeBSD/macOS).
//! - **Raw ARP sockets** for Duplicate Address Detection (DAD) probes.
//! - **Async receive** via a dedicated poll thread delivering packets to the
//!   owning Erlang process using `enif_send()`.
//!
//! ## Architecture
//!
//! ```text
//! Elixir process (owner)
//!   |
//!   |-- open(interface, self())  --> DhcpSocketResource
//!   |                                  |
//!   |                                  +-- UDP socket fd (port 68, broadcast)
//!   |                                  +-- ARP socket fd (raw, ETH_P_ARP)
//!   |                                  +-- poll thread handle
//!   |
//!   |<-- {:dhcp_rx, binary}     <-- poll thread (via enif_send)
//!   |<-- {:arp_rx, binary}      <-- poll thread (via enif_send)
//!   |
//!   |-- send_broadcast(res, pkt)
//!   |-- send_unicast(res, ip, pkt)
//!   |-- send_arp_probe(res, ip)
//!   |-- close(res)
//! ```

use rustler::{Atom, Binary, Env, Error, LocalPid, ResourceArc, Term};
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

mod arp;
mod poll;
mod socket;

pub(crate) mod atoms {
    rustler::atoms! {
        ok,
        error,
        dhcp_rx,
        arp_rx,
    }
}

/// Resource wrapping the socket state.
///
/// Held by Elixir as an opaque reference. The inner state is protected by a
/// `Mutex` so that the poll thread and NIF calls can coordinate safely. When
/// `close/1` is called the inner value is taken (`Option::take`) which signals
/// the poll thread to exit and closes the file descriptors.
pub struct DhcpSocketResource {
    inner: Mutex<Option<SocketInner>>,
}

/// Clean up on garbage collection. Sets the shutdown flag and closes fds.
/// Does NOT join the poll thread (to avoid blocking a BEAM scheduler).
/// The poll thread will exit when it sees shutdown=true or gets POLLNVAL.
impl Drop for DhcpSocketResource {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.inner.lock() {
            if let Some(mut inner) = guard.take() {
                inner.shutdown.store(true, Ordering::SeqCst);
                unsafe { libc::close(inner.udp_fd); }
                if let Some(arp_fd) = inner.arp_fd {
                    unsafe { libc::close(arp_fd); }
                }
                // Detach the poll thread — it will exit on its own.
                drop(inner.poll_handle.take());
            }
        }
    }
}

/// The actual socket state owned by the resource.
struct SocketInner {
    /// Network interface name (e.g. "eth0").
    interface: String,
    /// UDP socket fd (port 68, SO_BROADCAST, interface-bound).
    udp_fd: RawFd,
    /// ARP socket fd (AF_PACKET on Linux). None if creation failed.
    arp_fd: Option<RawFd>,
    /// Background poll thread handle.
    poll_handle: Option<std::thread::JoinHandle<()>>,
    /// Shared shutdown flag for the poll thread.
    shutdown: Arc<AtomicBool>,
    /// Interface MAC address (for ARP probe construction).
    mac: [u8; 6],
}

// SAFETY: SocketInner is Send because all fields are Send:
// - String, RawFd (i32), Option<RawFd>, Arc<AtomicBool>: Send
// - JoinHandle<()>: Send
// - [u8; 6]: Send
// DhcpSocketResource wraps Mutex<Option<SocketInner>> which is Send+Sync.
unsafe impl Send for DhcpSocketResource {}
unsafe impl Sync for DhcpSocketResource {}

// ---------------------------------------------------------------------------
// NIF Functions
// ---------------------------------------------------------------------------

/// Open a DHCP client socket bound to the given network interface.
///
/// Creates a UDP broadcast socket (port 68), optionally an ARP socket for DAD,
/// and starts a background poll thread that delivers received packets to
/// `owner_pid` as `{:dhcp_rx, binary}` and `{:arp_rx, binary}` messages.
#[rustler::nif(schedule = "DirtyIo")]
fn open(interface: String, owner_pid: LocalPid) -> Result<ResourceArc<DhcpSocketResource>, Error> {
    // 1. Create UDP socket (required — failure is fatal).
    let udp_fd = socket::create_udp_socket(&interface)
        .map_err(|e| Error::Term(Box::new(e)))?;

    // 2. Create ARP socket (optional — DAD probes won't work without it).
    let arp_fd = socket::create_arp_socket(&interface).ok();

    // 3. Look up interface MAC (best effort — zero MAC if unavailable).
    let mac = socket::get_interface_mac(&interface).unwrap_or([0u8; 6]);

    // 4. Start the poll thread.
    let shutdown = Arc::new(AtomicBool::new(false));
    let poll_handle = poll::start(udp_fd, arp_fd, owner_pid, shutdown.clone());

    let inner = SocketInner {
        interface,
        udp_fd,
        arp_fd,
        poll_handle: Some(poll_handle),
        shutdown,
        mac,
    };

    Ok(ResourceArc::new(DhcpSocketResource {
        inner: Mutex::new(Some(inner)),
    }))
}

/// Send a DHCP packet as a broadcast to 255.255.255.255:67.
#[rustler::nif(schedule = "DirtyIo")]
fn send_broadcast(
    resource: ResourceArc<DhcpSocketResource>,
    packet: Binary,
) -> Result<Atom, Error> {
    let guard = resource.inner.lock().unwrap();
    let inner = guard
        .as_ref()
        .ok_or_else(|| Error::Term(Box::new("socket closed".to_string())))?;
    socket::sendto_broadcast(inner.udp_fd, packet.as_slice())
        .map_err(|e| Error::Term(Box::new(e)))?;
    Ok(atoms::ok())
}

/// Send a DHCP packet as unicast to a specific server IP on port 67.
#[rustler::nif(schedule = "DirtyIo")]
fn send_unicast(
    resource: ResourceArc<DhcpSocketResource>,
    dest_ip: (u8, u8, u8, u8),
    packet: Binary,
) -> Result<Atom, Error> {
    let guard = resource.inner.lock().unwrap();
    let inner = guard
        .as_ref()
        .ok_or_else(|| Error::Term(Box::new("socket closed".to_string())))?;
    let addr = std::net::Ipv4Addr::new(dest_ip.0, dest_ip.1, dest_ip.2, dest_ip.3);
    socket::sendto_unicast(inner.udp_fd, &addr, packet.as_slice())
        .map_err(|e| Error::Term(Box::new(e)))?;
    Ok(atoms::ok())
}

/// Send an ARP probe for Duplicate Address Detection (DAD).
///
/// Constructs an ARP REQUEST with sender IP 0.0.0.0 (probe) and sends it
/// on the raw ARP socket. If a reply is received by the poll thread
/// (`{:arp_rx, binary}`), the address is already in use.
#[rustler::nif(schedule = "DirtyIo")]
fn send_arp_probe(
    resource: ResourceArc<DhcpSocketResource>,
    target_ip: (u8, u8, u8, u8),
) -> Result<Atom, Error> {
    let guard = resource.inner.lock().unwrap();
    let inner = guard
        .as_ref()
        .ok_or_else(|| Error::Term(Box::new("socket closed".to_string())))?;
    let arp_fd = inner
        .arp_fd
        .ok_or_else(|| Error::Term(Box::new("ARP socket not available".to_string())))?;
    let frame = arp::build_probe(&inner.mac, target_ip);
    arp::send_raw(arp_fd, &inner.interface, &frame)
        .map_err(|e| Error::Term(Box::new(e)))?;
    Ok(atoms::ok())
}

/// Close the socket and stop the poll thread.
///
/// Idempotent: calling close on an already-closed resource returns `:ok`.
/// Runs on DirtyIo so it can safely join the poll thread.
#[rustler::nif(schedule = "DirtyIo")]
fn close(resource: ResourceArc<DhcpSocketResource>) -> Atom {
    let mut guard = resource.inner.lock().unwrap();
    if let Some(mut inner) = guard.take() {
        // Signal the poll thread to exit.
        inner.shutdown.store(true, Ordering::SeqCst);

        // Close fds to unblock any blocking poll/recv.
        unsafe { libc::close(inner.udp_fd); }
        if let Some(arp_fd) = inner.arp_fd {
            unsafe { libc::close(arp_fd); }
        }

        // Wait for the poll thread to finish (safe on DirtyIo scheduler).
        if let Some(handle) = inner.poll_handle.take() {
            let _ = handle.join();
        }
    }
    atoms::ok()
}

/// Called when the NIF is loaded by the BEAM. Registers the resource type.
fn load(env: Env, _: Term) -> bool {
    rustler::resource!(DhcpSocketResource, env);
    true
}

rustler::init!(
    "Elixir.YellowDog.DhcpClient.DhcpSocket.Native",
    load = load
);
