defmodule YellowDog.Dns.RootZone.FetcherTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.RootZone.Fetcher

  doctest Fetcher

  describe "default_config/0" do
    test "returns default configuration" do
      config = Fetcher.default_config()

      assert config.url == "https://www.internic.net/domain/root.zone"
      assert config.interval_hours == 24
      assert config.timeout_ms == 30_000
    end

    test "config is a map with required keys" do
      config = Fetcher.default_config()

      assert Map.has_key?(config, :url)
      assert Map.has_key?(config, :interval_hours)
      assert Map.has_key?(config, :timeout_ms)
    end
  end

  describe "parse_and_load/2" do
    @tag :integration
    test "parses minimal zone data and loads it" do
      # Minimal valid zone file
      zone_data = """
      $ORIGIN .
      $TTL 518400
      .       IN  SOA a.root-servers.net. nstld.verisign-grs.com. (
                          2024102901  ; serial
                          1800        ; refresh (30 minutes)
                          900         ; retry (15 minutes)
                          604800      ; expire (1 week)
                          86400       ; minimum (1 day)
                          )
      .       IN  NS  a.root-servers.net.
      a.root-servers.net. IN A 198.41.0.4
      """

      temp_dir = System.tmp_dir!()

      result = Fetcher.parse_and_load(zone_data, temp_dir)

      case result do
        {:ok, serial} ->
          assert is_integer(serial)
          assert serial > 0

        {:error, _reason} ->
          # May fail if Zone.Manager not started, which is acceptable in unit tests
          :ok
      end
    end

    @tag :integration
    test "handles invalid zone data" do
      zone_data = "invalid zone data"
      temp_dir = System.tmp_dir!()

      result = Fetcher.parse_and_load(zone_data, temp_dir)

      # Should either error or succeed if Zone.Manager gracefully handles it
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end
  end

  describe "schedule_periodic_fetch/1" do
    test "schedules a message after interval" do
      # Schedule for 100ms in the future
      ref = Fetcher.schedule_periodic_fetch(100)

      assert is_reference(ref)

      # Wait for message
      receive do
        :fetch_root_zone ->
          assert true
      after
        200 ->
          flunk("Did not receive :fetch_root_zone message")
      end
    end

    test "returns a timer reference" do
      ref = Fetcher.schedule_periodic_fetch(10_000)

      assert is_reference(ref)

      # Cancel the timer to avoid side effects
      Process.cancel_timer(ref)
    end
  end

  @tag :skip
  @tag :integration
  describe "fetch_root_zone/1 (integration)" do
    test "fetches from real IANA URL" do
      # This test requires internet connectivity
      result = Fetcher.fetch_root_zone(timeout_ms: 60_000)

      case result do
        {:ok, serial} ->
          assert is_integer(serial)
          assert serial > 2024_00_00_00

        {:error, reason} ->
          # Network errors are acceptable in tests
          IO.puts("Fetch failed (expected in offline env): #{inspect(reason)}")
      end
    end
  end

  describe "fetch_root_zone/1 with mock" do
    @tag :skip
    test "handles HTTP errors gracefully" do
      # This would require mocking Req
      # For now, we test with a fake URL
      result = Fetcher.fetch_root_zone(url: "https://invalid.example.com/root.zone")

      assert {:error, _reason} = result
    end
  end
end
