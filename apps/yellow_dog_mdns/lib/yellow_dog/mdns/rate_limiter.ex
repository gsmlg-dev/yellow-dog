defmodule YellowDog.Mdns.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for mDNS requests.

  Provides protection against:
  - Single source flooding (per-source rate limiting)
  - Network congestion (global rate limiting)
  - mDNS amplification attacks

  mDNS rate limiting is less aggressive than DNS since:
  - It operates only on the local network
  - Multicast nature means responses go to all hosts
  - Legitimate usage can be bursty (service announcements)

  ## Configuration

      config :yellow_dog_mdns, YellowDog.Mdns.RateLimiter,
        enabled: true,
        client_tokens: 100,
        client_refill_rate: 50,
        global_tokens: 10000,
        global_refill_rate: 5000,
        bucket_ttl: 300_000,
        cleanup_interval: 60_000

  ## Usage

      case RateLimiter.check_rate(source_ip) do
        :ok -> process_message(...)
        {:error, :rate_limited} -> drop_message()
      end
  """

  use YellowDog.RateLimiter,
    ets_table: :mdns_rate_buckets,
    telemetry_prefix: [:yellow_dog, :mdns, :rate_limiter],
    otp_app: :yellow_dog_mdns,
    default_config: %{
      enabled: true,
      client_tokens: 100,
      client_refill_rate: 50,
      global_tokens: 10000,
      global_refill_rate: 5000,
      bucket_ttl: 300_000,
      cleanup_interval: 60_000
    }
end
