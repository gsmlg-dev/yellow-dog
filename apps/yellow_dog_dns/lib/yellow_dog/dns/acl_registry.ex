defmodule YellowDog.Dns.AclRegistry do
  @moduledoc """
  Registry for managing custom named ACLs.

  Provides runtime management of named ACL definitions that can be
  referenced by DNS views for access control.

  ## Usage

      # List all named ACLs
      AclRegistry.list_acls()

      # Get a specific ACL
      AclRegistry.get_acl("internal")

      # Create a new ACL
      AclRegistry.create_acl(%{
        name: "internal",
        description: "Internal network clients",
        rules: [
          %{action: "allow", network: "10.0.0.0/8"},
          %{action: "allow", network: "192.168.0.0/16"}
        ]
      })

      # Delete an ACL
      AclRegistry.delete_acl("internal")
  """

  use GenServer
  use YellowDog.Data.Collection

  require Logger

  alias YellowDog.Dns.AclStore
  alias YellowDog.Data.Store

  defcollection(:dns_acls,
    key_field: :name,
    adapter: YellowDog.Data.Store.Ets
  )

  # Client API

  @doc """
  Starts the ACL registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Lists all named ACLs.
  """
  @spec list_acls() :: [map()]
  def list_acls do
    GenServer.call(__MODULE__, :list_acls)
  end

  @doc """
  Gets a named ACL by name.
  """
  @spec get_acl(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_acl(name) do
    GenServer.call(__MODULE__, {:get_acl, name})
  end

  @doc """
  Creates a new named ACL.
  """
  @spec create_acl(map()) :: :ok | {:error, term()}
  def create_acl(acl) do
    GenServer.call(__MODULE__, {:create_acl, acl})
  end

  @doc """
  Updates an existing named ACL.
  """
  @spec update_acl(String.t(), map()) :: :ok | {:error, term()}
  def update_acl(name, acl) do
    GenServer.call(__MODULE__, {:update_acl, name, acl})
  end

  @doc """
  Deletes a named ACL.
  """
  @spec delete_acl(String.t()) :: :ok | {:error, :not_found}
  def delete_acl(name) do
    GenServer.call(__MODULE__, {:delete_acl, name})
  end

  @doc """
  Reloads ACLs from the configuration file.
  """
  @spec reload() :: :ok
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    acl_file = Keyword.get(opts, :acl_file)

    {:ok, store} =
      Store.init(collection(), table_name: :"dns_acls_#{:erlang.unique_integer([:positive])}")

    state = %{
      acl_file: acl_file,
      store: store
    }

    {:ok, load_acls(state)}
  end

  @impl true
  def handle_call(:list_acls, _from, state) do
    {:ok, acls} = Store.list(state.store)
    {:reply, Enum.sort_by(acls, & &1.name), state}
  end

  @impl true
  def handle_call({:get_acl, name}, _from, state) do
    {:reply, Store.get(state.store, name), state}
  end

  @impl true
  def handle_call({:create_acl, acl}, _from, state) do
    name = acl[:name] || acl["name"]

    if is_nil(name) or name == "" do
      {:reply, {:error, :invalid_name}, state}
    else
      if Store.exists?(state.store, name) do
        {:reply, {:error, :already_exists}, state}
      else
        normalized = normalize_acl(acl)
        {:ok, store} = Store.put(state.store, name, normalized)
        new_state = %{state | store: store}
        save_acls_async(new_state)
        {:reply, :ok, new_state}
      end
    end
  end

  @impl true
  def handle_call({:update_acl, name, acl}, _from, state) do
    if Store.exists?(state.store, name) do
      normalized = normalize_acl(Map.put(acl, :name, name))
      {:ok, store} = Store.put(state.store, name, normalized)
      new_state = %{state | store: store}
      save_acls_async(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_acl, name}, _from, state) do
    if Store.exists?(state.store, name) do
      {:ok, store} = Store.delete(state.store, name)
      new_state = %{state | store: store}
      save_acls_async(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, %{acl_file: nil} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:ok, store} = Store.clear(state.store)
    {:reply, :ok, load_acls(%{state | store: store})}
  end

  # Private functions

  defp load_acls(%{acl_file: nil} = state), do: state

  defp load_acls(state) do
    case AclStore.load_acls(state.acl_file) do
      {:ok, acls} ->
        store =
          Enum.reduce(acls, state.store, fn acl, acc ->
            {:ok, acc} = Store.put(acc, acl.name, acl)
            acc
          end)

        %{state | store: store}

      {:error, _reason} ->
        state
    end
  end

  defp save_acls_async(%{acl_file: nil}), do: :ok

  defp save_acls_async(state) do
    {:ok, acls} = Store.list(state.store)
    acl_file = state.acl_file

    Task.start(fn ->
      case AclStore.save_acls(acl_file, acls) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to save ACLs", error: inspect(reason))
      end
    end)
  end

  defp normalize_acl(acl) do
    %{
      name: acl[:name] || acl["name"],
      description: acl[:description] || acl["description"] || "",
      rules: normalize_rules(acl[:rules] || acl["rules"] || [])
    }
  end

  defp normalize_rules(rules) when is_list(rules) do
    Enum.map(rules, &normalize_rule/1)
  end

  defp normalize_rules(_), do: []

  defp normalize_rule(rule) when is_map(rule) do
    base = %{
      action: rule[:action] || rule["action"] || "allow"
    }

    geo_countries = rule[:geo_countries] || rule["geo_countries"]
    network = rule[:network] || rule["network"]

    cond do
      is_list(geo_countries) and geo_countries != [] ->
        Map.put(base, :geo_countries, geo_countries)

      is_binary(network) and network != "" ->
        Map.put(base, :network, network)

      true ->
        base
    end
  end

  defp normalize_rule(_), do: %{action: "allow"}
end
