defmodule YellowDog.Resolved.SupervisorTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Supervisor, as: ResolvedSup

  describe "init/1 strategy" do
    test "uses :rest_for_one strategy" do
      {:ok, {sup_flags, _children}} = call_init(discovery_enabled: true)
      assert sup_flags.strategy == :rest_for_one
    end
  end

  describe "init/1 child ordering" do
    test "has 5 children when discovery disabled" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: false)
      assert length(children) == 5
    end

    test "has 6 children when discovery enabled" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: true)
      assert length(children) == 6
    end

    test "Config is the first child" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: false)
      first = hd(children)
      assert first.id == YellowDog.Resolved.Config
    end

    test "Cache is the second child" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: false)
      assert Enum.at(children, 1).id == YellowDog.Resolved.Cache
    end

    test "Metrics is the third child" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: false)
      assert Enum.at(children, 2).id == YellowDog.Resolved.Metrics
    end

    test "Forwarder is the fourth child" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: false)
      assert Enum.at(children, 3).id == YellowDog.Resolved.Forwarder
    end

    test "Listener is the fifth child" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: false)
      assert Enum.at(children, 4).id == YellowDog.Resolved.Listener
    end

    test "Discovery is the last child when enabled" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: true)
      last = List.last(children)
      assert last.id == YellowDog.Resolved.Discovery
    end

    test "child order is Config → Cache → Metrics → Forwarder → Listener" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: false)

      ids = Enum.map(children, & &1.id)

      assert ids == [
               YellowDog.Resolved.Config,
               YellowDog.Resolved.Cache,
               YellowDog.Resolved.Metrics,
               YellowDog.Resolved.Forwarder,
               YellowDog.Resolved.Listener
             ]
    end

    test "full order with discovery is Config → Cache → Metrics → Forwarder → Listener → Discovery" do
      {:ok, {_flags, children}} = call_init(discovery_enabled: true)

      ids = Enum.map(children, & &1.id)

      assert ids == [
               YellowDog.Resolved.Config,
               YellowDog.Resolved.Cache,
               YellowDog.Resolved.Metrics,
               YellowDog.Resolved.Forwarder,
               YellowDog.Resolved.Listener,
               YellowDog.Resolved.Discovery
             ]
    end
  end

  # Call Supervisor.init/1 with a temporary TOML config file.
  # This only builds child specs — no processes are started.
  defp call_init(opts) do
    discovery_enabled = Keyword.get(opts, :discovery_enabled, false)

    discovery_section =
      if discovery_enabled do
        """
        [resolved.discovery]
        enabled = true

        [resolved.discovery.websocket]
        heartbeat_interval_s = 30
        reconnect_base_s = 5
        reconnect_max_s = 60
        """
      else
        """
        [resolved.discovery]
        enabled = false
        """
      end

    toml = """
    [resolved]
    listen = "127.0.0.1"
    port = 0
    upstreams = ["8.8.8.8"]

    [resolved.cache]
    enabled = true
    max_entries = 100
    min_ttl_s = 5
    max_ttl_s = 3600
    negative_ttl_s = 10
    sweep_interval_s = 3600

    #{discovery_section}
    """

    tmp_dir = System.tmp_dir!()
    path = Path.join(tmp_dir, "sup_test_#{System.unique_integer([:positive])}.toml")
    File.write!(path, toml)

    original = Application.get_env(:yellow_dog_resolved, :config_path)
    Application.put_env(:yellow_dog_resolved, :config_path, path)

    try do
      ResolvedSup.init([])
    after
      if original do
        Application.put_env(:yellow_dog_resolved, :config_path, original)
      else
        Application.delete_env(:yellow_dog_resolved, :config_path)
      end

      File.rm(path)
    end
  end
end
