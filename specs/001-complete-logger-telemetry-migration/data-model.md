# Data Model: Telemetry Event Catalog

**Feature**: Complete Logger to Telemetry Migration
**Date**: 2025-12-23

## Overview

This document defines all telemetry events that will replace Logger calls across the Yellow Dog umbrella applications. Each event follows the Constitution v1.3.0 naming pattern: `[:app, :component, :resource, :action]`.

## Event Structure

All telemetry events use the standard `:telemetry.execute/3` signature:

```elixir
:telemetry.execute(
  event_name,     # List of atoms: [:yellow_dog, :dns, :query, :complete]
  measurements,   # Map of numeric values: %{duration_ms: 123, count: 1}
  metadata        # Map of context: %{source: __MODULE__, query: query}
)
```

---

## DNS Query Events

### [:yellow_dog, :dns, :query, :start]

Emitted when a DNS query resolution begins.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `query_name` | string | Domain being queried |
| `query_type` | atom | Record type (:a, :aaaa, :mx, etc.) |
| `query_class` | atom | Query class (:in, :ch, etc.) |
| `client_ip` | tuple | Client IP address |

### [:yellow_dog, :dns, :query, :complete]

Emitted when a DNS query resolution completes successfully.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_ms` | integer | Resolution time in milliseconds |
| `count` | integer | Always 1 |
| `answer_count` | integer | Number of answers returned |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `query_name` | string | Domain queried |
| `query_type` | atom | Record type |
| `result` | atom | :success, :nxdomain, :servfail, etc. |

### [:yellow_dog, :dns, :query, :error]

Emitted when a DNS query resolution fails.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_ms` | integer | Time until failure |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `query_name` | string | Domain queried |
| `query_type` | atom | Record type |
| `reason` | term | Error reason |
| `severity` | atom | :error, :warning |

### [:yellow_dog, :dns, :query, :forward]

Emitted when a query is forwarded to upstream server.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_ms` | integer | Forward time |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `query_name` | string | Domain queried |
| `upstream` | string | Upstream server address |
| `result` | atom | :success, :timeout, :error |

### [:yellow_dog, :dns, :query, :recursive]

Emitted when recursive resolution completes.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_ms` | integer | Total recursive time |
| `iteration_count` | integer | Number of iterations |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `query_name` | string | Domain queried |
| `result` | atom | :success, :nxdomain, :error |

---

## DNS Cache Events

### [:yellow_dog, :dns, :cache, :hit]

Emitted when a cache lookup finds a matching entry.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `query_name` | string | Domain queried |
| `query_type` | atom | Record type |
| `ttl_remaining` | integer | Seconds until expiry |

### [:yellow_dog, :dns, :cache, :miss]

Emitted when a cache lookup finds no matching entry.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `query_name` | string | Domain queried |
| `query_type` | atom | Record type |

### [:yellow_dog, :dns, :cache, :store]

Emitted when an entry is stored in cache.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| `ttl` | integer | TTL in seconds |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `query_name` | string | Domain stored |
| `query_type` | atom | Record type |
| `record_count` | integer | Number of records stored |

### [:yellow_dog, :dns, :cache, :cleanup]

Emitted when cache cleanup runs.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| `entries_removed` | integer | Number of entries removed |
| `entries_remaining` | integer | Number of entries kept |
| `duration_ms` | integer | Cleanup duration |
| **Metadata** | | |
| `source` | atom | Module emitting event |

---

## DNS Root Zone Events

### [:yellow_dog, :dns, :root_zone, :fetch]

Emitted when root zone data is fetched.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_ms` | integer | Fetch duration |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `result` | atom | :success, :error |
| `source_url` | string | URL fetched from |

### [:yellow_dog, :dns, :root_zone, :update]

Emitted when root zone is updated.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| `zone_count` | integer | Number of zones loaded |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `version` | string | Zone version if available |

---

## Application Lifecycle Events

### [:yellow_dog, :application, :start]

Emitted when YellowDog application starts.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `version` | string | Application version |
| `environment` | atom | :prod, :dev, :test |

### [:yellow_dog, :application, :stop]

Emitted when YellowDog application stops.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `uptime_ms` | integer | Total uptime |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `reason` | atom | Shutdown reason |

---

## Configuration Events

### [:yellow_dog, :config, :loaded]

Emitted when configuration is loaded.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `config_file` | string | Path to config file |
| `services_enabled` | list | List of enabled services |

### [:yellow_dog, :config, :error]

Emitted when configuration loading fails.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `config_file` | string | Path to config file |
| `reason` | term | Error reason |
| `severity` | atom | :error |

---

## Service Management Events

### [:yellow_dog, :service, :start]

Emitted when a service starts.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `service` | atom | :dns, :dhcpv4, :dhcpv6, :mdns |
| `port` | integer | Service port |
| `listen` | string | Listen address |

### [:yellow_dog, :service, :stop]

Emitted when a service stops.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `uptime_ms` | integer | Service uptime |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `service` | atom | Service identifier |
| `reason` | atom | Stop reason |

### [:yellow_dog, :service, :error]

Emitted when a service encounters an error.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `service` | atom | Service identifier |
| `reason` | term | Error reason |
| `severity` | atom | :error, :warning |

---

## Console Events

### [:yellow_dog, :console, :dashboard, :load]

Emitted when dashboard loads data.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `duration_ms` | integer | Load duration |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `services_loaded` | list | Services loaded |

### [:yellow_dog, :console, :settings, :update]

Emitted when settings are updated.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `setting` | string | Setting changed |
| `result` | atom | :success, :error |

---

## Infrastructure Events

### [:abyss, :rate_limiter, :check]

Emitted when rate limiter checks a request.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `client_ip` | tuple | Client IP |
| `allowed` | boolean | Whether request was allowed |

### [:abyss, :rate_limiter, :exceeded]

Emitted when rate limit is exceeded.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `client_ip` | tuple | Client IP |
| `limit` | integer | Rate limit value |
| `window_ms` | integer | Rate limit window |

### [:ex_dns, :error]

Emitted when DNS parsing/handling error occurs.

| Field | Type | Description |
|-------|------|-------------|
| **Measurements** | | |
| `count` | integer | Always 1 |
| **Metadata** | | |
| `source` | atom | Module emitting event |
| `error_type` | atom | Type of error |
| `reason` | term | Error details |
| `severity` | atom | :error, :warning |

---

## Logger Handler Mappings

Events are mapped to Logger levels in `YellowDog.Telemetry.LoggerHandlers`:

| Event Pattern | Logger Level |
|--------------|--------------|
| `[:yellow_dog, _, _, :error]` | `:error` |
| `[:yellow_dog, _, _, :start]` | `:info` |
| `[:yellow_dog, _, _, :stop]` | `:info` |
| `[:yellow_dog, _, _, :complete]` | `:debug` |
| `[:yellow_dog, _, :cache, :hit]` | `:debug` |
| `[:yellow_dog, _, :cache, :miss]` | `:debug` |
| `[:abyss, :rate_limiter, :exceeded]` | `:warning` |
| `[:ex_dns, :error]` | `:error` |
