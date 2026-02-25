# CLAUDE.md - yellow_dog_resolved

## Overview

DNS stub resolver that replaces `systemd-resolved`. Listens on `127.0.0.1:53`, intercepts queries matching configurable domain rules, and forwards everything else to upstream DNS servers. Optionally auto-discovers YellowDog DNS instances via EDNS for remote management.

## Architecture

```
Listener (Abyss UDP) → Router → Intercept / Cache / Forwarder
                                                      ↓
                                              Upstream DNS (Abyss.Client)
Discovery (EDNS 65321) → Management WS Client
```

## Module Map

| Module | Purpose |
|--------|---------|
| `Application` | OTP app entry; skips start in test via `:start_services` config |
| `Supervisor` | rest_for_one: Config → Cache → Forwarder → Listener → Discovery |
| `Config` | TOML loader + FileSystem watcher for hot-reload |
| `Intercept` | Rule matching: exact, suffix (`*.local.dev`), prefix (`dev-*`) |
| `Cache` | ETS DNS cache: TTL, negative caching (NXDOMAIN), LRU eviction, sweep |
| `ResponseBuilder` | DNS response construction for A/AAAA/CNAME/TXT/MX/SRV |
| `Router` | Query pipeline: intercept → cache → forward |
| `Forwarder` | Upstream query + txn_id correlation + failover + deprioritization |
| `Listener` | Abyss.Handler for UDP DNS packets |
| `Discovery` | EDNS option 65321 probe + SRV extraction |
| `Management.Client` | WebSocket client for management commands (stub) |
| `Management.Handler` | Command dispatch: cache_flush, cache_stats, ping |

## Commands

```bash
# Run tests (from app dir)
cd apps/yellow_dog_resolved && mix test

# Run specific test
mix test test/yellow_dog_resolved/intercept_test.exs

# Quality checks
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
```

## Key Gotchas

- `Record.new/5` expects raw data (IP tuple, string), NOT `Data.A.new(ip)` result — double-wraps otherwise
- Application auto-start disabled in test via `config :yellow_dog_resolved, start_services: false`
- Tests start components individually via `start_supervised!`
- Config path resolution: `File.cwd!()` is already the app dir in umbrella
- WebSocket management client is a stub — production needs `websock_client` or `mint_web_socket`

## Configuration

TOML config at `config/resolved.toml`. Key sections:
- `[resolved]` — listen address, port, upstreams, timeouts
- `[resolved.cache]` — max entries, TTL clamps, sweep interval
- `[resolved.discovery]` — EDNS probe + WebSocket reconnection settings
- `[[resolved.intercept]]` — ordered intercept rules (first match wins)
