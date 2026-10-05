defmodule YellowDog.Management.Repo.Migrations.CreateDnsViews do
  use Ecto.Migration

  def up do
    create table(:management_dns_views, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :service_id, references(:management_services, type: :uuid, on_delete: :restrict),
        null: false

      add :name, :string, size: 63, null: false
      add :is_default, :boolean, null: false, default: false
      add :priority, :bigint
      add :enabled, :boolean, null: false, default: true
      add :recursion_enabled, :boolean, null: false, default: true
      add :ecs_enabled, :boolean, null: false, default: false
      add :client_rules, {:array, :map}, null: false, default: []
      add :fallback_forwarders, {:array, :map}, null: false, default: []
      add :fallback_timeout, :integer, null: false, default: 2000
      add :fallback_retries, :integer, null: false, default: 1
      add :revision, :bigint, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:management_dns_views, [:service_id, :name])
    create unique_index(:management_dns_views, [:service_id], where: "is_default")

    create constraint(:management_dns_views, :management_dns_view_name,
             check: "name ~ '^[A-Za-z0-9_-]{1,63}$'"
           )

    create constraint(:management_dns_views, :management_dns_view_default,
             check: """
             (is_default AND name = 'default' AND priority IS NULL
               AND client_rules = ARRAY['{"action":"allow","kind":"any"}'::jsonb])
             OR (NOT is_default AND name <> 'default' AND priority IS NOT NULL AND priority >= 0)
             """
           )

    create constraint(:management_dns_views, :management_dns_view_rules,
             check: "management_valid_dns_acl_rules(client_rules)"
           )

    create constraint(:management_dns_views, :management_dns_view_limits,
             check:
               "revision > 0 AND fallback_timeout BETWEEN 100 AND 30000 AND fallback_retries BETWEEN 0 AND 5"
           )

    execute """
    CREATE FUNCTION management_valid_dns_forwarders(candidate jsonb[]) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE endpoint jsonb; address_text text; port_text text;
    BEGIN
      IF candidate IS NULL OR cardinality(candidate) > 128
         OR COALESCE(array_ndims(candidate), 1) <> 1
         OR COALESCE(array_lower(candidate, 1), 1) <> 1 THEN RETURN false; END IF;
      FOREACH endpoint IN ARRAY candidate LOOP
        IF endpoint IS NULL OR jsonb_typeof(endpoint) <> 'object'
           OR NOT (endpoint ?& ARRAY['address', 'port'])
           OR endpoint - ARRAY['address', 'port'] <> '{}'::jsonb
           OR jsonb_typeof(endpoint->'address') <> 'string'
           OR jsonb_typeof(endpoint->'port') <> 'number' THEN RETURN false; END IF;
        address_text := endpoint->>'address';
        port_text := endpoint->>'port';
        IF length(address_text) > 64 OR host(address_text::inet) <> address_text
           OR port_text !~ '^[0-9]{1,5}$' OR port_text::integer NOT BETWEEN 1 AND 65535 THEN
          RETURN false;
        END IF;
      END LOOP;
      RETURN true;
    EXCEPTION WHEN invalid_text_representation THEN RETURN false;
    END;
    $$
    """

    create constraint(:management_dns_views, :management_dns_view_forwarders,
             check: "management_valid_dns_forwarders(fallback_forwarders)"
           )

    execute """
    INSERT INTO management_dns_views
      (id, service_id, name, is_default, priority, client_rules, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, 'default', true, NULL,
      ARRAY['{"action":"allow","kind":"any"}'::jsonb], now(), now()
    FROM management_services WHERE type = 'dns'
    """
  end
end
