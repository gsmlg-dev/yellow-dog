defmodule YellowDog.Management.Netmans do
  @moduledoc """
  Durable registry for concrete managed Netman instances.
  """

  use Agent

  require Logger

  alias YellowDog.Management.Event
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.InputSanitizer
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Netman
  alias YellowDog.Management.Profiles
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath

  @default_max_records 1_000
  @registration_keys Enum.sort([
                       "apply_mode",
                       "features",
                       "id",
                       "last_seen_at",
                       "metadata",
                       "name",
                       "profile",
                       "registered_at",
                       "status",
                       "updated_at"
                     ])

  @type register_attrs :: map() | keyword() | Netman.t()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> load_state() end, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Clears the in-memory registry without deleting durable manifests."
  def reset, do: Agent.update(__MODULE__, fn _state -> %{netmans: %{}} end)

  @doc "Lists registered Netman instances sorted by id."
  def list do
    Agent.get(__MODULE__, fn %{netmans: netmans} ->
      netmans
      |> Map.values()
      |> Enum.sort_by(& &1.id)
    end)
  end

  @doc "Fetches a registered Netman by id."
  def get(id) do
    Agent.get(__MODULE__, fn %{netmans: netmans} -> fetch(netmans, id) end)
  end

  @doc "Registers or replaces a Netman record."
  def register(attrs) do
    with {:ok, netman} <- build_netman(attrs) do
      Agent.get_and_update(
        __MODULE__,
        fn state ->
          existing = Map.get(state.netmans, netman.id)

          if is_nil(existing) and map_size(state.netmans) >= max_records() do
            {{:error, :registry_full}, state}
          else
            netman = preserve_registration_time(netman, existing)

            event_attrs = %{
              source: :netman,
              source_id: netman.id,
              type: :netman_registered,
              message: "Netman registered"
            }

            with :ok <- persist_with_event(netman, event_attrs) do
              {{:ok, netman}, %{state | netmans: Map.put(state.netmans, netman.id, netman)}}
            else
              {:error, _reason} = error -> {error, state}
            end
          end
        end,
        :infinity
      )
    end
  end

  @doc "Updates a registered Netman status."
  def update_status(id, status) do
    Agent.get_and_update(
      __MODULE__,
      fn state ->
        case Map.fetch(state.netmans, id) do
          {:ok, netman} ->
            now = DateTime.utc_now(:second)
            status = InputSanitizer.status(status)
            updated = %{netman | status: status, last_seen_at: now, updated_at: now}

            event_attrs = %{
              source: :netman,
              source_id: id,
              type: :netman_status_updated,
              message: "Netman status updated",
              metadata: %{status: status}
            }

            with :ok <- persist_with_event(updated, event_attrs) do
              {{:ok, updated}, %{state | netmans: Map.put(state.netmans, updated.id, updated)}}
            else
              {:error, _reason} = error -> {error, state}
            end

          :error ->
            {{:error, :not_found}, state}
        end
      end,
      :infinity
    )
  end

  @doc false
  def events do
    EventStore.list()
    |> Enum.filter(&(&1.source == :netman))
  end

  defp load_state do
    netmans =
      with {:ok, root} <- StoragePath.root() do
        root
        |> Path.join("netmans/*/manifest.json")
        |> Path.wildcard()
        |> Enum.reduce(%{}, &load_manifest/2)
      else
        _error -> %{}
      end

    %{netmans: netmans}
  end

  defp load_manifest(path, netmans) do
    case AtomicJson.read(path) do
      {:ok, manifest} when is_map(manifest) ->
        case Map.fetch(manifest, "registration") do
          {:ok, registration} -> load_registration(registration, path, netmans)
          :error -> netmans
        end

      _invalid ->
        malformed_manifest(path, netmans)
    end
  end

  defp load_registration(registration, path, netmans) do
    case from_registration(registration, path) do
      {:ok, netman} -> Map.put(netmans, netman.id, netman)
      :error -> malformed_manifest(path, netmans)
    end
  end

  defp malformed_manifest(path, netmans) do
    Logger.warning("Ignoring malformed Netman registration manifest: #{path}")
    netmans
  end

  defp persist_with_event(netman, event_attrs) do
    with {:ok, path} <- StoragePath.netman_manifest(netman.id),
         {:ok, _event} <-
           ManifestStore.update_section_with(
             path,
             "registration",
             fn _current -> to_registration(netman) end,
             fn -> EventStore.append(event_attrs) end
           ) do
      :ok
    end
  end

  defp to_registration(netman) do
    %{
      "id" => netman.id,
      "name" => netman.name,
      "profile" => Atom.to_string(netman.profile),
      "apply_mode" => encode_apply_mode(netman.apply_mode),
      "status" => Event.encode_scalar(netman.status),
      "features" => Map.new(netman.features, fn {key, value} -> {Atom.to_string(key), value} end),
      "metadata" => Event.encode_metadata(netman.metadata),
      "last_seen_at" => Event.encode_datetime(netman.last_seen_at),
      "registered_at" => Event.encode_datetime(netman.registered_at),
      "updated_at" => Event.encode_datetime(netman.updated_at)
    }
  end

  defp from_registration(value, path) when is_map(value) do
    with true <- Enum.sort(Map.keys(value)) == @registration_keys,
         {:ok, id} <- InputSanitizer.required_string(value["id"], :id),
         {:ok, expected_path} <- StoragePath.netman_manifest(id),
         true <- expected_path == path,
         {:ok, name} <- decode_name(value["name"]),
         {:ok, profile} <- decode_profile(value["profile"]),
         {:ok, apply_mode} <- decode_apply_mode(value["apply_mode"]),
         {:ok, status} <- Event.decode_scalar(value["status"]),
         true <- InputSanitizer.status(status) == status,
         {:ok, features} <- decode_flags(value["features"], Profiles.netman_feature_keys()),
         {:ok, metadata} <- Event.decode_metadata(value["metadata"]),
         true <- InputSanitizer.metadata(metadata) == metadata,
         {:ok, last_seen_at} <- Event.decode_optional_datetime(value["last_seen_at"]),
         {:ok, registered_at} <- decode_required_datetime(value["registered_at"]),
         {:ok, updated_at} <- decode_required_datetime(value["updated_at"]) do
      {:ok,
       %Netman{
         id: id,
         name: name,
         profile: profile,
         apply_mode: apply_mode,
         status: status,
         features: features,
         metadata: metadata,
         last_seen_at: last_seen_at,
         registered_at: registered_at,
         updated_at: updated_at
       }}
    else
      _invalid -> :error
    end
  end

  defp from_registration(_value, _path), do: :error

  defp decode_name(nil), do: {:ok, nil}

  defp decode_name(value) when is_binary(value) do
    if InputSanitizer.optional_string(value) == value, do: {:ok, value}, else: :error
  end

  defp decode_name(_value), do: :error

  defp decode_profile(value) when is_binary(value) do
    case Enum.find(Profiles.list_netman_profiles(), &(Atom.to_string(&1.name) == value)) do
      nil -> :error
      profile -> {:ok, profile.name}
    end
  end

  defp decode_profile(_value), do: :error

  defp encode_apply_mode(nil), do: nil
  defp encode_apply_mode(mode), do: Atom.to_string(mode)

  defp decode_apply_mode(nil), do: {:ok, nil}
  defp decode_apply_mode("managed"), do: {:ok, :managed}
  defp decode_apply_mode("observe_first"), do: {:ok, :observe_first}
  defp decode_apply_mode("observe"), do: {:ok, :observe}
  defp decode_apply_mode(_mode), do: :error

  defp decode_flags(value, known_keys) when is_map(value) do
    known_by_name = Map.new(known_keys, &{Atom.to_string(&1), &1})

    if Enum.all?(value, fn {key, flag} ->
         Map.has_key?(known_by_name, key) and is_boolean(flag)
       end) do
      {:ok, Map.new(value, fn {key, flag} -> {Map.fetch!(known_by_name, key), flag} end)}
    else
      :error
    end
  end

  defp decode_flags(_value, _known_keys), do: :error

  defp decode_required_datetime(nil), do: :error
  defp decode_required_datetime(value), do: Event.decode_optional_datetime(value)

  defp fetch(records, id) do
    case Map.fetch(records, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  defp build_netman(%Netman{} = netman) do
    now = DateTime.utc_now(:second)

    with {:ok, id} <- InputSanitizer.required_string(netman.id, :id) do
      {:ok,
       %{
         netman
         | id: id,
           name: InputSanitizer.optional_string(netman.name),
           profile: normalize_profile(netman.profile),
           apply_mode: normalize_apply_mode(netman.apply_mode),
           status: InputSanitizer.status(netman.status),
           features: InputSanitizer.flags(netman.features, Profiles.netman_feature_keys()),
           metadata: InputSanitizer.metadata(netman.metadata),
           last_seen_at: InputSanitizer.datetime(netman.last_seen_at),
           registered_at: netman.registered_at || now,
           updated_at: netman.updated_at || now
       }}
    end
  end

  defp build_netman(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = attrs_map(attrs)
    now = DateTime.utc_now(:second)

    with {:ok, id} <- InputSanitizer.required_string(get_attr(attrs, :id), :id) do
      {:ok,
       %Netman{
         id: id,
         name: InputSanitizer.optional_string(get_attr(attrs, :name)),
         profile: normalize_profile(get_attr(attrs, :profile, :custom)),
         apply_mode: normalize_apply_mode(get_attr(attrs, :apply_mode)),
         status: InputSanitizer.status(get_attr(attrs, :status, :registered)),
         features:
           InputSanitizer.flags(get_attr(attrs, :features, %{}), Profiles.netman_feature_keys()),
         metadata: InputSanitizer.metadata(get_attr(attrs, :metadata, %{})),
         last_seen_at: InputSanitizer.datetime(get_attr(attrs, :last_seen_at)),
         registered_at: now,
         updated_at: now
       }}
    end
  end

  defp preserve_registration_time(netman, nil), do: netman

  defp preserve_registration_time(netman, existing) do
    %{netman | registered_at: existing.registered_at || netman.registered_at}
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp get_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp normalize_apply_mode(mode) when mode in [:managed, :observe_first, :observe], do: mode

  defp normalize_apply_mode(mode) when is_binary(mode) do
    case mode do
      "managed" -> :managed
      "observe_first" -> :observe_first
      "observe" -> :observe
      _mode -> nil
    end
  end

  defp normalize_apply_mode(_mode), do: nil

  defp normalize_profile(profile) when is_binary(profile) do
    Profiles.list_netman_profiles()
    |> Enum.find(&(Atom.to_string(&1.name) == profile))
    |> case do
      nil -> :custom
      profile -> profile.name
    end
  end

  defp normalize_profile(profile) when is_atom(profile) do
    if Enum.any?(Profiles.list_netman_profiles(), &(&1.name == profile)),
      do: profile,
      else: :custom
  end

  defp normalize_profile(_profile), do: :custom

  defp max_records do
    case Application.get_env(:yellow_dog_management_core, :max_netmans, @default_max_records) do
      limit when is_integer(limit) and limit in 1..@default_max_records -> limit
      _invalid -> @default_max_records
    end
  end
end
