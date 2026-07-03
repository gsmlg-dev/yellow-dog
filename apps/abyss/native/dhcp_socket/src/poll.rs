//! # Poll Thread for Async Packet Reception
//!
//! A dedicated OS thread monitors the UDP and ARP sockets using `poll(2)`.
//! When data arrives, it reads the packet and delivers it to the owning Erlang
//! process via `enif_send()` (through rustler's `OwnedEnv`).
//!
//! ## Message Format
//!
//! - **DHCP**: `{:dhcp_rx, binary}` — raw UDP payload (kernel strips headers).
//! - **ARP**: `{:arp_rx, binary}` — full Ethernet frame (Linux AF_PACKET).
//! - **DHCP failure**: `{:dhcp_socket_down, :poll_error | :recv_error |
//!   :socket_error}` — the poll thread exited abnormally; the socket is no
//!   longer receiving and the owner should close and reopen it.
//! - **ARP failure**: `{:arp_socket_down, :recv_error | :socket_error}` —
//!   the ARP socket failed; DAD probes are unavailable but DHCP reception
//!   continues unaffected.
//!
//! No message is sent when the thread exits because `close/1` was called or
//! the owner process died.
//!
//! ## Why a Dedicated Thread
//!
//! `poll(2)` blocks indefinitely. Dirty schedulers have a limited pool and
//! should not be monopolized. A dedicated thread wakes immediately on packet
//! arrival and checks a shutdown flag on each timeout.
//!
//! ## Shutdown Protocol
//!
//! The thread also polls a wake pipe. `close/1` (and resource `Drop`) sets
//! the shutdown flag, writes one byte to the pipe to force `poll(2)` to
//! return immediately, joins the thread, and only then closes the file
//! descriptors. The thread checks the flag directly after `poll(2)` returns
//! and never touches the sockets afterwards, so an fd can never be closed
//! (and its number reused by the kernel) while the thread is still using it.

use rustler::{Atom, Encoder, LocalPid, NewBinary, OwnedEnv};
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

/// Maximum receive buffer size (4 KiB covers any DHCP packet + ARP frames).
pub const MAX_PACKET_SIZE: usize = 4096;

/// Poll timeout in milliseconds. The thread checks the shutdown flag at least
/// this often even if the wake pipe write is somehow lost.
pub const POLL_TIMEOUT_MS: i32 = 1000;

/// Start the poll thread for the given socket file descriptors.
///
/// `wake_fd` is the read end of the wake pipe used by the shutdown protocol.
/// Returns the `JoinHandle` for the spawned thread. The caller must set the
/// `shutdown` flag and write to the wake pipe before joining.
pub fn start(
    udp_fd: RawFd,
    arp_fd: Option<RawFd>,
    wake_fd: RawFd,
    owner_pid: LocalPid,
    shutdown: Arc<AtomicBool>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        run(udp_fd, arp_fd, wake_fd, owner_pid, shutdown);
    })
}

/// Outcome of a single `recv(2)` attempt.
enum RecvOutcome {
    Packet(usize),
    Retry,
    Fatal,
}

