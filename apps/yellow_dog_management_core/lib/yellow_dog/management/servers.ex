defmodule YellowDog.Management.Servers do
  @moduledoc """
  Durable registry for concrete managed server instances.
  """

  use Agent

  require Logger

  alias YellowDog.Management.Event
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.InputSanitizer
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Profiles
  alias YellowDog.Management.Server
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath

  @default_max_records 1_000
  @registration_keys Enum.sort([
                       "id",
                       "last_seen_at",
                       "metadata",
                       "name",
                       "profile",
                       "registered_at",
                       "services",
                       "status",
                       "updated_at"
                     ])

  @type register_attrs :: map() | keyword() | Server.t()

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
  def reset, do: Agent.update(__MODULE__, fn _state -> %{servers: %{}} end)

  @doc "Lists registered servers sorted by id."
  def list do
    Agent.get(__MODULE__, fn %{servers: servers} ->
      servers
      |> Map.values()
      |> Enum.sort_by(& &1.id)
    end)
  end

  @doc "Fetches a registered server by id."
  def get(id) do
    Agent.get(__MODULE__, fn %{servers: servers} -> fetch(servers, id) end)
  end

  @doc "Registers or replaces a server record."
  def register(attrs) do
    with {:ok, server} <- build_server(attrs) do
      Agent.get_and_update(
        __MODULE__,
        fn state ->
          existing = Map.get(state.servers, server.id)

          if is_nil(existing) and map_size(state.servers) >= max_records() do
            {{:error, :registry_full}, state}
          else
            server = preserve_registration_time(server, existing)

            event_attrs = %{
              source: :server,
              source_id: server.id,
              type: :server_registered,
              message: "Server registered"
            }

            with :ok <- persist_with_event(server, event_attrs) do
              {{:ok, server}, %{state | servers: Map.put(state.servers, server.id, server)}}
            else
              {:error, _reason} = error -> {error, state}
            end
          end
        end,
        :infinity
      )
    end
  end

  @doc "Updates a registered server status."
  def update_status(id, status) do
    Agent.get_and_update(
      __MODULE__,
      fn state ->
        case Map.fetch(state.servers, id) do
          {:ok, server} ->
            now = DateTime.utc_now(:second)
            status = InputSanitizer.status(status)
            updated = %{server | status: status, last_seen_at: now, updated_at: now}

            event_attrs = %{
              source: :server,
              source_id: id,
              type: :server_status_updated,
              message: "Server status updated",
              metadata: %{status: status}
            }

            with :ok <- persist_with_event(updated, event_attrs) do
              {{:ok, updated}, %{state | servers: Map.put(state.servers, updated.id, updated)}}
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
    |> Enum.filter(&(&1.source == :server))
  end

  defp load_state do
    servers =
      with {:ok, root} <- StoragePath.root() do
        root
        |> Path.join("servers/*/manifest.json")
        |> Path.wildcard()
        |> Enum.reduce(%{}, &load_manifest/2)
      else
        _error -> %{}
      end

    %{servers: servers}
  end

  defp load_manifest(path, servers) do
    case AtomicJson.read(path) do
      {:ok, manifest} when is_map(manifest) ->
        case Map.fetch(manifest, "registration") do
          {:ok, registration} -> load_registration(registration, path, servers)
          :error -> servers
        end

      _invalid ->
        malformed_manifest(path, servers)
    end
  end

  defp load_registration(registration, path, servers) do
    case from_registration(registration, path) do
      {:ok, server} -> Map.put(servers, server.id, server)
      :error -> malformed_manifest(path, servers)
    end
  end

  defp malformed_manifest(path, servers) do
    Logger.warning("Ignoring malformed server registration manifest: #{path}")
    servers
  end

  defp persist_with_event(server, event_attrs) do
    with {:ok, path} <- StoragePath.server_manifest(server.id),
         {:ok, _event} <-
           ManifestStore.update_section_with(
             path,
             "registration",
             fn _current -> to_registration(server) end,
             fn -> EventStore.append(event_attrs) end
           ) do
      :ok
    end
  end

  defp to_registration(server) do
    %{
      "id" => server.id,
      "name" => server.name,
      "profile" => Atom.to_string(server.profile),
      "status" => Event.encode_scalar(server.status),
      "services" => Map.new(server.services, fn {key, value} -> {Atom.to_string(key), value} end),
      "metadata" => Event.encode_metadata(server.metadata),
      "last_seen_at" => Event.encode_datetime(server.last_seen_at),
      "registered_at" => Event.encode_datetime(server.registered_at),
      "updated_at" => Event.encode_datetime(server.updated_at)
    }
  end

  defp from_registration(value, path) when is_map(value) do
    with true <- Enum.sort(Map.keys(value)) == @registration_keys,
         {:ok, id} <- InputSanitizer.required_string(value["id"], :id),
         {:ok, expected_path} <- StoragePath.server_manifest(id),
         true <- expected_path == path,
         {:ok, name} <- decode_name(value["name"]),
         {:ok, profile} <- decode_profile(value["profile"]),
         {:ok, status} <- Event.decode_scalar(value["status"]),
         true <- InputSanitizer.status(status) == status,
         {:ok, services} <- decode_flags(value["services"], Profiles.server_service_keys()),
         {:ok, metadata} <- Event.decode_metadata(value["metadata"]),
         true <- InputSanitizer.metadata(metadata) == metadata,
         {:ok, last_seen_at} <- Event.decode_optional_datetime(value["last_seen_at"]),
         {:ok, registered_at} <- decode_required_datetime(value["registered_at"]),
         {:ok, updated_at} <- decode_required_datetime(value["updated_at"]) do
      {:ok,
       %Server{
         id: id,
         name: name,
         profile: profile,
         status: status,
         services: services,
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
    case Enum.find(Profiles.list_server_profiles(), &(Atom.to_string(&1.name) == value)) do
      nil -> :error
      profile -> {:ok, profile.name}
    end
  end

  defp decode_profile(_value), do: :error

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

  defp build_server(%Server{} = server) do
    now = DateTime.utc_now(:second)

    with {:ok, id} <- InputSanitizer.required_string(server.id, :id) do
      {:ok,
       %{
         server
         | id: id,
           name: InputSanitizer.optional_string(server.name),
           profile: normalize_profile(server.profile),
           status: InputSanitizer.status(server.status),
           services: InputSanitizer.flags(server.services, Profiles.server_service_keys()),
           metadata: InputSanitizer.metadata(server.metadata),
           last_seen_at: InputSanitizer.datetime(server.last_seen_at),
           registered_at: server.registered_at || now,
           updated_at: server.updated_at || now
       }}
    end
  end

  defp build_server(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = attrs_map(attrs)
    now = DateTime.utc_now(:second)

    with {:ok, id} <- InputSanitizer.required_string(get_attr(attrs, :id), :id) do
      {:ok,
       %Server{
         id: id,
         name: InputSanitizer.optional_string(get_attr(attrs, :name)),
         profile: normalize_profile(get_attr(attrs, :profile, :custom)),
         status: InputSanitizer.status(get_attr(attrs, :status, :registered)),
         services:
           InputSanitizer.flags(get_attr(attrs, :services, %{}), Profiles.server_service_keys()),
         metadata: InputSanitizer.metadata(get_attr(attrs, :metadata, %{})),
         last_seen_at: InputSanitizer.datetime(get_attr(attrs, :last_seen_at)),
         registered_at: now,
         updated_at: now
       }}
    end
  end

  defp preserve_registration_time(server, nil), do: server

  defp preserve_registration_time(server, existing) do
    %{server | registered_at: existing.registered_at || server.registered_at}
  end

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp get_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp normalize_profile(profile) when is_binary(profile) do
    Profiles.list_server_profiles()
    |> Enum.find(&(Atom.to_string(&1.name) == profile))
    |> case do
      nil -> :custom
      profile -> profile.name
    end
  end

  defp normalize_profile(profile) when is_atom(profile) do
    if Enum.any?(Profiles.list_server_profiles(), &(&1.name == profile)),
      do: profile,
      else: :custom
  end

  defp normalize_profile(_profile), do: :custom

  defp max_records do
    case Application.get_env(:yellow_dog_management_core, :max_servers, @default_max_records) do
      limit when is_integer(limit) and limit in 1..@default_max_records -> limit
      _invalid -> @default_max_records
    end
  end
end
