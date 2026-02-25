defmodule YellowDog.Data.Resource do
  @moduledoc """
  Facade for resource management CRUD operations.

  Provides a unified API for creating, reading, updating, and deleting
  resource entities (Hardware, Identity, Ownership, NetworkResource).
  Each entity type has its own Store.Ets collection for independent storage.

  ## Usage

      # Initialize stores (typically done in supervision tree)
      {:ok, stores} = Resource.init_stores()

      # Hardware CRUD
      {:ok, hw} = Resource.create_hardware(%{id: "srv-01", mac: "AA:BB:CC:DD:EE:FF"})
      {:ok, hw} = Resource.get_hardware("srv-01")
      {:ok, hw} = Resource.update_hardware("srv-01", %{hostname: "web-1"})
      :ok = Resource.delete_hardware("srv-01")

      # Identity CRUD
      {:ok, id} = Resource.create_identity(%{id: "alice", name: "Alice"})

      # Ownership links
      {:ok, link} = Resource.assign_hardware("alice", "srv-01")
      links = Resource.list_hardware_for_identity("alice")
  """

  alias YellowDog.Data.Store
  alias YellowDog.Data.Resource.{Hardware, Identity, Ownership, NetworkResource}

  @resource_modules [Hardware, Identity, Ownership, NetworkResource]

  # ── Store initialization ──────────────────────────────────────────

  @doc """
  Initialize Store.Ets collections for all resource types.

  Returns a map of `%{module => store_state}`. Typically called once from
  a supervisor or the Data.Registry.
  """
  @spec init_stores(keyword()) :: {:ok, map()}
  def init_stores(opts \\ []) do
    stores =
      for mod <- @resource_modules, into: %{} do
        {:ok, store} = Store.init(mod.collection(), opts)
        {mod, store}
      end

    :persistent_term.put({__MODULE__, :stores}, stores)
    {:ok, stores}
  end

  # ── Hardware ──────────────────────────────────────────────────────

  @doc "Create a hardware record."
  @spec create_hardware(map()) :: {:ok, Hardware.t()} | {:error, term()}
  def create_hardware(attrs) do
    with {:ok, hw} <- Hardware.new(attrs),
         {:ok, _store} <- Store.put(store(Hardware), hw.id, hw) do
      {:ok, hw}
    end
  end

  @doc "Get a hardware record by ID."
  @spec get_hardware(String.t()) :: {:ok, Hardware.t()} | {:error, :not_found}
  def get_hardware(id), do: Store.get(store(Hardware), id)

  @doc "Update a hardware record."
  @spec update_hardware(String.t(), map()) :: {:ok, Hardware.t()} | {:error, term()}
  def update_hardware(id, attrs) do
    with {:ok, existing} <- Store.get(store(Hardware), id),
         {:ok, updated} <- Hardware.update(existing, attrs),
         {:ok, _store} <- Store.put(store(Hardware), id, updated) do
      {:ok, updated}
    end
  end

  @doc "Delete a hardware record."
  @spec delete_hardware(String.t()) :: :ok
  def delete_hardware(id) do
    {:ok, _store} = Store.delete(store(Hardware), id)
    :ok
  end

  @doc "List all hardware records."
  @spec list_hardware() :: [Hardware.t()]
  def list_hardware do
    {:ok, records} = Store.list(store(Hardware))
    records
  end

  # ── Identity ──────────────────────────────────────────────────────

  @doc "Create an identity record."
  @spec create_identity(map()) :: {:ok, Identity.t()} | {:error, term()}
  def create_identity(attrs) do
    with {:ok, identity} <- Identity.new(attrs),
         {:ok, _store} <- Store.put(store(Identity), identity.id, identity) do
      {:ok, identity}
    end
  end

  @doc "Get an identity by ID."
  @spec get_identity(String.t()) :: {:ok, Identity.t()} | {:error, :not_found}
  def get_identity(id), do: Store.get(store(Identity), id)

  @doc "Update an identity record."
  @spec update_identity(String.t(), map()) :: {:ok, Identity.t()} | {:error, term()}
  def update_identity(id, attrs) do
    with {:ok, existing} <- Store.get(store(Identity), id),
         {:ok, updated} <- Identity.update(existing, attrs),
         {:ok, _store} <- Store.put(store(Identity), id, updated) do
      {:ok, updated}
    end
  end

  @doc "Delete an identity record."
  @spec delete_identity(String.t()) :: :ok
  def delete_identity(id) do
    {:ok, _store} = Store.delete(store(Identity), id)
    :ok
  end

  @doc "List all identities."
  @spec list_identities() :: [Identity.t()]
  def list_identities do
    {:ok, records} = Store.list(store(Identity))
    records
  end

  # ── Ownership ─────────────────────────────────────────────────────

  @doc "Assign hardware to an identity (create ownership link)."
  @spec assign_hardware(String.t(), String.t(), keyword()) ::
          {:ok, Ownership.t()} | {:error, term()}
  def assign_hardware(identity_id, hardware_id, opts \\ []) do
    attrs =
      %{identity_id: identity_id, hardware_id: hardware_id}
      |> Map.merge(Map.new(opts))

    with {:ok, link} <- Ownership.new(attrs),
         {:ok, _store} <- Store.put(store(Ownership), link.id, link) do
      {:ok, link}
    end
  end

  @doc "Remove an ownership link."
  @spec unassign_hardware(String.t(), String.t()) :: :ok
  def unassign_hardware(identity_id, hardware_id) do
    link_id = "#{identity_id}:#{hardware_id}"
    {:ok, _store} = Store.delete(store(Ownership), link_id)
    :ok
  end

  @doc "List hardware assigned to an identity."
  @spec list_hardware_for_identity(String.t()) :: [Ownership.t()]
  def list_hardware_for_identity(identity_id) do
    {:ok, links} = Store.list(store(Ownership), &(&1.identity_id == identity_id))
    links
  end

  @doc "List identities that own a hardware resource."
  @spec list_owners_for_hardware(String.t()) :: [Ownership.t()]
  def list_owners_for_hardware(hardware_id) do
    {:ok, links} = Store.list(store(Ownership), &(&1.hardware_id == hardware_id))
    links
  end

  @doc "List all ownership links."
  @spec list_ownership() :: [Ownership.t()]
  def list_ownership do
    {:ok, records} = Store.list(store(Ownership))
    records
  end

  # ── Network Resources ─────────────────────────────────────────────

  @doc "Create a network resource."
  @spec create_network_resource(map()) :: {:ok, NetworkResource.t()} | {:error, term()}
  def create_network_resource(attrs) do
    with {:ok, resource} <- NetworkResource.new(attrs),
         {:ok, _store} <- Store.put(store(NetworkResource), resource.id, resource) do
      {:ok, resource}
    end
  end

  @doc "Get a network resource by ID."
  @spec get_network_resource(String.t()) :: {:ok, NetworkResource.t()} | {:error, :not_found}
  def get_network_resource(id), do: Store.get(store(NetworkResource), id)

  @doc "Delete a network resource."
  @spec delete_network_resource(String.t()) :: :ok
  def delete_network_resource(id) do
    {:ok, _store} = Store.delete(store(NetworkResource), id)
    :ok
  end

  @doc "List network resources, optionally filtered by type."
  @spec list_network_resources(keyword()) :: [NetworkResource.t()]
  def list_network_resources(opts \\ []) do
    case Keyword.get(opts, :type) do
      nil ->
        {:ok, records} = Store.list(store(NetworkResource))
        records

      type ->
        type_str = to_string(type)
        {:ok, records} = Store.list(store(NetworkResource), &(&1.type == type_str))
        records
    end
  end

  @doc "List network resources linked to a hardware device."
  @spec list_resources_for_hardware(String.t()) :: [NetworkResource.t()]
  def list_resources_for_hardware(hardware_id) do
    {:ok, records} = Store.list(store(NetworkResource), &(&1.hardware_id == hardware_id))
    records
  end

  # ── Internal ──────────────────────────────────────────────────────

  defp store(module) do
    stores = :persistent_term.get({__MODULE__, :stores})
    Map.fetch!(stores, module)
  end
end