/// The main poll loop. Runs on a dedicated OS thread until shutdown is
/// signalled, a fatal socket error occurs, or the owner process dies. The
/// thread never closes the socket fds; that is done by the NIF after joining.
fn run(
    udp_fd: RawFd,
    mut arp_fd: Option<RawFd>,
    wake_fd: RawFd,
    owner_pid: LocalPid,
    shutdown: Arc<AtomicBool>,
) {
    let mut buf = [0u8; MAX_PACKET_SIZE];
    let mut msg_env = OwnedEnv::new();

    loop {
        if shutdown.load(Ordering::SeqCst) {
            return;
        }

        // poll(2) ignores entries with a negative fd, so the disabled ARP
        // slot simply never fires.
        let mut fds = [
            libc::pollfd {
                fd: udp_fd,
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: arp_fd.unwrap_or(-1),
                events: libc::POLLIN,
                revents: 0,
            },
            libc::pollfd {
                fd: wake_fd,
                events: libc::POLLIN,
                revents: 0,
            },
        ];

        // SAFETY: poll(2) with a valid pollfd array and timeout.
        let ret = unsafe { libc::poll(fds.as_mut_ptr(), 3, POLL_TIMEOUT_MS) };

        // Checked immediately after poll() returns: once the shutdown flag is
        // set (always together with a wake pipe write), the thread provably
        // never touches the sockets again.
        if shutdown.load(Ordering::SeqCst) {
            return;
        }

        if ret < 0 {
            let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            if errno == libc::EINTR {
                continue;
            }
            // Fatal poll error (ENOMEM, etc.) — tell the owner and exit.
            notify(
                &mut msg_env,
                &owner_pid,
                crate::atoms::dhcp_socket_down(),
                crate::atoms::poll_error(),
            );
            return;
        }

        if ret == 0 {
            continue; // Timeout, loop back to check the shutdown flag.
        }

        // Wake pipe. A byte is only ever written together with shutdown=true
        // (handled above); drain defensively so a stray byte cannot spin the
        // loop.
        if fds[2].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            return; // Wake pipe gone — the resource is being torn down.
        }
        if fds[2].revents & libc::POLLIN != 0 {
            let mut drain = [0u8; 8];
            // SAFETY: read from the nonblocking wake pipe into a local buffer.
            unsafe {
                libc::read(
                    wake_fd,
                    drain.as_mut_ptr() as *mut libc::c_void,
                    drain.len(),
                );
            }
            continue;
        }

        // UDP socket (DHCP). Errors here are fatal for the socket.
        if fds[0].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            notify(
                &mut msg_env,
                &owner_pid,
                crate::atoms::dhcp_socket_down(),
                crate::atoms::socket_error(),
            );
            return;
        }
        if fds[0].revents & libc::POLLIN != 0 {
            match recv_packet(udp_fd, &mut buf) {
                RecvOutcome::Packet(len) => {
                    if !send_packet(
                        &mut msg_env,
                        &owner_pid,
                        crate::atoms::dhcp_rx(),
                        &buf[..len],
                    ) {
                        return; // Owner process died.
                    }
                }
                RecvOutcome::Retry => {}
                RecvOutcome::Fatal => {
                    notify(
                        &mut msg_env,
                        &owner_pid,
                        crate::atoms::dhcp_socket_down(),
                        crate::atoms::recv_error(),
                    );
                    return;
                }
            }
        }

        // ARP socket. Errors only disable DAD; DHCP reception keeps running.
        if let Some(afd) = arp_fd {
            if fds[1].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                notify(
                    &mut msg_env,
                    &owner_pid,
                    crate::atoms::arp_socket_down(),
                    crate::atoms::socket_error(),
                );
                arp_fd = None;
            } else if fds[1].revents & libc::POLLIN != 0 {
                match recv_packet(afd, &mut buf) {
                    RecvOutcome::Packet(len) => {
                        if !send_packet(
                            &mut msg_env,
                            &owner_pid,
                            crate::atoms::arp_rx(),
                            &buf[..len],
                        ) {
                            return; // Owner process died.
                        }
                    }
                    RecvOutcome::Retry => {}
                    RecvOutcome::Fatal => {
                        notify(
                            &mut msg_env,
                            &owner_pid,
                            crate::atoms::arp_socket_down(),
                            crate::atoms::recv_error(),
                        );
                        arp_fd = None;
                    }
                }
            }
        }
    }
}

fn recv_packet(fd: RawFd, buf: &mut [u8]) -> RecvOutcome {
    // SAFETY: recv from a valid fd into our buffer.
    let n = unsafe { libc::recv(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len(), 0) };

    if n > 0 {
        RecvOutcome::Packet(n as usize)
    } else if n == 0 {
        // Zero-length datagram — nothing to deliver.
        RecvOutcome::Retry
    } else {
        let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
        if errno == libc::EINTR || errno == libc::EAGAIN || errno == libc::EWOULDBLOCK {
            RecvOutcome::Retry
        } else {
            RecvOutcome::Fatal
        }
    }
}

/// Deliver a received packet as `{tag, binary}`. Returns false if the owner
/// process is no longer alive.
fn send_packet(env: &mut OwnedEnv, owner: &LocalPid, tag: Atom, data: &[u8]) -> bool {
    env.send_and_clear(owner, |env| {
        let mut bin = NewBinary::new(env, data.len());
        bin.as_mut_slice().copy_from_slice(data);
        let bin_term: rustler::Binary = bin.into();
        (tag, bin_term).encode(env)
    })
    .is_ok()
}

/// Deliver a `{tag, reason}` status message. Send errors (owner already dead)
/// are ignored — the thread is exiting either way.
fn notify(env: &mut OwnedEnv, owner: &LocalPid, tag: Atom, reason: Atom) {
    let _ = env.send_and_clear(owner, |env| (tag, reason).encode(env));
}
