defmodule YellowDog.Management.Servers do
  @moduledoc """
  In-memory registry for concrete managed server instances.
  """

  use Agent

  alias YellowDog.Management.Event
  alias YellowDog.Management.Profiles
  alias YellowDog.Management.Server

  @type register_attrs :: map() | keyword() | Server.t()

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> initial_state() end, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Clears the in-memory registry. Intended for focused tests."
  def reset do
    Agent.update(__MODULE__, fn _state -> initial_state() end)
  end

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
    Agent.get(__MODULE__, fn %{servers: servers} ->
      fetch(servers, id)
    end)
  end

  @doc "Registers or replaces a server record."
  def register(attrs) do
    with {:ok, server} <- build_server(attrs) do
      Agent.get_and_update(__MODULE__, fn state ->
        server = preserve_registration_time(server, Map.get(state.servers, server.id))

        event =
          Event.new(%{
            source: :server,
            source_id: server.id,
            type: :server_registered,
            message: "Server registered"
          })

        state = %{
          state
          | servers: Map.put(state.servers, server.id, server),
            events: [event | state.events]
        }

        {{:ok, server}, state}
      end)
    end
  end

  @doc "Updates a registered server status."
  def update_status(id, status) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.servers, id) do
        {:ok, server} ->
          now = DateTime.utc_now(:second)
          updated = %{server | status: status, last_seen_at: now, updated_at: now}

          event =
            Event.new(%{
              source: :server,
              source_id: id,
              type: :server_status_updated,
              message: "Server status updated",
              metadata: %{status: status}
            })

          state = %{
            state
            | servers: Map.put(state.servers, id, updated),
              events: [event | state.events]
          }

          {{:ok, updated}, state}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  @doc "Lists events recorded by the server registry."
  def events do
    Agent.get(__MODULE__, fn %{events: events} ->
      Enum.reverse(events)
    end)
  end

  defp initial_state, do: %{servers: %{}, events: []}

  defp fetch(records, id) do
    case Map.fetch(records, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  defp build_server(%Server{} = server) do
    now = DateTime.utc_now(:second)

    {:ok,
     %{
       server
       | profile: normalize_profile(server.profile),
         registered_at: server.registered_at || now,
         updated_at: server.updated_at || now
     }}
  end

  defp build_server(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = attrs_map(attrs)
    now = DateTime.utc_now(:second)

    with {:ok, id} <- fetch_required_string(attrs, :id) do
      {:ok,
       %Server{
         id: id,
         name: get_attr(attrs, :name),
         profile: normalize_profile(get_attr(attrs, :profile, :custom)),
         status: get_attr(attrs, :status, :registered),
         services: get_attr(attrs, :services, %{}),
         metadata: get_attr(attrs, :metadata, %{}),
         last_seen_at: get_attr(attrs, :last_seen_at),
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

  defp fetch_required_string(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:required, key}}
    end
  end

  defp get_attr(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp normalize_profile(profile) when is_binary(profile) do
    Profiles.list_server_profiles()
    |> Enum.find(&(Atom.to_string(&1.name) == profile))
    |> case do
      nil -> profile
      profile -> profile.name
    end
  end

  defp normalize_profile(profile), do: profile
end
