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

  alias YellowDog.Dns.AclStore

  # Client API

  @doc """
  Starts the ACL registry.
  """
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

    state = %{
      acl_file: acl_file,
      acls: %{}
    }

    {:ok, load_acls(state)}
  end

  @impl true
  def handle_call(:list_acls, _from, state) do
    acls =
      state.acls
      |> Map.values()
      |> Enum.sort_by(& &1.name)

    {:reply, acls, state}
  end

  @impl true
  def handle_call({:get_acl, name}, _from, state) do
    case Map.get(state.acls, name) do
      nil -> {:reply, {:error, :not_found}, state}
      acl -> {:reply, {:ok, acl}, state}
    end
  end

  @impl true
  def handle_call({:create_acl, acl}, _from, state) do
    name = acl[:name] || acl["name"]

    if is_nil(name) or name == "" do
      {:reply, {:error, :invalid_name}, state}
    else
      if Map.has_key?(state.acls, name) do
        {:reply, {:error, :already_exists}, state}
      else
        normalized = normalize_acl(acl)
        new_state = put_in(state.acls[name], normalized)
        save_acls_async(new_state)
        {:reply, :ok, new_state}
      end
    end
  end

  @impl true
  def handle_call({:update_acl, name, acl}, _from, state) do
    if Map.has_key?(state.acls, name) do
      normalized = normalize_acl(Map.put(acl, :name, name))
      new_state = put_in(state.acls[name], normalized)
      save_acls_async(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:delete_acl, name}, _from, state) do
    if Map.has_key?(state.acls, name) do
      new_state = %{state | acls: Map.delete(state.acls, name)}
      save_acls_async(new_state)
      {:reply, :ok, new_state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:reload, _from, state) do
    {:reply, :ok, load_acls(state)}
  end

  # Private functions

  defp load_acls(%{acl_file: nil} = state), do: state

  defp load_acls(state) do
    case AclStore.load_acls(state.acl_file) do
      {:ok, acls} ->
        acls_map = Map.new(acls, fn acl -> {acl.name, acl} end)
        %{state | acls: acls_map}

      {:error, _reason} ->
        state
    end
  end

  defp save_acls_async(%{acl_file: nil}), do: :ok

  defp save_acls_async(state) do
    acls = Map.values(state.acls)
    acl_file = state.acl_file

    Task.start(fn ->
      case AclStore.save_acls(acl_file, acls) do
        :ok ->
          :ok

        {:error, reason} ->
          require Logger
          Logger.warning("Failed to save ACLs: #{inspect(reason)}")
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
