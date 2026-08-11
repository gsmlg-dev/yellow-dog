defmodule YellowDog.Netman.Control.DhcpClient do
  @moduledoc false

  alias YellowDog.DhcpClient.Lease
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @test_environment Mix.env() == :test
  @release_operation "netman.dhcp_client.connections.release_lease"
  @fsm_states [:init, :selecting, :requesting, :bound, :renewing, :rebinding]

  @spec current(String.t(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def current(@release_operation, payload) do
    with {:ok, snapshot} <- owned_snapshot(payload),
         {:ok, state} <- encode_state(snapshot.state),
         {:ok, lease} <- active_lease(snapshot),
         {:ok, revision} <- release_revision(payload, state, lease) do
      {:ok, revision}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> adapter_error(reason)
    end
  end

  def current(_operation, _payload), do: unsupported_error()

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("netman.dhcp_client.fsm.get", payload) do
    with {:ok, snapshot} <- owned_snapshot(payload),
         {:ok, state} <- encode_state(snapshot.state) do
      {:ok,
       %{
         "profile_id" => payload["profile_id"],
         "interface" => payload["interface"],
         "state" => state
       }}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch("netman.dhcp_client.leases.list", _payload) do
    items =
      netman().list_connections()
      |> Enum.flat_map(&lease_item/1)
      |> Enum.sort_by(&{&1["profile_id"], &1["interface"]})

    with {:ok, revision} <- Digest.calculate(items) do
      {:ok,
       %{
         "items" => items,
         "revision" => revision,
         "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      _error -> internal_error()
    end
  end

  def dispatch(_operation, _payload), do: unsupported_error()

  @spec dispatch(String.t(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch(@release_operation, payload, context) do
    with {:ok, expected_revision} <- owner_revision(context),
         {:ok, snapshot} <- owned_snapshot(payload),
         {:ok, state} <- encode_state(snapshot.state),
         {:ok, lease} <- active_lease(snapshot),
         {:ok, ^expected_revision} <- release_revision(payload, state, lease),
         :ok <- dhcp_client().release(payload["interface"]) do
      {:ok,
       %{
         "family" => "ipv4",
         "lease_id" => payload["profile_id"] <> "." <> payload["interface"],
         "address" => encode_ip(lease.ip),
         "released" => true
       }}
    else
      {:ok, _current_revision} -> conflict_error()
      {:error, %Error{}} = error -> error
      {:error, reason} -> adapter_error(reason)
      _other -> internal_error()
    end
  end

  def dispatch(_operation, _payload, _context), do: unsupported_error()

  defp owned_snapshot(%{"profile_id" => profile_id, "interface" => interface}) do
    if Enum.any?(netman().list_connections(), &owned_connection?(&1, profile_id, interface)) do
      case dhcp_client().connection(interface) do
        {:ok, %{interface: ^interface} = snapshot} -> {:ok, snapshot}
        {:error, reason} -> {:error, reason}
        _other -> {:error, :invalid_snapshot}
      end
    else
      {:error, :not_found}
    end
  end

  defp owned_snapshot(_payload), do: {:error, :invalid_payload}

  defp owned_connection?(connection, profile_id, interface) when is_map(connection) do
    value(connection, :profile_id) == profile_id and value(connection, :interface) == interface
  end

  defp owned_connection?(_connection, _profile_id, _interface), do: false

  defp lease_item(connection) when is_map(connection) do
    profile_id = value(connection, :profile_id)
    interface = value(connection, :interface)

    with true <- is_binary(profile_id) and is_binary(interface),
         {:ok, %{state: snapshot_state, lease: lease}} <- dhcp_client().connection(interface),
         {:ok, state} <- encode_state(snapshot_state),
         {:ok, lease} <- active_lease(%{lease: lease}),
         %DateTime{} = expires_at <- Lease.expires_at(lease),
         {:ok, revision} <-
           release_revision(%{"profile_id" => profile_id, "interface" => interface}, state, lease) do
      [
        %{
          "profile_id" => profile_id,
          "interface" => interface,
          "address" => encode_ip(lease.ip),
          "expires_at" => DateTime.to_iso8601(expires_at),
          "revision" => revision
        }
      ]
    else
      _not_active -> []
    end
  end

  defp lease_item(_connection), do: []

  defp active_lease(%{lease: %Lease{ip: ip} = lease}) when is_tuple(ip) do
    if Lease.valid?(lease), do: {:ok, lease}, else: {:error, :not_found}
  end

  defp active_lease(_snapshot), do: {:error, :not_found}

  defp release_revision(payload, state, lease) do
    Digest.calculate(%{
      "profile_id" => payload["profile_id"],
      "interface" => payload["interface"],
      "state" => state,
      "address" => encode_ip(lease.ip),
      "expires_at" => encode_datetime(Lease.expires_at(lease))
    })
  end

  defp encode_state(state) when state in @fsm_states, do: {:ok, Atom.to_string(state)}
  defp encode_state(_state), do: {:error, :invalid_state}

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(nil), do: nil
  defp encode_ip(address), do: address |> :inet.ntoa() |> List.to_string()

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp owner_revision(%{precondition: {:revision, revision}}) when is_binary(revision),
    do: {:ok, revision}

  defp owner_revision(_context), do: invalid_error()

  if @test_environment do
    defp netman, do: dependency(:netman, YellowDog.Netman)
    defp dhcp_client, do: dependency(:dhcp_client, YellowDog.DhcpClient)

    defp dependency(key, default) do
      case Application.get_env(:yellow_dog_netman, __MODULE__, []) do
        config when is_list(config) -> Keyword.get(config, key, default)
        _invalid -> default
      end
    end
  else
    defp netman, do: YellowDog.Netman
    defp dhcp_client, do: YellowDog.DhcpClient
  end

  defp adapter_error(%Error{} = error), do: {:error, error}
  defp adapter_error(:not_found), do: not_found_error()

  defp adapter_error(reason)
       when reason in [:invalid_payload, :invalid_snapshot, :invalid_state],
       do: invalid_error()

  defp adapter_error(_reason), do: internal_error()

  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp conflict_error, do: {:error, Error.new(:conflict, "operation conflict", %{})}

  defp unsupported_error,
    do: {:error, Error.new(:unsupported, "unsupported operation", %{})}

  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
