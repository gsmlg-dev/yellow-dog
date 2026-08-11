defmodule YellowDog.ServerAgent.BootConfigTest do
  use ExUnit.Case, async: false

  alias YellowDog.ServerAgent.BootConfig
  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope

  @server_id "server-east-1"
  @profile "dns_only"
  @operation "server.settings.update"
  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-boot-config-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf(data_dir) end)
    %{data_dir: data_dir}
  end

  test "selects the exact acknowledged applied known-good revision", %{data_dir: data_dir} do
    {apply_store, config_store, _first} = applied_store(data_dir)
    stop(apply_store)
    stop(config_store)

    assert {:ok, @revision_a} = BootConfig.select(data_dir, @server_id)
  end

  test "selects acknowledged known-good instead of a newer installed applying candidate", %{
    data_dir: data_dir
  } do
    {apply_store, config_store, first} = applied_store(data_dir)
    drain(apply_store)
    second = envelope(2, expected_revision: @revision_a)
    candidate = stage(second, config_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:before_validate, %{version: 2}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:before_install, %{version: 2}, apply_store)

    assert {:ok, applying} =
             ConfigApplyStore.transition(
               :before_activate,
               %{version: 2, installed_revision: @revision_b},
               apply_store
             )

    assert applying.known_good.revision == @revision_a
    assert applying.attempt.installed_revision == @revision_b
    assert applying.attempt.digest == second.payload_digest
    refute applying.attempt.digest == first.payload_digest
    stop(apply_store)
    stop(config_store)

    assert {:ok, @revision_a} = BootConfig.select(data_dir, @server_id)
    refute BootConfig.select(data_dir, @server_id) == {:ok, @revision_b}
  end

  test "unknown side-effect state falls back to its acknowledged known-good revision", %{
    data_dir: data_dir
  } do
    {apply_store, config_store, _first} = applied_store(data_dir)
    drain(apply_store)
    second = envelope(2, expected_revision: @revision_a)
    candidate = stage(second, config_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:before_validate, %{version: 2}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:before_install, %{version: 2}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(
               :before_activate,
               %{version: 2, installed_revision: @revision_b},
               apply_store
             )

    assert {:ok, unknown} =
             ConfigApplyStore.transition(
               :uncertain_after_side_effect,
               %{version: 2},
               apply_store
             )

    assert unknown.runtime_status == :unknown
    assert unknown.known_good.revision == @revision_a
    stop(apply_store)
    stop(config_store)

    assert {:ok, @revision_a} = BootConfig.select(data_dir, @server_id)
    refute BootConfig.select(data_dir, @server_id) == {:ok, @revision_b}
  end

  test "corrupt apply journal returns a safe error", %{data_dir: data_dir} do
    {apply_store, config_store, _first} = applied_store(data_dir)
    stop(apply_store)
    stop(config_store)
    File.write!(apply_state_path(data_dir), "{")

    assert {:error, :corrupt} = BootConfig.select(data_dir, @server_id)
  end

  test "target-mismatched apply journal returns a safe error", %{data_dir: data_dir} do
    {apply_store, config_store, _first} = applied_store(data_dir)
    stop(apply_store)
    stop(config_store)

    rewrite(apply_state_path(data_dir), &Map.put(&1, "target_id", "server-west-1"))

    assert {:error, :corrupt} = BootConfig.select(data_dir, @server_id)
  end

  test "does not follow a symlinked apply journal", %{data_dir: data_dir} do
    {apply_store, config_store, _first} = applied_store(data_dir)
    stop(apply_store)
    stop(config_store)
    path = apply_state_path(data_dir)
    outside = Path.join(data_dir, "outside-apply-state.json")
    File.rename!(path, outside)
    File.ln_s!(outside, path)

    assert {:error, :corrupt} = BootConfig.select(data_dir, @server_id)
    assert File.read!(outside) =~ @revision_a
  end

  test "absent journal returns no managed config without creating directories or processes", %{
    data_dir: data_dir
  } do
    server_dir = Path.join(data_dir, "server")
    refute File.exists?(server_dir)

    assert :no_managed_config = BootConfig.select(data_dir, @server_id)
    refute File.exists?(server_dir)
    refute Process.whereis(BootConfig)
  end

  test "unknown state without acknowledged known-good returns no managed config", %{
    data_dir: data_dir
  } do
    {apply_store, config_store} = start_stores(data_dir)
    first = envelope(1)
    candidate = stage(first, config_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:before_validate, %{version: 1}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:before_install, %{version: 1}, apply_store)

    assert {:ok, unknown} =
             ConfigApplyStore.transition(
               :uncertain_after_side_effect,
               %{version: 1},
               apply_store
             )

    assert unknown.runtime_status == :unknown
    assert unknown.known_good == nil
    stop(apply_store)
    stop(config_store)

    assert :no_managed_config = BootConfig.select(data_dir, @server_id)
  end

  defp applied_store(data_dir) do
    {apply_store, config_store} = start_stores(data_dir)
    first = envelope(1)
    candidate = stage(first, config_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:before_validate, %{version: 1}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(:before_install, %{version: 1}, apply_store)

    assert {:ok, _snapshot} =
             ConfigApplyStore.transition(
               :before_activate,
               %{version: 1, installed_revision: @revision_a},
               apply_store
             )

    assert {:ok, applied} =
             ConfigApplyStore.transition(:applied, %{version: 1}, apply_store)

    assert applied.known_good.revision == @revision_a
    {apply_store, config_store, first}
  end

  defp start_stores(data_dir) do
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}

    config_store =
      start_supervised!(%{
        id: make_ref(),
        start:
          {ConfigStore, :start_link,
           [[name: name, data_dir: data_dir, server_id: @server_id, profile: @profile]]}
      })

    apply_store =
      start_supervised!(%{
        id: make_ref(),
        start:
          {ConfigApplyStore, :start_link,
           [
             [
               name: nil,
               data_dir: data_dir,
               server_id: @server_id,
               profile: @profile,
               config_store: name
             ]
           ]}
      })

    {apply_store, config_store}
  end

  defp stage(delivery, config_store) do
    assert {:ok, candidate} = ConfigStore.stage(delivery, config_store)
    candidate
  end

  defp drain(store) do
    assert {:ok, publications} = ConfigApplyStore.pending_publications(store)

    for publication <- publications do
      assert {:ok, _snapshot} =
               ConfigApplyStore.acknowledge_publication(publication.sequence, store)
    end
  end

  defp envelope(version, opts \\ []) do
    payload = %{
      "service" => "dns",
      "entries" => [
        %{"key" => "timeout", "value" => %{"type" => "integer", "value" => version}}
      ]
    }

    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: uuid(version),
      target_type: :server,
      target_id: @server_id,
      operation: @operation,
      idempotency_key: uuid(version + 100),
      payload: payload,
      payload_digest: digest,
      expected_revision: Keyword.get(opts, :expected_revision),
      config_version: version,
      sent_at: ~U[2026-08-11 08:00:00Z]
    }
  end

  defp rewrite(path, mutation) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> mutation.()
    |> then(&File.write!(path, Jason.encode!(&1)))
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  end

  defp apply_state_path(data_dir), do: Path.join([data_dir, "server", "apply_state.json"])

  defp uuid(value) do
    leading = value |> Integer.to_string(16) |> String.pad_leading(8, "0")
    "#{leading}-1111-4111-8111-111111111111"
  end
end
