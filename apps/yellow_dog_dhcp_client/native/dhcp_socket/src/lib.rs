//! # DHCP Client Socket NIF
//!
//! This NIF provides low-level socket operations required by the YellowDog DHCP
//! client that cannot be performed through Erlang's `:gen_udp`:
//!
//! - **Broadcast UDP sockets** bound to a specific network interface via
//!   `SO_BINDTODEVICE` (Linux) or `IP_BOUND_IF` (FreeBSD/macOS).
//! - **Raw ARP sockets** for Duplicate Address Detection (DAD) probes sent
//!   before accepting a DHCP lease.
//! - **Async receive** via a dedicated poll thread that delivers incoming
//!   packets to the owning Erlang process using `enif_send()`.
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
//!
//! ## NIF Scheduling
//!
//! All functions that perform I/O are scheduled on the `DirtyIo` scheduler to
//! avoid blocking the normal BEAM scheduler threads.

use rustler::{Atom, Binary, Env, Error, LocalPid, ResourceArc, Term};
use std::sync::Mutex;

mod arp;
mod poll;
mod socket;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        dhcp_rx,
        arp_rx,
        not_implemented,
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

/// The actual socket state.
///
/// When fully implemented this will contain:
/// - `udp_fd`: The raw file descriptor for the UDP socket bound to port 68.
/// - `arp_fd`: The raw file descriptor for the ARP socket (AF_PACKET on Linux,
///   BPF on FreeBSD).
/// - `poll_handle`: A `JoinHandle` for the background poll thread.
/// - `shutdown_flag`: An `Arc<AtomicBool>` shared with the poll thread to
///   signal graceful shutdown.
/// - `interface`: The name of the network interface this socket is bound to.
/// - `owner`: The PID of the Erlang process that receives incoming packets.
pub struct SocketInner {
    /// Network interface name (e.g. "eth0", "en0").
    interface: String,
    // Future fields:
    // udp_fd: RawFd,
    // arp_fd: RawFd,
    // poll_handle: Option<std::thread::JoinHandle<()>>,
    // shutdown: Arc<AtomicBool>,
    // owner: LocalPid,
}

// ---------------------------------------------------------------------------
// NIF Functions
// ---------------------------------------------------------------------------

/// Open a DHCP client socket bound to the given network interface.
///
/// ## Parameters
/// - `interface` - Network interface name (e.g. `"eth0"`).
/// - `owner_pid` - The Erlang process that will receive `{:dhcp_rx, binary}`
///   and `{:arp_rx, binary}` messages.
///
/// ## Intended Implementation
///
/// 1. **Create UDP socket** (`AF_INET`, `SOCK_DGRAM`):
///    - Set `SO_BROADCAST` to allow sending to 255.255.255.255.
///    - Set `SO_REUSEADDR` for multiple clients on one host (testing).
///    - On Linux: set `SO_BINDTODEVICE` to the interface name.
///    - On FreeBSD/macOS: set `IP_BOUND_IF` to the interface index.
///    - Bind to `0.0.0.0:68` (DHCP client port).
///
/// 2. **Create ARP socket** (for DAD probes):
///    - On Linux: `AF_PACKET`, `SOCK_RAW`, protocol `ETH_P_ARP`.
///      Bind to the interface via `sockaddr_ll`.
///    - On FreeBSD: Open `/dev/bpf`, attach to interface, set BPF filter
///      for ARP replies.
///
/// 3. **Start poll thread** (see `poll::run`):
///    - Uses `poll(2)` to watch both fds.
///    - On readable, reads the packet and sends it to `owner_pid` via
///      `enif_send()`.
///
/// 4. **Return** a `ResourceArc<DhcpSocketResource>` wrapping the state.
///
/// ## Returns
/// - `{:ok, resource}` on success.
/// - `{:error, reason}` on failure.
#[rustler::nif(schedule = "DirtyIo")]
fn open(_interface: String, _owner_pid: LocalPid) -> Result<ResourceArc<DhcpSocketResource>, Error> {
    // Stub: return :not_implemented until the real socket code is written.
    //
    // Real implementation will call:
    //   let udp_fd = socket::create_udp_socket(&interface)?;
    //   let arp_fd = socket::create_arp_socket(&interface)?;
    //   let (shutdown, handle) = poll::start(udp_fd, arp_fd, owner_pid, env);
    //   let inner = SocketInner { interface, udp_fd, arp_fd, poll_handle: Some(handle), shutdown, owner: owner_pid };
    //   Ok(ResourceArc::new(DhcpSocketResource { inner: Mutex::new(Some(inner)) }))
    Err(Error::Term(Box::new(atoms::not_implemented())))
}

