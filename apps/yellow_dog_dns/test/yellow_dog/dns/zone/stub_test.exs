defmodule YellowDog.Dns.Zone.StubTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Zone.Stub

  setup do
    # Start the DNS ZoneRegistry for this test
    registry_name = :"ZoneRegistry_#{System.unique_integer([:positive])}"

    {:ok, _registry} =
      start_supervised({Registry, keys: :unique, name: YellowDog.Dns.ZoneRegistry})

    %{registry: registry_name}
  end

  # Helper to safely stop a GenServer
  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  describe "start_link/1" do
    test "starts a stub zone with required options" do
      opts = [
        name: "example.com",
        view_name: "test_view_#{System.unique_integer([:positive])}"
      ]

      {:ok, pid} = Stub.start_link(opts)
      assert Process.alive?(pid)
      assert Stub.get_name(pid) == "example.com"

      safe_stop(pid)
    end

    test "starts with NS records and glue records" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "delegated.com",
        view_name: view_name,
        ns_records: ["ns1.delegated.com", "ns2.delegated.com"],
        glue_records: %{
          "ns1.delegated.com" => {192, 168, 1, 1},
          "ns2.delegated.com" => {192, 168, 1, 2}
        }
      ]

      {:ok, pid} = Stub.start_link(opts)

      assert Stub.get_ns_records(pid) == ["ns1.delegated.com", "ns2.delegated.com"]

      stats = Stub.stats(pid)
      assert stats.ns_count == 2
      assert stats.glue_count == 2
      assert stats.available_ns == 2

      safe_stop(pid)
    end

    test "accepts IP addresses as strings in glue records" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "string-glue.com",
        view_name: view_name,
        ns_records: ["ns1.string-glue.com"],
        glue_records: %{
          "ns1.string-glue.com" => "10.0.0.1"
        }
      ]

      {:ok, pid} = Stub.start_link(opts)

      stats = Stub.stats(pid)
      assert stats.available_ns == 1

      safe_stop(pid)
    end
  end

  describe "get_name/1 and get_view/1" do
    test "returns zone name and view name" do
      view_name = "custom_view_#{System.unique_integer([:positive])}"

      opts = [name: "test.example.org", view_name: view_name]
      {:ok, pid} = Stub.start_link(opts)

      assert Stub.get_name(pid) == "test.example.org"
      assert Stub.get_view(pid) == view_name

      safe_stop(pid)
    end
  end

  describe "get_ns_records/1" do
    test "returns configured NS records" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      ns_records = ["ns1.example.com", "ns2.example.com", "ns3.example.com"]
      opts = [name: "example.com", view_name: view_name, ns_records: ns_records]

      {:ok, pid} = Stub.start_link(opts)
      assert Stub.get_ns_records(pid) == ns_records

      safe_stop(pid)
    end

    test "returns empty list when no NS records configured" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [name: "no-ns.com", view_name: view_name]
      {:ok, pid} = Stub.start_link(opts)

      assert Stub.get_ns_records(pid) == []

      safe_stop(pid)
    end
  end

  describe "add_glue_record/3" do
    test "adds a glue record" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "dynamic-glue.com",
        view_name: view_name,
        ns_records: ["ns1.dynamic-glue.com"]
      ]

      {:ok, pid} = Stub.start_link(opts)

      # Initially no glue, so no available NS servers
      assert Stub.stats(pid).available_ns == 0

      # Add glue record
      :ok = Stub.add_glue_record(pid, "ns1.dynamic-glue.com", {192, 168, 10, 1})

      # Now we have an available NS server
      assert Stub.stats(pid).available_ns == 1

      safe_stop(pid)
    end

    test "normalizes hostname to lowercase" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "case-test.com",
        view_name: view_name,
        ns_records: ["NS1.CASE-TEST.COM"]
      ]

      {:ok, pid} = Stub.start_link(opts)

      # Add glue with uppercase hostname
      :ok = Stub.add_glue_record(pid, "NS1.Case-Test.Com", {192, 168, 20, 1})

      # Should still match (case-insensitive)
      assert Stub.stats(pid).available_ns == 1

      safe_stop(pid)
    end
  end

  describe "resolve/2" do
    @tag :capture_log
    test "returns error when no NS servers available" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "no-servers.com",
        view_name: view_name,
        ns_records: ["ns1.no-servers.com"],
        # No glue records, so NS is not available
        glue_records: %{}
      ]

      {:ok, pid} = Stub.start_link(opts)

      query = create_test_query("www.no-servers.com", :A)
      assert {:error, :no_ns_servers} = Stub.resolve(pid, query)

      safe_stop(pid)
    end

    test "sends query to NS server and increments query count" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "query-count.com",
        view_name: view_name,
        ns_records: ["ns1.query-count.com"],
        glue_records: %{
          # Use TEST-NET-1 (RFC 5737) - non-routable documentation address
          # This ensures the query times out instead of reaching any local DNS server
          "ns1.query-count.com" => {192, 0, 2, 1}
        },
        timeout: 100,
        retries: 0
      ]

      {:ok, pid} = Stub.start_link(opts)

      # Verify initial stats
      stats = Stub.stats(pid)
      assert stats.query_count == 0

      # Make a query (will timeout but should still count)
      query = create_test_query("www.query-count.com", :A)

      # This will timeout since there's no real NS server
      result = Stub.resolve(pid, query)
      assert {:error, :servfail} = result

      stats = Stub.stats(pid)
      assert stats.query_count == 1

      safe_stop(pid)
    end
  end

  describe "reload/2" do
    test "updates NS records" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "reload-test.com",
        view_name: view_name,
        ns_records: ["ns1.reload-test.com"]
      ]

      {:ok, pid} = Stub.start_link(opts)
      assert Stub.get_ns_records(pid) == ["ns1.reload-test.com"]

      :ok = Stub.reload(pid, ns_records: ["ns2.reload-test.com", "ns3.reload-test.com"])
      assert Stub.get_ns_records(pid) == ["ns2.reload-test.com", "ns3.reload-test.com"]

      safe_stop(pid)
    end

    test "updates glue records" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "reload-glue.com",
        view_name: view_name,
        ns_records: ["ns1.reload-glue.com"],
        glue_records: %{
          "ns1.reload-glue.com" => {10, 0, 0, 1}
        }
      ]

      {:ok, pid} = Stub.start_link(opts)
      assert Stub.stats(pid).available_ns == 1

      # Reload with new glue records
      new_glue = %{
        "ns1.reload-glue.com" => {10, 0, 0, 2},
        "ns2.reload-glue.com" => {10, 0, 0, 3}
      }

      :ok = Stub.reload(pid, glue_records: new_glue)

      # Still only 1 available since only ns1 is in ns_records
      assert Stub.stats(pid).glue_count == 2
      assert Stub.stats(pid).available_ns == 1

      safe_stop(pid)
    end

    test "updates timeout and retries" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "reload-opts.com",
        view_name: view_name,
        timeout: 3000,
        retries: 1
      ]

      {:ok, pid} = Stub.start_link(opts)

      :ok = Stub.reload(pid, timeout: 10000, retries: 5)

      # We can verify via stats that reload succeeded
      # (timeout/retries not exposed in stats, but the reload should work)
      assert Stub.get_name(pid) == "reload-opts.com"

      safe_stop(pid)
    end
  end

  describe "stats/1" do
    test "returns comprehensive statistics" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "stats-test.com",
        view_name: view_name,
        ns_records: ["ns1.stats-test.com", "ns2.stats-test.com"],
        glue_records: %{
          "ns1.stats-test.com" => {192, 168, 1, 1}
        }
      ]

      {:ok, pid} = Stub.start_link(opts)

      stats = Stub.stats(pid)

      assert stats.name == "stats-test.com"
      assert stats.type == :stub
      assert stats.ns_count == 2
      assert stats.ns_records == ["ns1.stats-test.com", "ns2.stats-test.com"]
      assert stats.glue_count == 1
      assert stats.available_ns == 1
      assert stats.query_count == 0
      assert stats.success_count == 0
      assert stats.error_count == 0
      assert stats.pending_count == 0
      assert %DateTime{} = stats.created_at

      safe_stop(pid)
    end
  end

  describe "timeout handling" do
    @tag :capture_log
    test "retries on timeout" do
      view_name = "test_view_#{System.unique_integer([:positive])}"

      opts = [
        name: "timeout-retry.com",
        view_name: view_name,
        ns_records: ["ns1.timeout-retry.com"],
        glue_records: %{
          # Use TEST-NET-1 (RFC 5737) - non-routable documentation address
          "ns1.timeout-retry.com" => {192, 0, 2, 1}
        },
        timeout: 50,
        retries: 2
      ]

      {:ok, pid} = Stub.start_link(opts)

      query = create_test_query("www.timeout-retry.com", :A)

      # This will timeout after retries
      result = Stub.resolve(pid, query)
      assert {:error, :servfail} = result

      # Should have incremented error count
      stats = Stub.stats(pid)
      assert stats.error_count >= 1

      safe_stop(pid)
    end
  end

  # Helper function to create test DNS queries
  defp create_test_query(name, type) do
    header = DNS.Message.Header.new()
    # Map atom types to numeric values
    type_num = type_to_number(type)
    question = DNS.Message.Question.new(name, type_num, 1)

    %DNS.Message{
      header: %{header | id: :rand.uniform(65535)},
      qdlist: [question]
    }
  end

  # Map common DNS record types to their numeric values
  defp type_to_number(:A), do: 1
  defp type_to_number(:NS), do: 2
  defp type_to_number(:CNAME), do: 5
  defp type_to_number(:SOA), do: 6
  defp type_to_number(:PTR), do: 12
  defp type_to_number(:MX), do: 15
  defp type_to_number(:TXT), do: 16
  defp type_to_number(:AAAA), do: 28
  defp type_to_number(:SRV), do: 33
  defp type_to_number(n) when is_integer(n), do: n
end
