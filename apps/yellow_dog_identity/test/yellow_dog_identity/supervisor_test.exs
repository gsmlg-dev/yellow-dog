defmodule YellowDogIdentity.SupervisorTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Supervisor, as: IdentitySup

  # ---------------------------------------------------------------------------
  # init/1 return value (no running supervisor needed)
  # ---------------------------------------------------------------------------

  describe "init/1 return value" do
    test "returns {:ok, supervisor_spec} tuple" do
      assert {:ok, {sup_flags, children}} = IdentitySup.init([])
      assert is_map(sup_flags)
      assert is_list(children)
    end

    test "uses one_for_one strategy" do
      {:ok, {sup_flags, _children}} = IdentitySup.init([])
      assert sup_flags.strategy == :one_for_one
    end

    test "starts children in correct order: Registry then LeaseCache" do
      {:ok, {_sup_flags, children}} = IdentitySup.init([])

      assert length(children) == 2

      [first, second] = children
      assert first.start == {YellowDogIdentity.Registry, :start_link, [[data_dir: "data/identity"]]}
      assert second.start == {YellowDogIdentity.Trust.DHCP.LeaseCache, :start_link, [[]]}
    end

    test "uses default data_dir when no option is provided" do
      {:ok, {_sup_flags, [registry_spec | _]}} = IdentitySup.init([])

      {YellowDogIdentity.Registry, :start_link, [opts]} = registry_spec.start
      assert Keyword.get(opts, :data_dir) == "data/identity"
    end

    test "uses custom data_dir when provided" do
      {:ok, {_sup_flags, [registry_spec | _]}} = IdentitySup.init(data_dir: "/tmp/custom_identity")

      {YellowDogIdentity.Registry, :start_link, [opts]} = registry_spec.start
      assert Keyword.get(opts, :data_dir) == "/tmp/custom_identity"
    end

    test "LeaseCache child receives empty opts" do
      {:ok, {_sup_flags, [_registry, lease_cache_spec]}} = IdentitySup.init([])

      assert lease_cache_spec.start == {YellowDogIdentity.Trust.DHCP.LeaseCache, :start_link, [[]]}
    end
  end

  # ---------------------------------------------------------------------------
  # Supervisor lifecycle (requires starting the process)
  #
  # The supervisor registers under a fixed name (__MODULE__), so only one
  # instance can exist at a time.  We use a single test that exercises all
  # lifecycle assertions, then cleanly shuts the supervisor down.
  # ---------------------------------------------------------------------------

  describe "start_link/1" do
    test "starts successfully with running children" do
      tmp_dir = make_tmp_dir()

      {:ok, pid} = IdentitySup.start_link(data_dir: tmp_dir)

      try do
        # Supervisor is alive
        assert Process.alive?(pid)

        # Has the expected two children
        children = Supervisor.which_children(pid)
        assert length(children) == 2

        # Children are the correct modules
        child_modules = Enum.map(children, fn {_id, _pid, _type, [mod]} -> mod end)
        assert YellowDogIdentity.Registry in child_modules
        assert YellowDogIdentity.Trust.DHCP.LeaseCache in child_modules

        # All children are workers and alive
        Enum.each(children, fn {_id, child_pid, type, _modules} ->
          assert type == :worker
          assert is_pid(child_pid)
          assert Process.alive?(child_pid)
        end)
      after
        Supervisor.stop(pid, :normal)
        File.rm_rf!(tmp_dir)
      end
    end

    test "creates data_dir structure for Registry" do
      tmp_dir = make_tmp_dir()

      {:ok, pid} = IdentitySup.start_link(data_dir: tmp_dir)

      try do
        # The Registry should have created its subdirectories
        assert File.dir?(Path.join(tmp_dir, "hosts"))
        assert File.dir?(Path.join(tmp_dir, "tokens"))
      after
        Supervisor.stop(pid, :normal)
        File.rm_rf!(tmp_dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Config validation (exercised indirectly via init/1)
  # ---------------------------------------------------------------------------

  describe "validate_config graceful handling" do
    test "init succeeds when YellowDog.Config is not loaded" do
      # YellowDog.Config may not be available in the test environment,
      # and validate_config/0 handles this via Code.ensure_loaded check.
      assert {:ok, {_sup_flags, _children}} = IdentitySup.init([])
    end

    test "init always returns a valid supervisor spec regardless of config state" do
      # validate_config rescues exceptions from YellowDog.Config.get_all/0,
      # so init should always return a usable spec.
      assert {:ok, {sup_flags, children}} = IdentitySup.init([])
      assert sup_flags.strategy == :one_for_one
      assert length(children) == 2
    end

    test "init succeeds with invalid approval default_action (logs warning)" do
      original = Agent.get(YellowDog.Config, & &1)
      bad = Map.put(original, "identity", %{"approval" => %{"default_action" => "bogus"}})
      Agent.update(YellowDog.Config, fn _ -> bad end)
      on_exit(fn -> Agent.update(YellowDog.Config, fn _ -> original end) end)

      assert {:ok, {_sup, children}} = IdentitySup.init([])
      assert length(children) == 2
    end

    test "init succeeds when approval policy is missing name field (logs warning)" do
      original = Agent.get(YellowDog.Config, & &1)

      bad =
        Map.put(original, "identity", %{
          "approval" => %{
            "policies" => [%{"action" => "approve"}]
          }
        })

      Agent.update(YellowDog.Config, fn _ -> bad end)
      on_exit(fn -> Agent.update(YellowDog.Config, fn _ -> original end) end)

      assert {:ok, {_sup, children}} = IdentitySup.init([])
      assert length(children) == 2
    end

    test "init succeeds when cloud.aws.allowed_projects is not a list (logs warning)" do
      original = Agent.get(YellowDog.Config, & &1)

      bad =
        Map.put(original, "identity", %{
          "cloud" => %{"aws" => %{"allowed_projects" => "not-a-list"}}
        })

      Agent.update(YellowDog.Config, fn _ -> bad end)
      on_exit(fn -> Agent.update(YellowDog.Config, fn _ -> original end) end)

      assert {:ok, {_sup, children}} = IdentitySup.init([])
      assert length(children) == 2
    end

    test "init succeeds when webhook.url is not https (logs warning)" do
      original = Agent.get(YellowDog.Config, & &1)

      bad =
        Map.put(original, "identity", %{
          "webhook" => %{"url" => "ftp://not-valid"}
        })

      Agent.update(YellowDog.Config, fn _ -> bad end)
      on_exit(fn -> Agent.update(YellowDog.Config, fn _ -> original end) end)

      assert {:ok, {_sup, children}} = IdentitySup.init([])
      assert length(children) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir!(), "yd_sup_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
