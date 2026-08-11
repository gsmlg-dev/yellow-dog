defmodule YellowDog.Netman.Control.Profiles do
  @moduledoc false

  alias YellowDog.Netman
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @profile_mutations [
    "netman.profiles.put",
    "netman.profiles.patch",
    "netman.profiles.delete",
    "netman.profiles.activate",
    "netman.profiles.rollback"
  ]

  @spec current(String.t(), map()) :: {:ok, String.t() | :missing} | {:error, Error.t()}
  def current("netman.profiles.replace", _payload) do
    Netman.profiles_revision()
  end

  def current(operation, %{"profile_id" => profile_id}) when operation in @profile_mutations do
    case Netman.profile_revision(profile_id) do
      {:ok, revision} -> {:ok, revision}
      {:error, :not_found} -> {:ok, :missing}
      {:error, reason} -> adapter_error(reason)
    end
  end

  def current(_operation, _payload), do: unsupported_error()

  @doc false
  @spec replacement_snapshot() :: {:ok, map(), String.t()} | {:error, Error.t()}
  def replacement_snapshot do
    {profiles, namespace_revision} = Netman.profiles_snapshot()

    profiles =
      Enum.map(profiles, &profile_to_wire/1)

    {:ok, %{"profiles" => profiles}, namespace_revision}
  rescue
    _exception -> internal_error()
  catch
    _kind, _reason -> internal_error()
  end

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("netman.profiles.list", payload) do
    {states, namespace_revision} = Netman.list_profile_states()

    items =
      states
      |> Enum.sort_by(& &1.profile.id)
      |> page(payload)
      |> Enum.map(&profile_state/1)

    {:ok, list_result(items, namespace_revision)}
  end

  def dispatch("netman.profiles.active_revision.get", %{"profile_id" => profile_id}) do
    with {:ok, state} <- Netman.profile_state(profile_id) do
      {:ok, revision_state(state)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch("netman.profiles.history.list", %{"profile_id" => profile_id}) do
    with {:ok, entries} <- Netman.profile_history(profile_id),
         items = Enum.map(entries, &history_item/1),
         {:ok, revision} <- Digest.calculate(items) do
      {:ok, list_result(items, revision)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch("netman.profiles.validate", payload) do
    case profile_from_wire(payload) do
      {:ok, profile} ->
        {:ok, %{"profile_id" => profile.id, "valid" => true, "errors" => []}}

      {:error, reason} ->
        {:ok,
         %{
           "profile_id" => Map.get(payload, "profile_id", "invalid"),
           "valid" => false,
           "errors" => [%{"field" => "profile", "message" => validation_message(reason)}]
         }}
    end
  end

  def dispatch(_operation, _payload), do: unsupported_error()

  @spec dispatch(String.t(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("netman.profiles.put", payload, context) do
    with {:ok, profile} <- profile_from_wire(payload),
         :ok <- Netman.put_profile(profile.id, profile, owner_options(context)),
         {:ok, state} <- Netman.profile_state(profile.id) do
      {:ok, profile_state(state)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch(
        "netman.profiles.patch",
        %{"profile_id" => profile_id, "changes" => changes},
        context
      ) do
    with {:ok, profile} <- Netman.get_profile(profile_id),
         {:ok, patched} <- patch_profile(profile, changes),
         :ok <- Netman.put_profile(profile_id, patched, owner_options(context)),
         {:ok, state} <- Netman.profile_state(profile_id) do
      {:ok, profile_state(state)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch("netman.profiles.delete", %{"profile_id" => profile_id}, context) do
    with {:ok, revision} <- Netman.profile_revision(profile_id),
         :ok <- Netman.delete_profile(profile_id, owner_options(context)) do
      {:ok,
       %{
         "resource_type" => "netman_profile",
         "resource_id" => profile_id,
         "resource_ref" => %{"profile_id" => profile_id},
         "revision" => revision
       }}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch("netman.profiles.activate", %{"profile_id" => profile_id}, _context) do
    with {:ok, connections} <- Netman.activate_with_results(profile_id),
         {:ok, state} <- Netman.profile_state(profile_id) do
      {:ok, activation_state(state, connections)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch(
        "netman.profiles.rollback",
        %{"profile_id" => profile_id, "target_revision" => target_revision},
        context
      ) do
    with {:ok, ^target_revision} <-
           Netman.rollback_profile(
             profile_id,
             target_revision,
             owner_options(context)
           ),
         {:ok, connections} <- Netman.activate_with_results(profile_id),
         {:ok, state} <- Netman.profile_state(profile_id) do
      {:ok, activation_state(state, connections)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch("netman.profiles.replace", %{"profiles" => profiles} = payload, context) do
    with true <- is_integer(context.config_version) and context.config_version > 0,
         {:ok, profiles} <- profiles_from_wire(profiles),
         {previous_states, _namespace_revision} = Netman.list_profile_states(),
         {:ok, applied_revision} <-
           Netman.replace_profiles(profiles, owner_options(context)),
         :ok <- converge_replacement(previous_states, profiles),
         {:ok, digest} <- Digest.calculate(payload) do
      {:ok,
       %{
         "state" => "applied",
         "version" => context.config_version,
         "digest" => digest,
         "applied_revision" => applied_revision,
         "previous_version" => nil,
         "previous_revision" => nil,
         "failure" => nil,
         "rollback" => nil
       }}
    else
      false -> invalid_error()
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch(_operation, _payload, _context), do: unsupported_error()

  defp converge_replacement(previous_states, profiles) do
    previous_revisions =
      Map.new(previous_states, fn state -> {state.profile.id, state.desired_revision} end)

    {current_states, _namespace_revision} = Netman.list_profile_states()
    current_revisions = Map.new(current_states, &{&1.profile.id, &1.desired_revision})

    stale_profile_ids =
      previous_revisions
      |> Enum.flat_map(fn {id, revision} ->
        if Map.get(current_revisions, id) == revision, do: [], else: [id]
      end)
      |> MapSet.new()

    with :ok <- stop_stale_connections(stale_profile_ids),
         :ok <- activate_autoconnect_profiles(profiles) do
      :ok
    end
  end

  defp stop_stale_connections(stale_profile_ids) do
    Netman.list_connections()
    |> Enum.filter(&MapSet.member?(stale_profile_ids, &1.profile_id))
    |> Enum.sort_by(& &1.interface)
    |> Enum.reduce_while(:ok, fn connection, :ok ->
      case Connection.Supervisor.stop_connection(connection.interface) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :apply_failed}}
      end
    end)
  end

  defp activate_autoconnect_profiles(profiles) do
    profiles
    |> Enum.filter(& &1.autoconnect)
    |> Enum.sort_by(&{-&1.autoconnect_priority, &1.id})
    |> Enum.reduce_while(:ok, fn profile, :ok ->
      case Netman.activate(profile.id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp owner_options(%{precondition: :must_be_missing}), do: [expected_revision: :missing]

  defp owner_options(%{precondition: {:revision, revision}}),
    do: [expected_revision: revision]

  defp page(profiles, payload) do
    profiles =
      case Map.get(payload, "cursor") do
        nil -> profiles
        cursor -> Enum.drop_while(profiles, &(&1.profile.id <= cursor))
      end

    Enum.take(profiles, Map.get(payload, "limit", length(profiles)))
  end

  defp profile_state(state) do
    %{
      "profile" => profile_to_wire(state.profile),
      "desired_revision" => state.desired_revision,
      "active_revision" => state.active_revision
    }
  end

  defp revision_state(state) do
    %{
      "profile_id" => state.profile.id,
      "desired_revision" => state.desired_revision,
      "active_revision" => state.active_revision
    }
  end

  defp activation_state(state, connections) do
    %{
      "profile_id" => state.profile.id,
      "desired_revision" => state.desired_revision,
      "active_revision" => state.active_revision,
      "state" => "activated",
      "connections" =>
        connections
        |> Enum.sort_by(& &1.interface)
        |> Enum.map(fn connection ->
          %{
            "profile_id" => connection.profile_id,
            "interface" => connection.interface,
            "state" => Atom.to_string(connection.state)
          }
        end)
    }
  end

  defp history_item(entry) do
    %{
      "profile_id" => entry.profile_id,
      "revision" => entry.revision,
      "profile" => profile_to_wire(entry.profile),
      "stored_at" => DateTime.to_iso8601(entry.stored_at),
      "activated_at" => encode_datetime(entry.activated_at)
    }
  end

  defp list_result(items, revision) do
    %{
      "items" => items,
      "revision" => revision,
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp profiles_from_wire(profiles) when is_list(profiles) do
    Enum.reduce_while(profiles, {:ok, []}, fn value, {:ok, decoded} ->
      case profile_from_wire(value) do
        {:ok, profile} -> {:cont, {:ok, [profile | decoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp profiles_from_wire(_profiles), do: {:error, :invalid_profiles}

  defp profile_from_wire(profile) when is_map(profile) do
    toml = %{
      "connection" => %{
        "id" => Map.get(profile, "profile_id"),
        "type" => Map.get(profile, "type"),
        "interface" => Map.get(profile, "interface"),
        "autoconnect" => Map.get(profile, "autoconnect"),
        "autoconnect_priority" => Map.get(profile, "autoconnect_priority"),
        "zone" => Map.get(profile, "zone")
      },
      "ethernet" => Map.get(profile, "ethernet", %{}),
      "ipv4" => Map.get(profile, "ipv4", %{}),
      "ipv6" => Map.get(profile, "ipv6", %{})
    }

    Profile.from_toml(toml)
  end

  defp profile_from_wire(_profile), do: {:error, :invalid_profile}

  defp profile_to_wire(%Profile{} = profile) do
    %{
      "profile_id" => profile.id,
      "type" => Atom.to_string(profile.type),
      "interface" => profile.interface,
      "autoconnect" => profile.autoconnect,
      "autoconnect_priority" => profile.autoconnect_priority,
      "zone" => profile.zone,
      "ethernet" => %{"mtu" => profile.ethernet.mtu},
      "ipv4" => ip_to_wire(profile.ipv4),
      "ipv6" => ip_to_wire(profile.ipv6)
    }
  end

  defp ip_to_wire(config) do
    %{
      "method" => config.method |> Atom.to_string() |> String.replace("_", "-"),
      "address" => config.address,
      "gateway" => config.gateway,
      "dns" => config.dns,
      "dns_search" => config.dns_search
    }
  end

  defp patch_profile(profile, changes) when is_list(changes) do
    patched = Enum.reduce(changes, profile_to_wire(profile), &apply_change/2)
    profile_from_wire(patched)
  end

  defp patch_profile(_profile, _changes), do: {:error, :invalid_profile}

  defp apply_change(%{"field" => field, "value" => value}, profile)
       when field in ["interface", "autoconnect", "autoconnect_priority", "zone", "ipv4", "ipv6"] do
    Map.put(profile, field, value)
  end

  defp apply_change(%{"field" => "ethernet.mtu", "value" => value}, profile) do
    put_in(profile, ["ethernet", "mtu"], value)
  end

  defp apply_change(_change, profile), do: profile

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp validation_message(reason) when is_binary(reason), do: reason
  defp validation_message(_reason), do: "invalid profile"

  defp adapter_error(%Error{} = error), do: {:error, error}
  defp adapter_error(:not_found), do: not_found_error()
  defp adapter_error(:revision_not_found), do: not_found_error()
  defp adapter_error({:conflict, _revision}), do: conflict_error()

  defp adapter_error(reason)
       when reason in [
              :invalid_id,
              :invalid_options,
              :invalid_profile,
              :invalid_profiles,
              :invalid_revision,
              :profile_id_mismatch
            ],
       do: invalid_error()

  defp adapter_error(reason)
       when reason in [:apply_failed, :no_matching_interface, :not_connected, :timeout],
       do: apply_failed_error()

  defp adapter_error({:activation_failed, _details}), do: apply_failed_error()
  defp adapter_error({:activation_timeout, _details}), do: timeout_error()
  defp adapter_error({:invalid_profile, _reason}), do: invalid_error()
  defp adapter_error(_reason), do: internal_error()

  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp conflict_error, do: {:error, Error.new(:conflict, "operation conflict", %{})}
  defp apply_failed_error, do: {:error, Error.new(:apply_failed, "apply failed", %{})}
  defp timeout_error, do: {:error, Error.new(:timeout, "operation timed out", %{})}
  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
