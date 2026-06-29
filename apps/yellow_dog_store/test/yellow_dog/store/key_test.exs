defmodule YellowDog.Store.KeyTest do
  use ExUnit.Case, async: true

  alias YellowDog.Store.Key

  describe "normalize_mac/1" do
    test "normalizes uppercase MAC to lowercase colon-separated" do
      assert Key.normalize_mac("AA:BB:CC:DD:EE:FF") == "aa:bb:cc:dd:ee:ff"
    end

    test "normalizes dash-separated MAC" do
      assert Key.normalize_mac("aa-bb-cc-dd-ee-ff") == "aa:bb:cc:dd:ee:ff"
    end

    test "normalizes dot-separated MAC" do
      assert Key.normalize_mac("aa.bb.cc.dd.ee.ff") == "aa:bb:cc:dd:ee:ff"
    end

    test "normalizes no-separator MAC" do
      assert Key.normalize_mac("aabbccddeeff") == "aa:bb:cc:dd:ee:ff"
    end

    test "normalizes mixed-case dash-separated MAC" do
      assert Key.normalize_mac("AA-Bb-cC-Dd-EE-ff") == "aa:bb:cc:dd:ee:ff"
    end

    test "already normalized MAC passes through unchanged" do
      assert Key.normalize_mac("aa:bb:cc:dd:ee:ff") == "aa:bb:cc:dd:ee:ff"
    end
  end

  describe "normalize_duid/1" do
    test "normalizes uppercase DUID to lowercase" do
      assert Key.normalize_duid("00:01:AA:BB") == "00:01:aa:bb"
    end

    test "normalizes dash-separated DUID" do
      assert Key.normalize_duid("00-01-aa-bb") == "00:01:aa:bb"
    end

    test "normalizes dot-separated DUID" do
      assert Key.normalize_duid("00.01.AA.BB") == "00:01:aa:bb"
    end

    test "already normalized DUID passes through unchanged" do
      assert Key.normalize_duid("00:01:aa:bb:cc") == "00:01:aa:bb:cc"
    end
  end

  describe "lease_v4/1" do
    test "builds correct key format" do
      assert Key.lease_v4("AA:BB:CC:DD:EE:FF") == "dhcp:lease:v4:aa:bb:cc:dd:ee:ff"
    end

    test "normalizes MAC in key" do
      assert Key.lease_v4("aabbccddeeff") == "dhcp:lease:v4:aa:bb:cc:dd:ee:ff"
    end
  end

  describe "lease_v6/1" do
    test "builds correct key format" do
      assert Key.lease_v6("00:01:AA:BB") == "dhcp:lease:v6:00:01:aa:bb"
    end
  end

  describe "lease/2" do
    test "delegates to lease_v4 for :v4 protocol" do
      assert Key.lease(:v4, "AA:BB:CC:DD:EE:FF") == Key.lease_v4("AA:BB:CC:DD:EE:FF")
    end

    test "delegates to lease_v6 for :v6 protocol" do
      assert Key.lease(:v6, "00:01:AA:BB") == Key.lease_v6("00:01:AA:BB")
    end
  end

  describe "pool/1" do
    test "builds correct key" do
      assert Key.pool("192.168.1.0/24") == "dhcp:pool:192.168.1.0/24"
    end
  end

  describe "device/1" do
    test "builds correct key with normalized MAC" do
      assert Key.device("AA:BB:CC:DD:EE:FF") == "device:aa:bb:cc:dd:ee:ff"
    end
  end

  describe "dyn_dns/1" do
    test "builds correct key" do
      assert Key.dyn_dns("host.example.com.") == "dns:dyn:host.example.com."
    end
  end

  describe "dyn_dns_ptr/1" do
    test "builds correct key" do
      assert Key.dyn_dns_ptr("1.0.168.192.in-addr.arpa") ==
               "dns:dyn:ptr:1.0.168.192.in-addr.arpa"
    end
  end

  describe "zone/1" do
    test "builds correct key" do
      assert Key.zone("example.com") == "dns:view:default:zone:example.com"
    end
  end

  describe "zone_rr/3" do
    test "builds correct key" do
      assert Key.zone_rr("example.com", "www.example.com", :a) ==
               "dns:view:default:zone:example.com:rr:www.example.com:a"
    end
  end

  describe "cache/2" do
    test "builds correct key" do
      assert Key.cache("example.com", :a) == "dns:cache:example.com:a"
    end
  end

  describe "rpz/2" do
    test "builds correct key" do
      assert Key.rpz("blocklist", "bad.example.com") == "rpz:blocklist:bad.example.com"
    end
  end

  describe "host/1" do
    test "builds correct key" do
      assert Key.host("myhost") == "host:myhost"
    end
  end

  describe "config/2" do
    test "builds correct key" do
      assert Key.config(:dns, :port) == "config:dns:port"
    end

    test "accepts string key" do
      assert Key.config(:dns, "port") == "config:dns:port"
    end
  end

  describe "event_log/2" do
    test "builds correct key" do
      assert Key.event_log(1_234_567, "dhcp:lease:v4:aa:bb:cc:dd:ee:ff") ==
               "event_log:1234567:dhcp:lease:v4:aa:bb:cc:dd:ee:ff"
    end
  end

  describe "task_job/2" do
    test "builds per-task job keys" do
      assert Key.task_job(:ip_city, "job-1") == "tasks:job:ip_city:job-1"
      assert Key.task_job("mac", "job-2") == "tasks:job:mac:job-2"
    end
  end

  describe "prefix functions" do
    test "lease_v4_prefix" do
      assert Key.lease_v4_prefix() == "dhcp:lease:v4:"
    end

    test "lease_v6_prefix" do
      assert Key.lease_v6_prefix() == "dhcp:lease:v6:"
    end

    test "device_prefix" do
      assert Key.device_prefix() == "device:"
    end

    test "dyn_dns_prefix" do
      assert Key.dyn_dns_prefix() == "dns:dyn:"
    end

    test "zone_prefix" do
      assert Key.zone_prefix() == "dns:view:default:zone:"
    end

    test "zone_rr_prefix includes zone name" do
      assert Key.zone_rr_prefix("example.com") == "dns:view:default:zone:example.com:rr:"
    end

    test "cache_prefix" do
      assert Key.cache_prefix() == "dns:cache:"
    end

    test "rpz_prefix includes zone name" do
      assert Key.rpz_prefix("blocklist") == "rpz:blocklist:"
    end

    test "rpz_all_prefix" do
      assert Key.rpz_all_prefix() == "rpz:"
    end

    test "config_prefix includes service" do
      assert Key.config_prefix(:dns) == "config:dns:"
    end

    test "event_log_prefix" do
      assert Key.event_log_prefix() == "event_log:"
    end

    test "task prefixes" do
      assert Key.task_job_prefix() == "tasks:job:"
      assert Key.task_job_prefix(:ip_city) == "tasks:job:ip_city:"
      assert Key.task_schedule_prefix() == "tasks:schedule:"
    end
  end

  describe "key determinism" do
    test "same input always produces same key" do
      mac = "AA-BB-CC-DD-EE-FF"
      assert Key.lease_v4(mac) == Key.lease_v4(mac)
      assert Key.device(mac) == Key.device(mac)
    end

    test "different MAC formats produce identical keys" do
      key1 = Key.lease_v4("AA:BB:CC:DD:EE:FF")
      key2 = Key.lease_v4("aa-bb-cc-dd-ee-ff")
      key3 = Key.lease_v4("aabbccddeeff")
      key4 = Key.lease_v4("AA.BB.CC.DD.EE.FF")

      assert key1 == key2
      assert key2 == key3
      assert key3 == key4
    end

    test "lease key starts with the correct prefix" do
      key = Key.lease_v4("aa:bb:cc:dd:ee:ff")
      assert String.starts_with?(key, Key.lease_v4_prefix())
    end

    test "zone_rr key starts with the correct prefix" do
      key = Key.zone_rr("example.com", "www", :a)
      assert String.starts_with?(key, Key.zone_rr_prefix("example.com"))
    end
  end
end
