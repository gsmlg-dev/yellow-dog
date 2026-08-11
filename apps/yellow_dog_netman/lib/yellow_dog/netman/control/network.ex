defmodule YellowDog.Netman.Control.Network do
  @moduledoc false

  alias YellowDog.Netman
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @connection_mutations ["netman.connections.activate", "netman.connections.deactivate"]
  @wire_scopes [:global, :link, :host]

  @spec current(String.t(), map()) :: {:ok, String.t() | :missing} | {:error, Error.t()}
  def current(operation, %{"profile_id" => profile_id}) when operation in @connection_mutations do
    case Netman.profile_revision(profile_id) do
      {:ok, revision} -> {:ok, revision}
      {:error, :not_found} -> {:ok, :missing}
      {:error, reason} -> adapter_error(reason)
    end
  end

  def current(_operation, _payload), do: unsupported_error()

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("netman.network.links.list", payload) do
    Netman.list_interfaces()
    |> Enum.map(&link_item/1)
    |> list_result(payload, "link_id")
  end

  def dispatch("netman.network.addresses.list", payload) do
    Netman.list_interfaces()
    |> Enum.flat_map(&address_items/1)
    |> list_result(payload, "link_id")
  end

  def dispatch("netman.network.routes.list", payload) do
    Netman.list_interfaces()
    |> Enum.flat_map(&route_items/1)
    |> list_result(payload, "link_id")
  end

  def dispatch(
        "netman.network.connection_state.get",
        %{"profile_id" => profile_id, "interface" => interface}
      ) do
    with {:ok, profile} <- Netman.get_profile(profile_id),
         {:ok, link} <- Netman.interface_info(interface),
         :ok <- ensure_matches(profile, link) do
      {:ok, connection_state(profile_id, interface)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch(_operation, _payload), do: unsupported_error()

  @spec dispatch(String.t(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch(
        "netman.connections.activate",
        %{"profile_id" => profile_id, "interface" => interface},
        context
      ) do
    with :ok <- ensure_owner_revision(profile_id, context),
         :ok <- Netman.activate_connection(profile_id, interface) do
      {:ok, connection_result(profile_id, interface, :activated)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch(
        "netman.connections.deactivate",
        %{"profile_id" => profile_id, "interface" => interface},
        context
      ) do
    with :ok <- ensure_owner_revision(profile_id, context),
         :ok <- Netman.deactivate_connection(profile_id, interface) do
      {:ok, connection_result(profile_id, interface, :deactivated)}
    else
      {:error, reason} -> adapter_error(reason)
    end
  end

  def dispatch(_operation, _payload, _context), do: unsupported_error()

  defp link_item(link) do
    %{
      "link_id" => link.interface,
      "name" => link.interface,
      "state" => encode_link_state(link.state)
    }
  end

  defp address_items(link) do
    case Netman.interface_info(link.interface) do
      {:ok, %{addresses: addresses}} ->
        addresses
        |> Enum.filter(&(&1.scope in @wire_scopes))
        |> Enum.map(fn address ->
          %{
            "link_id" => link.interface,
            "address" => encode_cidr(address.address, address.prefix_len),
            "scope" => Atom.to_string(address.scope)
          }
        end)

      {:error, _reason} ->
        []
    end
  end

  defp route_items(link) do
    case Netman.interface_info(link.interface) do
      {:ok, %{routes: routes}} ->
        Enum.map(routes, fn route ->
          %{
            "destination" => encode_destination(route.destination, route.family),
            "gateway" => route.gateway,
            "link_id" => link.interface
          }
        end)

      {:error, _reason} ->
        []
    end
  end

  defp list_result(items, payload, cursor_field) do
    items = Enum.sort_by(items, &{Map.fetch!(&1, cursor_field), &1})

    with {:ok, revision} <- Digest.calculate(items) do
      {:ok,
       %{
         "items" => page(items, payload, cursor_field),
         "revision" => revision,
         "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      _error -> internal_error()
    end
  end

  defp page(items, payload, cursor_field) do
    items =
      case Map.get(payload, "cursor") do
        nil -> items
        cursor -> Enum.drop_while(items, &(Map.fetch!(&1, cursor_field) <= cursor))
      end

    Enum.take(items, Map.get(payload, "limit", length(items)))
  end

  defp connection_state(profile_id, interface) do
    state =
      Netman.list_connections()
      |> Enum.find(&(&1.profile_id == profile_id and &1.interface == interface))
      |> case do
        nil -> :deactivated
        connection -> encode_connection_state(connection.state)
      end

    connection_result(profile_id, interface, state)
  end

  defp connection_result(profile_id, interface, state) do
    %{
      "profile_id" => profile_id,
      "interface" => interface,
      "state" => Atom.to_string(state)
    }
  end

  defp ensure_owner_revision(profile_id, %{precondition: {:revision, expected_revision}}) do
    case Netman.profile_revision(profile_id) do
      {:ok, ^expected_revision} -> :ok
      {:ok, current_revision} -> {:error, {:conflict, current_revision}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_owner_revision(_profile_id, _context), do: {:error, :invalid_revision}

  defp ensure_matches(%Profile{type: :ethernet, interface: nil}, %{kind: kind})
       when kind != "loopback",
       do: :ok

  defp ensure_matches(%Profile{type: :ethernet, interface: interface}, %{interface: interface}),
    do: :ok

  defp ensure_matches(_profile, _link), do: {:error, :no_matching_interface}

  defp encode_link_state(state) when state in [:up, :down, :unknown], do: Atom.to_string(state)
  defp encode_link_state(_state), do: "unknown"

  defp encode_connection_state(:activated), do: :activated
  defp encode_connection_state(:failed), do: :failed
  defp encode_connection_state(:unavailable), do: :failed
  defp encode_connection_state(_state), do: :deactivated

  defp encode_cidr(address, prefix_len) do
    if String.contains?(address, "/"), do: address, else: "#{address}/#{prefix_len}"
  end

  defp encode_destination("default", :inet6), do: "::/0"
  defp encode_destination("default", _family), do: "0.0.0.0/0"
  defp encode_destination(destination, _family), do: destination

  defp adapter_error(%Error{} = error), do: {:error, error}
  defp adapter_error(:not_found), do: not_found_error()
  defp adapter_error(:no_matching_interface), do: apply_failed_error()
  defp adapter_error({:activation_failed, _details}), do: apply_failed_error()
  defp adapter_error({:deactivation_failed, _details}), do: apply_failed_error()
  defp adapter_error({:activation_timeout, _details}), do: timeout_error()
  defp adapter_error({:deactivation_timeout, _details}), do: timeout_error()
  defp adapter_error({:conflict, _current_revision}), do: conflict_error()
  defp adapter_error(:invalid_revision), do: invalid_error()
  defp adapter_error(_reason), do: internal_error()

  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp conflict_error, do: {:error, Error.new(:conflict, "operation conflict", %{})}
  defp apply_failed_error, do: {:error, Error.new(:apply_failed, "apply failed", %{})}
  defp timeout_error, do: {:error, Error.new(:timeout, "operation timed out", %{})}

  defp unsupported_error,
    do: {:error, Error.new(:unsupported, "unsupported operation", %{})}

  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
