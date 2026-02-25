defmodule YellowDogIdentity.TelemetryTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Telemetry

  defp attach(handler_id, event) do
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )
  end

  describe "registration_start/3" do
    test "emits start event with system_time, hostname, source_ip, and trust_level" do
      ref = make_ref()
      handler_id = "test-reg-start-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :register, :start])

      Telemetry.registration_start("node-01", {192, 168, 1, 10}, :verified)

      assert_receive {:telemetry, [:yellow_dog, :identity, :register, :start], measurements,
                       metadata}

      assert is_integer(measurements.system_time)
      assert metadata.hostname == "node-01"
      assert metadata.source_ip == "192.168.1.10"
      assert metadata.trust_level == :verified

      :telemetry.detach(handler_id)
    end

    test "defaults trust_level to :unverified" do
      ref = make_ref()
      handler_id = "test-reg-start-default-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :register, :start])

      Telemetry.registration_start("node-02", "10.0.0.1")

      assert_receive {:telemetry, [:yellow_dog, :identity, :register, :start], _measurements,
                       metadata}

      assert metadata.trust_level == :unverified
      assert metadata.source_ip == "10.0.0.1"

      :telemetry.detach(handler_id)
    end
  end

  describe "registration_stop/2" do
    test "emits stop event with duration and metadata" do
      ref = make_ref()
      handler_id = "test-reg-stop-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :register, :stop])

      meta = %{hostname: "node-01", status: :approved}
      Telemetry.registration_stop(1_500_000, meta)

      assert_receive {:telemetry, [:yellow_dog, :identity, :register, :stop], measurements,
                       metadata}

      assert measurements.duration == 1_500_000
      assert metadata.hostname == "node-01"
      assert metadata.status == :approved

      :telemetry.detach(handler_id)
    end
  end

  describe "registration_exception/3" do
    test "emits exception event with duration, hostname, and reason" do
      ref = make_ref()
      handler_id = "test-reg-exception-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :register, :exception])

      Telemetry.registration_exception(2_000_000, "node-03", :timeout)

      assert_receive {:telemetry, [:yellow_dog, :identity, :register, :exception], measurements,
                       metadata}

      assert measurements.duration == 2_000_000
      assert metadata.hostname == "node-03"
      assert metadata.reason == :timeout

      :telemetry.detach(handler_id)
    end
  end

  describe "host_approved/3" do
    test "emits approve event with host_id, approved_by, and trust_level" do
      ref = make_ref()
      handler_id = "test-approved-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :approve])

      Telemetry.host_approved("abc-123", "admin@example.com", :full)

      assert_receive {:telemetry, [:yellow_dog, :identity, :approve], measurements, metadata}

      assert measurements.count == 1
      assert metadata.host_id == "abc-123"
      assert metadata.approved_by == "admin@example.com"
      assert metadata.trust_level == :full

      :telemetry.detach(handler_id)
    end
  end

  describe "host_revoked/3" do
    test "emits revoke event with host_id, revoked_by, and reason" do
      ref = make_ref()
      handler_id = "test-revoked-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :revoke])

      Telemetry.host_revoked("abc-123", "admin@example.com", :compromised)

      assert_receive {:telemetry, [:yellow_dog, :identity, :revoke], measurements, metadata}

      assert measurements.count == 1
      assert metadata.host_id == "abc-123"
      assert metadata.revoked_by == "admin@example.com"
      assert metadata.reason == :compromised

      :telemetry.detach(handler_id)
    end
  end

  describe "correlation_match/4" do
    test "emits correlation match event with formatted IP tuple" do
      ref = make_ref()
      handler_id = "test-corr-match-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :correlation, :match])

      Telemetry.correlation_match({10, 0, 0, 5}, "aa:bb:cc:dd:ee:ff", "Linux", :dhcp)

      assert_receive {:telemetry, [:yellow_dog, :identity, :correlation, :match], measurements,
                       metadata}

      assert measurements.count == 1
      assert metadata.source_ip == "10.0.0.5"
      assert metadata.mac == "aa:bb:cc:dd:ee:ff"
      assert metadata.fingerprint_class == "Linux"
      assert metadata.trust_level == :dhcp

      :telemetry.detach(handler_id)
    end

    test "formats IPv6 tuple to string" do
      ref = make_ref()
      handler_id = "test-corr-match-v6-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :correlation, :match])

      Telemetry.correlation_match({0, 0, 0, 0, 0, 0, 0, 1}, "aa:bb:cc:dd:ee:ff", "Linux", :dhcp)

      assert_receive {:telemetry, [:yellow_dog, :identity, :correlation, :match], _measurements,
                       metadata}

      assert metadata.source_ip == "::1"

      :telemetry.detach(handler_id)
    end
  end

  describe "correlation_miss/2" do
    test "emits correlation miss event with formatted source_ip and reason" do
      ref = make_ref()
      handler_id = "test-corr-miss-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :correlation, :miss])

      Telemetry.correlation_miss({172, 16, 0, 1}, :no_lease)

      assert_receive {:telemetry, [:yellow_dog, :identity, :correlation, :miss], measurements,
                       metadata}

      assert measurements.count == 1
      assert metadata.source_ip == "172.16.0.1"
      assert metadata.reason == :no_lease

      :telemetry.detach(handler_id)
    end

    test "passes string source_ip through unchanged" do
      ref = make_ref()
      handler_id = "test-corr-miss-str-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :correlation, :miss])

      Telemetry.correlation_miss("192.168.1.1", :expired)

      assert_receive {:telemetry, [:yellow_dog, :identity, :correlation, :miss], _measurements,
                       metadata}

      assert metadata.source_ip == "192.168.1.1"

      :telemetry.detach(handler_id)
    end

    test "formats non-tuple non-string source_ip as unknown" do
      ref = make_ref()
      handler_id = "test-corr-miss-unknown-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :correlation, :miss])

      Telemetry.correlation_miss(nil, :invalid)

      assert_receive {:telemetry, [:yellow_dog, :identity, :correlation, :miss], _measurements,
                       metadata}

      assert metadata.source_ip == "unknown"

      :telemetry.detach(handler_id)
    end
  end

  describe "attestation_verify/5" do
    test "emits attestation verify event with duration, provider, account_id, instance_id, result" do
      ref = make_ref()
      handler_id = "test-attest-verify-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :attestation, :verify])

      Telemetry.attestation_verify(3_000_000, :aws, "acct-111", "i-abc123", :ok)

      assert_receive {:telemetry, [:yellow_dog, :identity, :attestation, :verify], measurements,
                       metadata}

      assert measurements.duration == 3_000_000
      assert metadata.provider == :aws
      assert metadata.account_id == "acct-111"
      assert metadata.instance_id == "i-abc123"
      assert metadata.result == :ok

      :telemetry.detach(handler_id)
    end
  end

  describe "attestation_reject/3" do
    test "emits attestation reject event with provider, reason, and formatted source_ip" do
      ref = make_ref()
      handler_id = "test-attest-reject-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :attestation, :reject])

      Telemetry.attestation_reject(:gcp, :invalid_token, {10, 20, 30, 40})

      assert_receive {:telemetry, [:yellow_dog, :identity, :attestation, :reject], measurements,
                       metadata}

      assert measurements.count == 1
      assert metadata.provider == :gcp
      assert metadata.reason == :invalid_token
      assert metadata.source_ip == "10.20.30.40"

      :telemetry.detach(handler_id)
    end
  end

  describe "export_recipients/2" do
    test "emits export recipients event with count and duration measurements" do
      ref = make_ref()
      handler_id = "test-export-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :export, :recipients])

      Telemetry.export_recipients(42, 500_000)

      assert_receive {:telemetry, [:yellow_dog, :identity, :export, :recipients], measurements,
                       metadata}

      assert measurements.count == 42
      assert measurements.duration == 500_000
      assert metadata == %{}

      :telemetry.detach(handler_id)
    end
  end

  describe "trust_untrusted/3" do
    test "emits trust untrusted event with provider, reason, and hostname" do
      ref = make_ref()
      handler_id = "test-trust-untrusted-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :trust, :untrusted])

      Telemetry.trust_untrusted(:manual, :policy_violation, "rogue-node")

      assert_receive {:telemetry, [:yellow_dog, :identity, :trust, :untrusted], measurements,
                       metadata}

      assert measurements.count == 1
      assert metadata.provider == :manual
      assert metadata.reason == :policy_violation
      assert metadata.hostname == "rogue-node"

      :telemetry.detach(handler_id)
    end
  end

  describe "trust_resolved/4" do
    test "emits trust resolved event with duration, trust_level, provider, and hostname" do
      ref = make_ref()
      handler_id = "test-trust-resolved-#{inspect(ref)}"
      attach(handler_id, [:yellow_dog, :identity, :trust, :resolved])

      Telemetry.trust_resolved(1_200_000, :full, :cloud_attestation, "prod-web-01")

      assert_receive {:telemetry, [:yellow_dog, :identity, :trust, :resolved], measurements,
                       metadata}

      assert measurements.duration == 1_200_000
      assert metadata.trust_level == :full
      assert metadata.provider == :cloud_attestation
      assert metadata.hostname == "prod-web-01"

      :telemetry.detach(handler_id)
    end
  end
end
