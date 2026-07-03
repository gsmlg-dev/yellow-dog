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
//!   |<-- {:dhcp_rx, binary}           <-- poll thread (via enif_send)
//!   |<-- {:arp_rx, binary}            <-- poll thread (via enif_send)
//!   |<-- {:dhcp_socket_down, reason}  <-- poll thread exited abnormally
//!   |<-- {:arp_socket_down, reason}   <-- ARP degraded, DHCP still running
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
        dhcp_socket_down,
        arp_socket_down,
        poll_error,
        recv_error,
        socket_error,
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

/// Clean up on garbage collection (when Elixir code forgot to call `close/1`).
/// Uses the same wake-join-close teardown as `close/1`: the wake pipe forces
/// `poll(2)` to return immediately, so the join is bounded by roughly one
/// loop iteration and does not meaningfully block the scheduler.
impl Drop for DhcpSocketResource {
    fn drop(&mut self) {
        if let Ok(mut guard) = self.inner.lock() {
            if let Some(inner) = guard.take() {
                teardown(inner);
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
    /// Wake pipe read end, polled by the poll thread.
    wake_read: RawFd,
    /// Wake pipe write end, written by teardown to interrupt poll(2).
    wake_write: RawFd,
    /// Background poll thread handle.
    poll_handle: Option<std::thread::JoinHandle<()>>,
    /// Shared shutdown flag for the poll thread.
    shutdown: Arc<AtomicBool>,
    /// Interface MAC address (for ARP probe construction).
    mac: [u8; 6],
}

/// Tear down the socket state: signal shutdown, wake the poll thread out of
/// `poll(2)`, wait for it to exit, and only then close the file descriptors.
///
/// Closing only after the thread has exited eliminates the fd-reuse race
/// where the kernel hands a just-closed fd number to another socket while the
/// poll thread is still reading from it. Sends are serialized against
/// teardown by the resource mutex, so no other user of the fds can exist at
/// this point either.
fn teardown(mut inner: SocketInner) {
    inner.shutdown.store(true, Ordering::SeqCst);

    // Wake the poll thread immediately (it may otherwise sleep in poll(2)
    // for up to POLL_TIMEOUT_MS). The pipe is nonblocking; a full pipe or
    // already-exited thread makes the write a harmless no-op.
    let byte = 1u8;
    // SAFETY: writing one byte to the nonblocking wake pipe.
    unsafe {
        libc::write(
            inner.wake_write,
            &byte as *const u8 as *const libc::c_void,
            1,
        );
    }

    // The thread checks the shutdown flag right after poll(2) returns, so
    // this join completes within roughly one loop iteration.
    if let Some(handle) = inner.poll_handle.take() {
        let _ = handle.join();
    }

    // The poll thread has exited; nothing references these fds anymore.
    // SAFETY: closing fds owned by this resource exactly once.
    unsafe {
        libc::close(inner.udp_fd);
        if let Some(arp_fd) = inner.arp_fd {
            libc::close(arp_fd);
        }
        libc::close(inner.wake_read);
        libc::close(inner.wake_write);
    }
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
    let udp_fd = socket::create_udp_socket(&interface).map_err(|e| Error::Term(Box::new(e)))?;

    // 2. Create ARP socket (optional — DAD probes won't work without it).
    let arp_fd = socket::create_arp_socket(&interface).ok();

    // 3. Look up interface MAC (best effort — zero MAC if unavailable).
    let mac = socket::get_interface_mac(&interface).unwrap_or([0u8; 6]);

    // 4. Create the wake pipe used to interrupt the poll thread on shutdown.
    let (wake_read, wake_write) = match socket::create_wake_pipe() {
        Ok(pipe) => pipe,
        Err(e) => {
            // SAFETY: closing the fds created above before failing.
            unsafe {
                libc::close(udp_fd);
                if let Some(fd) = arp_fd {
                    libc::close(fd);
                }
            }
            return Err(Error::Term(Box::new(e)));
        }
    };

    // 5. Start the poll thread.
    let shutdown = Arc::new(AtomicBool::new(false));
    let poll_handle = poll::start(udp_fd, arp_fd, wake_read, owner_pid, shutdown.clone());

    let inner = SocketInner {
        interface,
        udp_fd,
        arp_fd,
        wake_read,
        wake_write,
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
    arp::send_raw(arp_fd, &inner.interface, &frame).map_err(|e| Error::Term(Box::new(e)))?;
    Ok(atoms::ok())
}

/// Close the socket and stop the poll thread.
///
/// Idempotent: calling close on an already-closed resource returns `:ok`.
/// Runs on DirtyIo so it can safely join the poll thread. See `teardown/1`
/// for the wake-join-close ordering that makes this race-free.
#[rustler::nif(schedule = "DirtyIo")]
fn close(resource: ResourceArc<DhcpSocketResource>) -> Atom {
    let mut guard = resource.inner.lock().unwrap();
    if let Some(inner) = guard.take() {
        teardown(inner);
    }
    atoms::ok()
}

/// Called when the NIF is loaded by the BEAM. Registers the resource type.
fn load(env: Env, _: Term) -> bool {
    rustler::resource!(DhcpSocketResource, env);
    true
}

rustler::init!("Elixir.Abyss.DhcpSocket.Native", load = load);
