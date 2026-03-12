defmodule YellowDogIdentity.AuditLogTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Registry

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "audit_log_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(Path.join(tmp_dir, "hosts"))
    File.mkdir_p!(Path.join(tmp_dir, "tokens"))

    # Stop the identity supervisor (which manages Registry) if running
    if sup = Process.whereis(YellowDogIdentity.Supervisor) do
      Supervisor.stop(sup)
    end

    # Stop any pre-existing registry (started by yellow_dog app)
    if pid = Process.whereis(YellowDogIdentity.Registry) do
      GenServer.stop(pid)
    end

    start_supervised!({YellowDogIdentity.Registry, data_dir: tmp_dir, name: YellowDogIdentity.Registry})

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  defp flush_cast do
    :sys.get_state(YellowDogIdentity.Registry)
  end

  describe "read_audit_log/1" do
    test "returns empty list when no audit.log exists" do
      assert Registry.read_audit_log() == []
    end

    test "returns entry after append_audit" do
      host_id = "aaaaaaaa-1111-2222-3333-444444444444"
      Registry.append_audit("host.registered", host_id)
      flush_cast()

      entries = Registry.read_audit_log()
      assert length(entries) == 1

      [entry] = entries
      assert entry.event == "host.registered"
      assert entry.host_id == host_id
      assert entry.timestamp != ""
    end

    test "multiple entries returned in reverse chronological order (newest first)" do
      Registry.append_audit("host.registered", "host-1")
      flush_cast()
      Registry.append_audit("host.approved", "host-2")
      flush_cast()
      Registry.append_audit("host.revoked", "host-3")
      flush_cast()

      entries = Registry.read_audit_log()
      assert length(entries) == 3
      assert Enum.map(entries, & &1.event) == ["host.revoked", "host.approved", "host.registered"]
    end

    test "filtering by event type" do
      Registry.append_audit("host.registered", "host-1")
      flush_cast()
      Registry.append_audit("host.approved", "host-2")
      flush_cast()
      Registry.append_audit("host.registered", "host-3")
      flush_cast()

      entries = Registry.read_audit_log(event: "host.registered")
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.event == "host.registered"))
    end

    test "filtering by host_id" do
      target_id = "target-host-id"
      Registry.append_audit("host.registered", target_id)
      flush_cast()
      Registry.append_audit("host.approved", "other-host")
      flush_cast()
      Registry.append_audit("host.revoked", target_id)
      flush_cast()

      entries = Registry.read_audit_log(host_id: target_id)
      assert length(entries) == 2
      assert Enum.all?(entries, &(&1.host_id == target_id))
    end

    test "limit option restricts number of results" do
      for i <- 1..5 do
        Registry.append_audit("host.registered", "host-#{i}")
        flush_cast()
      end

      entries = Registry.read_audit_log(limit: 3)
      assert length(entries) == 3

      # Should return newest first, so host-5, host-4, host-3
      assert Enum.map(entries, & &1.host_id) == ["host-5", "host-4", "host-3"]
    end

    test "combined event and host_id filter" do
      target_id = "combo-host"
      Registry.append_audit("host.registered", target_id)
      flush_cast()
      Registry.append_audit("host.approved", target_id)
      flush_cast()
      Registry.append_audit("host.registered", "other-host")
      flush_cast()
      Registry.append_audit("host.revoked", target_id)
      flush_cast()

      entries = Registry.read_audit_log(event: "host.registered", host_id: target_id)
      assert length(entries) == 1
      assert hd(entries).event == "host.registered"
      assert hd(entries).host_id == target_id
    end

    test "entries with details are parsed correctly" do
      host_id = "detailed-host"
      details = %{hostname: "node-01", status: :approved, trust_level: :high}
      Registry.append_audit("host.registered", host_id, details)
      flush_cast()

      [entry] = Registry.read_audit_log()
      assert entry.event == "host.registered"
      assert entry.host_id == host_id
      assert entry.details != ""
    end

    test "malformed lines are skipped", %{tmp_dir: tmp_dir} do
      audit_path = Path.join(tmp_dir, "audit.log")

      content = """
      2024-01-01T00:00:00Z host.registered host=valid-host details
      this is a malformed line
      not even close
      2024-01-01T00:00:01Z host.approved host=another-host more-details
      """

      File.write!(audit_path, content)

      entries = Registry.read_audit_log()
      assert length(entries) == 2
      assert Enum.map(entries, & &1.host_id) == ["another-host", "valid-host"]
    end
  end

  describe "YellowDogIdentity.audit_log/1" do
    test "wraps Registry.read_audit_log" do
      Registry.append_audit("host.registered", "api-host")
      flush_cast()

      entries = YellowDogIdentity.audit_log()
      assert length(entries) == 1
      assert hd(entries).host_id == "api-host"
    end

    test "passes options through" do
      Registry.append_audit("host.registered", "host-a")
      flush_cast()
      Registry.append_audit("host.approved", "host-b")
      flush_cast()

      entries = YellowDogIdentity.audit_log(event: "host.approved")
      assert length(entries) == 1
      assert hd(entries).event == "host.approved"
    end
  end
end
