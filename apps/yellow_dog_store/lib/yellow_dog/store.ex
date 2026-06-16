defmodule YellowDog.Store do
  @moduledoc """
  Unified service data backend for YellowDog, built on Concord.

  Provides domain-typed facade functions over Concord's distributed KV store.
  Child apps never call `Concord.*` directly — all access goes through this module
  and its sub-modules.

  ## Sub-modules

    * `Store.Lease` — DHCP lease lifecycle
    * `Store.Device` — Device fingerprint registry
    * `Store.Zone` — Authoritative DNS zone data
    * `Store.Cache` — DNS resolver cache (ETS + Concord backing)
    * `Store.DynDns` — Dynamic DNS records
    * `Store.Rpz` — Response policy zones
    * `Store.Host` — Host identity registry
    * `Store.Config` — Runtime configuration overrides
    * `Store.Backup` — Backup and restore operations
    * `Store.EventBridge` — Event stream dispatcher
  """

  alias YellowDog.Store.Backend
  alias YellowDog.Store.ModeDetector

  # Lease operations
  defdelegate offer(protocol, client_id, ip, opts), to: YellowDog.Store.Lease
  defdelegate bind(protocol, client_id, xid), to: YellowDog.Store.Lease
  defdelegate renew(protocol, client_id, duration), to: YellowDog.Store.Lease
  defdelegate release_lease(protocol, client_id), to: YellowDog.Store.Lease, as: :release
  defdelegate decline(protocol, client_id), to: YellowDog.Store.Lease
  defdelegate get_lease(protocol, client_id), to: YellowDog.Store.Lease, as: :get
  defdelegate lease_by_ip(ip), to: YellowDog.Store.Lease, as: :by_ip
  defdelegate leases_by_subnet(subnet), to: YellowDog.Store.Lease, as: :list_by_subnet
  defdelegate leases_by_protocol(protocol), to: YellowDog.Store.Lease, as: :list_by_protocol

  # Device operations
  defdelegate upsert_device(mac, attrs), to: YellowDog.Store.Device, as: :upsert
  defdelegate get_device(mac), to: YellowDog.Store.Device, as: :get
  defdelegate devices_by_vendor(vendor_class), to: YellowDog.Store.Device, as: :by_vendor
  defdelegate recent_devices(since), to: YellowDog.Store.Device, as: :list_recent

  # Zone operations (view-scoped)
  defdelegate create_zone(view_name, name, soa, opts \\ []), to: YellowDog.Store.Zone
  defdelegate delete_zone(view_name, name), to: YellowDog.Store.Zone
  defdelegate get_zone(view_name, name), to: YellowDog.Store.Zone
  defdelegate list_zones(), to: YellowDog.Store.Zone
  defdelegate list_zones_for_view(view_name), to: YellowDog.Store.Zone
  defdelegate list_zones_by_type(zone_type), to: YellowDog.Store.Zone
  defdelegate update_zone(view_name, name, attrs), to: YellowDog.Store.Zone
  defdelegate put_rrset(view_name, zone, owner, type, rrset), to: YellowDog.Store.Zone
  defdelegate get_rrset(view_name, zone, owner, type), to: YellowDog.Store.Zone
  defdelegate delete_rrset(view_name, zone, owner, type), to: YellowDog.Store.Zone
  defdelegate list_records(view_name, zone), to: YellowDog.Store.Zone
  defdelegate list_records(view_name, zone, owner), to: YellowDog.Store.Zone
  defdelegate import_zone(view_name, name, records), to: YellowDog.Store.Zone
  defdelegate export_zone(view_name, name), to: YellowDog.Store.Zone
  defdelegate increment_serial(view_name, name), to: YellowDog.Store.Zone

  # Forward zone operations
  defdelegate create_forward_zone(view_name, name, forwarders, opts \\ []),
    to: YellowDog.Store.Zone

  defdelegate update_forward_zone(view_name, name, attrs), to: YellowDog.Store.Zone

  # Stub zone operations
  defdelegate create_stub_zone(view_name, name, primaries, opts \\ []),
    to: YellowDog.Store.Zone

  defdelegate update_stub_zone(view_name, name, attrs), to: YellowDog.Store.Zone

  # DynDns operations
  defdelegate put_dyn_dns(fqdn, record, opts \\ []), to: YellowDog.Store.DynDns, as: :put
  defdelegate put_dyn_dns_ptr(arpa, fqdn, opts \\ []), to: YellowDog.Store.DynDns, as: :put_ptr
  defdelegate get_dyn_dns(fqdn), to: YellowDog.Store.DynDns, as: :get
  defdelegate get_dyn_dns_ptr(arpa), to: YellowDog.Store.DynDns, as: :get_ptr
  defdelegate delete_dyn_dns(fqdn), to: YellowDog.Store.DynDns, as: :delete
  defdelegate dyn_dns_by_source(source), to: YellowDog.Store.DynDns, as: :list_by_source

  # RPZ operations
  defdelegate put_rpz(zone, trigger, rule), to: YellowDog.Store.Rpz, as: :put
  defdelegate get_rpz(zone, trigger), to: YellowDog.Store.Rpz, as: :get
  defdelegate list_rpz(zone), to: YellowDog.Store.Rpz, as: :list
  defdelegate delete_rpz(zone, trigger), to: YellowDog.Store.Rpz, as: :delete
  defdelegate rpz_zones(), to: YellowDog.Store.Rpz, as: :zones

  # Host operations
  defdelegate register_host(hostname, attrs), to: YellowDog.Store.Host, as: :register
  defdelegate update_host_keys(hostname, pubkeys), to: YellowDog.Store.Host, as: :update_keys
  defdelegate get_host(hostname), to: YellowDog.Store.Host, as: :get
  defdelegate host_by_mac(mac), to: YellowDog.Store.Host, as: :by_mac
  defdelegate attest_host(hostname), to: YellowDog.Store.Host, as: :attest

  # Config operations
  defdelegate get_config(service, key, default \\ nil), to: YellowDog.Store.Config, as: :get
  defdelegate put_config(service, key, value), to: YellowDog.Store.Config, as: :put
  defdelegate list_config(service), to: YellowDog.Store.Config, as: :list
  defdelegate delete_config(service, key), to: YellowDog.Store.Config, as: :delete

  defdelegate put_provider_config(config), to: YellowDog.Store.Provider, as: :put_config
  defdelegate get_provider_config(name), to: YellowDog.Store.Provider, as: :get_config
  defdelegate list_provider_configs(), to: YellowDog.Store.Provider, as: :list_configs
  defdelegate delete_provider_config(name), to: YellowDog.Store.Provider, as: :delete_config

  # Backup operations
  defdelegate create_backup(opts \\ []), to: YellowDog.Store.Backup, as: :create
  defdelegate restore_backup(path, opts \\ []), to: YellowDog.Store.Backup, as: :restore
  defdelegate verify_backup(path), to: YellowDog.Store.Backup, as: :verify
  defdelegate list_backups(opts \\ []), to: YellowDog.Store.Backup, as: :list
  defdelegate delete_backup(path), to: YellowDog.Store.Backup, as: :delete

  # Event operations
  defdelegate subscribe(pattern, handler_fn), to: YellowDog.Store.EventBridge
  defdelegate subscribe(pattern), to: YellowDog.Store.EventBridge
  defdelegate replay(pattern, since), to: YellowDog.Store.EventBridge

  # Single-node mode detection
  defdelegate single_node?(), to: ModeDetector

  @doc """
  Returns the current Store mode: `:single_node` or `:cluster`.
  """
  defdelegate store_mode(), to: ModeDetector, as: :mode

  @doc """
  Emits a telemetry event for Store operations.
  """
  def emit_telemetry(namespace, operation, key, duration, metadata \\ %{}) do
    :telemetry.execute(
      [:yellow_dog, :store, :operation, :stop],
      %{duration: duration},
      Map.merge(metadata, %{namespace: namespace, operation: operation, key: key})
    )
  end

  @doc """
  Routes a `put` call to the active backend (ETS or Concord).
  Used by Store sub-modules.
  """
  def backend_put(key, value, opts \\ []) do
    Backend.active().put(key, value, opts)
  end

  @doc """
  Routes a `get` call to the active backend.
  """
  def backend_get(key, opts \\ []) do
    Backend.active().get(key, opts)
  end

  @doc """
  Routes a `delete` call to the active backend.
  """
  def backend_delete(key) do
    Backend.active().delete(key)
  end

  @doc """
  Routes a `put_if` call to the active backend.
  """
  def backend_put_if(key, value, opts) do
    Backend.active().put_if(key, value, opts)
  end

  @doc """
  Routes a `prefix_scan` call to the active backend.
  """
  def backend_prefix_scan(prefix, opts \\ []) do
    Backend.active().prefix_scan(prefix, opts)
  end

  @doc """
  Routes a `put_many` call to the active backend.
  """
  def backend_put_many(operations) do
    Backend.active().put_many(operations)
  end
end