/// Send a DHCP packet as a broadcast to 255.255.255.255:67.
///
/// ## Parameters
/// - `socket` - The socket resource returned by `open/2`.
/// - `packet` - Raw DHCP packet bytes (already fully encoded by Elixir).
///
/// ## Intended Implementation
///
/// 1. Lock the resource mutex and obtain the UDP fd.
/// 2. Use `sendto(2)` to send the packet to `255.255.255.255:67`.
/// 3. Return `:ok` on success or `{:error, reason}` on failure.
///
/// The destination address is always the limited broadcast address because
/// DHCP DISCOVER and REQUEST messages before lease acquisition must be
/// broadcast (the client has no IP yet).
#[rustler::nif(schedule = "DirtyIo")]
fn send_broadcast(
    _socket: ResourceArc<DhcpSocketResource>,
    _packet: Binary,
) -> Result<Atom, Error> {
    // Stub: return :not_implemented until the real socket code is written.
    //
    // Real implementation will call:
    //   let guard = socket.inner.lock().unwrap();
    //   let inner = guard.as_ref().ok_or(Error::Term(Box::new(atoms::error())))?;
    //   socket::sendto_broadcast(inner.udp_fd, packet.as_slice())?;
    //   Ok(atoms::ok())
    Err(Error::Term(Box::new(atoms::not_implemented())))
}

/// Send a DHCP packet as unicast to a specific server IP on port 67.
///
/// ## Parameters
/// - `socket`  - The socket resource returned by `open/2`.
/// - `dest_ip` - Destination IPv4 address as a 4-tuple `{a, b, c, d}`.
/// - `packet`  - Raw DHCP packet bytes.
///
/// ## Intended Implementation
///
/// Used for DHCP RENEW/REBIND where the client already has an IP and knows
/// the server address. Sends via `sendto(2)` to `dest_ip:67`.
#[rustler::nif(schedule = "DirtyIo")]
fn send_unicast(
    _socket: ResourceArc<DhcpSocketResource>,
    _dest_ip: (u8, u8, u8, u8),
    _packet: Binary,
) -> Result<Atom, Error> {
    // Stub: return :not_implemented until the real socket code is written.
    //
    // Real implementation will call:
    //   let guard = socket.inner.lock().unwrap();
    //   let inner = guard.as_ref().ok_or(...)?;
    //   let addr = std::net::Ipv4Addr::new(dest_ip.0, dest_ip.1, dest_ip.2, dest_ip.3);
    //   socket::sendto_unicast(inner.udp_fd, &addr, packet.as_slice())?;
    //   Ok(atoms::ok())
    Err(Error::Term(Box::new(atoms::not_implemented())))
}

/// Send an ARP probe for Duplicate Address Detection (DAD).
///
/// ## Parameters
/// - `socket`    - The socket resource returned by `open/2`.
/// - `target_ip` - The IPv4 address to probe, as a 4-tuple `{a, b, c, d}`.
///
/// ## Intended Implementation
///
/// Constructs and sends an ARP REQUEST with:
/// - Sender protocol address: `0.0.0.0` (indicates a probe, not a claim).
/// - Sender hardware address: the interface's MAC.
/// - Target protocol address: the IP being probed.
/// - Target hardware address: `00:00:00:00:00:00`.
///
/// Per RFC 5227, the client sends ARP probes before using a newly offered IP.
/// If a reply is received (delivered as `{:arp_rx, binary}` by the poll
/// thread), the address is already in use and the client must DECLINE.
#[rustler::nif(schedule = "DirtyIo")]
fn send_arp_probe(
    _socket: ResourceArc<DhcpSocketResource>,
    _target_ip: (u8, u8, u8, u8),
) -> Result<Atom, Error> {
    // Stub: return :not_implemented until the real socket code is written.
    //
    // Real implementation will call:
    //   let guard = socket.inner.lock().unwrap();
    //   let inner = guard.as_ref().ok_or(...)?;
    //   let mac = socket::get_interface_mac(&inner.interface)?;
    //   let probe = arp::build_probe(&mac, target_ip);
    //   arp::send_raw(inner.arp_fd, &inner.interface, &probe)?;
    //   Ok(atoms::ok())
    Err(Error::Term(Box::new(atoms::not_implemented())))
}

/// Close the socket and stop the poll thread.
///
/// ## Intended Implementation
///
/// 1. Lock the mutex and take the inner state (`Option::take`), leaving `None`.
/// 2. Set the shutdown flag (`AtomicBool`) to `true`.
/// 3. Join the poll thread to ensure it has exited.
/// 4. Close both file descriptors.
/// 5. Return `:ok`.
///
/// This is idempotent: calling `close` on an already-closed resource is a
/// no-op and returns `:ok`.
#[rustler::nif(schedule = "DirtyIo")]
fn close(socket: ResourceArc<DhcpSocketResource>) -> Atom {
    // Stub: take the inner state (if any) and return :ok.
    //
    // Real implementation will additionally:
    //   - Set shutdown.store(true, Ordering::SeqCst)
    //   - handle.join().ok()
    //   - nix::unistd::close(inner.udp_fd).ok()
    //   - nix::unistd::close(inner.arp_fd).ok()
    let mut guard = socket.inner.lock().unwrap();
    let _ = guard.take();
    atoms::ok()
}

/// Called when the NIF is loaded by the BEAM.
///
/// Registers the `DhcpSocketResource` type so that Erlang can track and
/// garbage-collect our socket handles.
fn load(env: Env, _: Term) -> bool {
    rustler::resource!(DhcpSocketResource, env);
    true
}

rustler::init!(
    "Elixir.YellowDog.DhcpClient.DhcpSocket.Native",
    [open, send_broadcast, send_unicast, send_arp_probe, close],
    load = load
);
