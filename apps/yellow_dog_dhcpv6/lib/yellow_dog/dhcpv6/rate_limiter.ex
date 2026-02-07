defmodule YellowDog.Dhcpv6.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for DHCPv6 requests.

  Provides protection against:
  - Single client flooding (per-client rate limiting)
  - Pool exhaustion attacks (global rate limiting)
  - DoS attacks from spoofed DUIDs

  ## Configuration

      config :yellow_dog_dhcpv6, YellowDog.Dhcpv6.RateLimiter,
        enabled: true,
        client_tokens: 10,
        client_refill_rate: 2,
        global_tokens: 1000,
        global_refill_rate: 100,
        bucket_ttl: 300_000,
        cleanup_interval: 60_000

  ## Usage

      case RateLimiter.check_rate(client_identifier) do
        :ok -> process_request(...)
        {:error, :rate_limited} -> drop_request()
      end
  """

  use YellowDog.RateLimiter,
    ets_table: :dhcpv6_rate_buckets,
    telemetry_prefix: [:yellow_dog, :dhcpv6, :rate_limiter],
    otp_app: :yellow_dog_dhcpv6,
    default_config: %{
      enabled: true,
      client_tokens: 10,
      client_refill_rate: 2,
      global_tokens: 1000,
      global_refill_rate: 100,
      bucket_ttl: 300_000,
      cleanup_interval: 60_000
    }
end
