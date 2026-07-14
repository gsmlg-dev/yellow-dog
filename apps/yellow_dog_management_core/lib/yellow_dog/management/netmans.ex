defmodule YellowDog.Management.Netmans do
  @moduledoc """
  In-memory registry for concrete managed Netman instances.
  """

  use Agent

  alias YellowDog.Management.Event
  alias YellowDog.Management.InputSanitizer
  alias YellowDog.Management.Netman
  alias YellowDog.Management.Profiles

  @max_events 500
  @max_records 1_000

  @type register_attrs :: map() | keyword() | Netman.t()

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
    Agent.get(__MODULE__, fn %{netmans: netmans} ->
      fetch(netmans, id)
    end)
  end

  @doc "Registers or replaces a Netman record."
  def register(attrs) do
    with {:ok, netman} <- build_netman(attrs) do
      Agent.get_and_update(__MODULE__, fn state ->
        existing = Map.get(state.netmans, netman.id)

        if is_nil(existing) and map_size(state.netmans) >= @max_records do
          {{:error, :registry_full}, state}
        else
          netman = preserve_registration_time(netman, existing)

          event =
            Event.new(%{
              source: :netman,
              source_id: netman.id,
              type: :netman_registered,
              message: "Netman registered"
            })

          state = %{
            state
            | netmans: Map.put(state.netmans, netman.id, netman),
              events: record_event(state.events, event)
          }

          {{:ok, netman}, state}
        end
      end)
    end
  end

  @doc "Updates a registered Netman status."
  def update_status(id, status) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.fetch(state.netmans, id) do
        {:ok, netman} ->
          now = DateTime.utc_now(:second)
          status = InputSanitizer.status(status)
          updated = %{netman | status: status, last_seen_at: now, updated_at: now}

          event =
            Event.new(%{
              source: :netman,
              source_id: id,
              type: :netman_status_updated,
              message: "Netman status updated",
              metadata: %{status: status}
            })

          state = %{
            state
            | netmans: Map.put(state.netmans, id, updated),
              events: record_event(state.events, event)
          }

          {{:ok, updated}, state}

        :error ->
          {{:error, :not_found}, state}
      end
    end)
  end

  @doc "Lists events recorded by the Netman registry."
  def events do
    Agent.get(__MODULE__, fn %{events: events} ->
      Enum.reverse(events)
    end)
  end

  defp initial_state, do: %{netmans: %{}, events: []}

  defp record_event(events, event) do
    [event | events]
    |> Enum.take(@max_events)
  end

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
end
