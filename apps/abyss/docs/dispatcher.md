# Opt-in datagram dispatcher

The default Abyss configuration continues to create one legacy handler per
datagram. A protocol that needs persistent state can set
`datagram_dispatcher: Module` (or `{Module, module_options}`) on a unicast
listener. The module implements `Abyss.DatagramDispatcher`.

The dispatcher is a separate process from the listener's blocking
`recv(:infinity)` loop. Its writer owns a bounded queue and performs local UDP
sends independently of listener mailbox progress. A callback returns `{:new,
keys, pid, state}` or `{:route, keys, pid, state}` to install CID/provisional
route keys; process death removes every key. The callback context also provides
`send_fun/2`, which accepts `(remote, bytes)` and returns the writer result for
adapters that should not depend on Abyss structs. Admission returns a bounded
error under queue pressure. A callback must not close the shared socket.

`datagram_dispatcher` is unavailable in broadcast mode and is optional: Abyss
does not load or require ex_quic when the option is omitted.
