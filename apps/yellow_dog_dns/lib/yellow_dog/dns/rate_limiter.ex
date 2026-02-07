defmodule YellowDog.Dns.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for DNS requests.

  Provides protection against:
  - Single client flooding (per-client rate limiting)
  - Server overload (global rate limiting)
  - DNS amplification attacks (rate limit response size)

  Uses a token bucket algorithm with configurable:
  - Tokens per client (bucket capacity)
  - Token refill rate (tokens per second)
  - Global request limit

  ## Configuration

      config :yellow_dog_dns, YellowDog.Dns.RateLimiter,
        enabled: true,
        # Per-client limits
        client_tokens: 50,           # Max burst per client (DNS is bursty)
        client_refill_rate: 20,      # Tokens per second per client
        # Global limits
        global_tokens: 5000,         # Max global burst
        global_refill_rate: 1000,    # Global tokens per second
        # Cleanup
        bucket_ttl: 300_000,         # 5 minutes - cleanup inactive buckets
        cleanup_interval: 60_000     # 1 minute - run cleanup

  ## Usage

      # In handler, before processing request:
      case RateLimiter.check_rate(client_ip) do
        :ok -> process_request(...)
        {:error, :rate_limited} -> drop_request_or_send_servfail()
      end
  """

  use YellowDog.RateLimiter,
    ets_table: :dns_rate_buckets,
    telemetry_prefix: [:yellow_dog, :dns, :rate_limiter],
    otp_app: :yellow_dog_dns,
    default_config: %{
      enabled: true,
      client_tokens: 50,
      client_refill_rate: 20,
      global_tokens: 5000,
      global_refill_rate: 1000,
      bucket_ttl: 300_000,
      cleanup_interval: 60_000
    }
end
