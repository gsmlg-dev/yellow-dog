defmodule YellowDog.ServerNetbootControlFake do
  @moduledoc false

  use Agent

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          responses: %{
            managed_snapshot: {:ok, %{"version" => 1, "profiles" => []}},
            device_snapshot: {:ok, []},
            asset_snapshot: {:ok, []},
            file_index_snapshot: [],
            clock: ~U[2026-07-17 00:00:00Z]
          },
          calls: []
        }
      end,
      name: __MODULE__
    )
  end

  def configure(responses) when is_map(responses) do
    Agent.update(__MODULE__, fn state ->
      %{state | responses: Map.merge(state.responses, responses)}
    end)
  end

  def take_calls do
    Agent.get_and_update(__MODULE__, fn state ->
      {Enum.reverse(state.calls), %{state | calls: []}}
    end)
  end

  def call(owner, function, arguments) do
    response =
      Agent.get_and_update(__MODULE__, fn state ->
        key = response_key(owner, function)
        value = Map.get(state.responses, key, {:error, :apply_failed})
        {value, %{state | calls: [{owner, function, arguments} | state.calls]}}
      end)

    run(response)
  end

  def packet_or_socket_calls, do: []

  defp response_key(:manifest_store, :managed_snapshot), do: :managed_snapshot
  defp response_key(:manifest_store, :put_managed_profile), do: :profile_put
  defp response_key(:manifest_store, :delete_managed_profile), do: :profile_delete
  defp response_key(:device_registry, :control_snapshot), do: :device_snapshot
  defp response_key(:device_registry, :control_put_device), do: :device_put
  defp response_key(:device_registry, :control_delete_device), do: :device_delete
  defp response_key(:asset_store, :control_snapshot), do: :asset_snapshot
  defp response_key(:asset_store, :control_rescan), do: :asset_rescan
  defp response_key(:file_index, :snapshot), do: :file_index_snapshot
  defp response_key(:clock, :utc_now), do: :clock

  defp run({:raise, reason}), do: raise(reason)
  defp run({:exit, reason}), do: exit(reason)
  defp run({:throw, reason}), do: throw(reason)
  defp run(value), do: value
end

defmodule YellowDog.ServerNetbootControlFake.ManifestStore do
  @moduledoc false

  def managed_snapshot,
    do: YellowDog.ServerNetbootControlFake.call(:manifest_store, :managed_snapshot, [])

  def put_managed_profile(profile),
    do:
      YellowDog.ServerNetbootControlFake.call(
        :manifest_store,
        :put_managed_profile,
        [profile]
      )

  def delete_managed_profile(profile_id),
    do:
      YellowDog.ServerNetbootControlFake.call(
        :manifest_store,
        :delete_managed_profile,
        [profile_id]
      )
end

defmodule YellowDog.ServerNetbootControlFake.ManagedProfile do
  @moduledoc false

  defstruct [:profile_id, :name, :boot_asset_id, :arguments]

  def from_wire(
        %{
          "profile_id" => profile_id,
          "name" => name,
          "boot_asset_id" => boot_asset_id,
          "arguments" => arguments
        } = wire
      )
      when map_size(wire) == 4 and is_list(arguments) do
    {:ok,
     %__MODULE__{
       profile_id: profile_id,
       name: name,
       boot_asset_id: boot_asset_id,
       arguments: arguments
     }}
  end

  def from_wire(_wire), do: {:error, :invalid_profile}

  def to_wire(%__MODULE__{} = profile) do
    %{
      "profile_id" => profile.profile_id,
      "name" => profile.name,
      "boot_asset_id" => profile.boot_asset_id,
      "arguments" => profile.arguments
    }
  end
end

defmodule YellowDog.ServerNetbootControlFake.DeviceRegistry do
  @moduledoc false

  def control_snapshot,
    do: YellowDog.ServerNetbootControlFake.call(:device_registry, :control_snapshot, [])

  def control_put_device(device_id, profile_id, mac),
    do:
      YellowDog.ServerNetbootControlFake.call(
        :device_registry,
        :control_put_device,
        [device_id, profile_id, mac]
      )

  def control_delete_device(device_id),
    do:
      YellowDog.ServerNetbootControlFake.call(
        :device_registry,
        :control_delete_device,
        [device_id]
      )
end

defmodule YellowDog.ServerNetbootControlFake.AssetStore do
  @moduledoc false

  def control_snapshot,
    do: YellowDog.ServerNetbootControlFake.call(:asset_store, :control_snapshot, [])

  def control_rescan(scope),
    do: YellowDog.ServerNetbootControlFake.call(:asset_store, :control_rescan, [scope])
end

defmodule YellowDog.ServerNetbootControlFake.FileIndex do
  @moduledoc false
  def snapshot, do: YellowDog.ServerNetbootControlFake.call(:file_index, :snapshot, [])
end

defmodule YellowDog.ServerNetbootControlFake.Clock do
  @moduledoc false
  def utc_now, do: YellowDog.ServerNetbootControlFake.call(:clock, :utc_now, [])
end

defmodule YellowDog.ServerNetbootControlFake.InternalUndefinedFunctionAssetStore do
  @moduledoc false

  def control_snapshot do
    apply(__MODULE__, :missing_internal_function, [])
  end
end
