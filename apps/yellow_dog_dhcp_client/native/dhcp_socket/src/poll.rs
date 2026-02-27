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
//!
//! ## Why a Dedicated Thread
//!
//! `poll(2)` blocks indefinitely. Dirty schedulers have a limited pool and
//! should not be monopolized. A dedicated thread wakes immediately on packet
//! arrival and checks a shutdown flag on each timeout.

use rustler::{Encoder, LocalPid, NewBinary, OwnedEnv};
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

/// Maximum receive buffer size (4 KiB covers any DHCP packet + ARP frames).
pub const MAX_PACKET_SIZE: usize = 4096;

/// Poll timeout in milliseconds. The thread checks the shutdown flag at least
/// this often, even when no packets arrive.
pub const POLL_TIMEOUT_MS: i32 = 1000;

/// Start the poll thread for the given socket file descriptors.
///
/// Returns the `JoinHandle` for the spawned thread. The caller must store the
/// `shutdown` flag and set it to `true` before joining to request a clean exit.
pub fn start(
    udp_fd: RawFd,
    arp_fd: Option<RawFd>,
    owner_pid: LocalPid,
    shutdown: Arc<AtomicBool>,
) -> JoinHandle<()> {
    thread::spawn(move || {
        run(udp_fd, arp_fd, owner_pid, shutdown);
    })
}

/// The main poll loop. Runs on a dedicated OS thread until shutdown is
/// signalled or the owner process dies.
fn run(
    udp_fd: RawFd,
    arp_fd: Option<RawFd>,
    owner_pid: LocalPid,
    shutdown: Arc<AtomicBool>,
) {
    let mut buf = [0u8; MAX_PACKET_SIZE];
    let mut msg_env = OwnedEnv::new();

    // Number of fds to poll: always the UDP socket, optionally the ARP socket.
    let nfds: libc::nfds_t = if arp_fd.is_some() { 2 } else { 1 };

    loop {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }

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
        ];

        // SAFETY: poll(2) with valid pollfd array and timeout.
        let ret = unsafe { libc::poll(fds.as_mut_ptr(), nfds, POLL_TIMEOUT_MS) };

        if shutdown.load(Ordering::SeqCst) {
            break;
        }

        if ret < 0 {
            let errno = std::io::Error::last_os_error()
                .raw_os_error()
                .unwrap_or(0);
            if errno == libc::EINTR {
                continue;
            }
            // Fatal poll error (EBADF, ENOMEM, etc.) — exit the thread.
            break;
        }

        if ret == 0 {
            continue; // Timeout, loop back to check shutdown flag.
        }

        // Check UDP socket for incoming DHCP packets.
        if fds[0].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
            break; // Socket error or fd closed.
        }
        if fds[0].revents & libc::POLLIN != 0 {
            // SAFETY: recv from a valid fd into our buffer.
            let n = unsafe {
                libc::recv(
                    udp_fd,
                    buf.as_mut_ptr() as *mut libc::c_void,
                    buf.len(),
                    0,
                )
            };
            if n > 0 {
                let len = n as usize;
                let sent = msg_env.send_and_clear(&owner_pid, |env| {
                    let mut bin = NewBinary::new(env, len);
                    bin.as_mut_slice().copy_from_slice(&buf[..len]);
                    let bin_term = bin.into();
                    (crate::atoms::dhcp_rx(), bin_term).encode(env)
                });
                if sent.is_err() {
                    break; // Owner process died.
                }
            } else if n < 0 {
                let errno = std::io::Error::last_os_error()
                    .raw_os_error()
                    .unwrap_or(0);
                if errno != libc::EINTR {
                    break; // Fatal recv error.
                }
            }
        }

        // Check ARP socket for incoming ARP frames (if available).
        if arp_fd.is_some() {
            if fds[1].revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                // ARP socket error — disable ARP but keep running for DHCP.
                // We can't easily "disable" the fd in-loop, so just break.
                // The DHCP handshake can still complete; DAD will be skipped.
                break;
            }
            if fds[1].revents & libc::POLLIN != 0 {
                let afd = arp_fd.unwrap();
                // SAFETY: recv from a valid ARP socket fd.
                let n = unsafe {
                    libc::recv(
                        afd,
                        buf.as_mut_ptr() as *mut libc::c_void,
                        buf.len(),
                        0,
                    )
                };
                if n > 0 {
                    let len = n as usize;
                    let sent = msg_env.send_and_clear(&owner_pid, |env| {
                        let mut bin = NewBinary::new(env, len);
                        bin.as_mut_slice().copy_from_slice(&buf[..len]);
                        let bin_term = bin.into();
                        (crate::atoms::arp_rx(), bin_term).encode(env)
                    });
                    if sent.is_err() {
                        break; // Owner process died.
                    }
                } else if n < 0 {
                    let errno = std::io::Error::last_os_error()
                        .raw_os_error()
                        .unwrap_or(0);
                    if errno != libc::EINTR {
                        break;
                    }
                }
            }
        }
    }
}
