defmodule YellowDog.Management.Repo.Migrations.AddOrderedDnsAclRules do
  use Ecto.Migration

  def up do
    alter table(:management_dns_acls) do
      add :description, :text, null: false, default: ""
      add :rules, {:array, :map}, null: false, default: []
    end

    execute """
    UPDATE management_dns_acls
    SET rules = ARRAY[jsonb_build_object('action', action, 'kind', 'networks', 'networks', networks)]
    """

    drop constraint(:management_dns_acls, :management_dns_acl_action)
    drop constraint(:management_dns_acls, :management_dns_acl_networks)

    alter table(:management_dns_acls) do
      remove :action
      remove :networks
    end

    execute """
    CREATE FUNCTION management_valid_dns_acl_rules(candidate jsonb[]) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE
      rule jsonb;
      value jsonb;
      network_count integer := 0;
      network_text text;
    BEGIN
      IF candidate IS NULL OR cardinality(candidate) > 128
         OR COALESCE(array_ndims(candidate), 1) <> 1
         OR COALESCE(array_lower(candidate, 1), 1) <> 1 THEN
        RETURN false;
      END IF;
      FOREACH rule IN ARRAY candidate LOOP
        IF rule IS NULL OR jsonb_typeof(rule) <> 'object'
           OR NOT (rule ?& ARRAY['action', 'kind'])
           OR rule->>'action' NOT IN ('allow', 'deny')
           OR jsonb_typeof(rule->'action') <> 'string'
           OR jsonb_typeof(rule->'kind') <> 'string' THEN
          RETURN false;
        END IF;
        CASE rule->>'kind'
          WHEN 'any' THEN
            IF rule - ARRAY['action', 'kind'] <> '{}'::jsonb THEN RETURN false; END IF;
          WHEN 'networks' THEN
            IF NOT (rule ? 'networks') OR jsonb_typeof(rule->'networks') <> 'array'
               OR rule - ARRAY['action', 'kind', 'networks'] <> '{}'::jsonb THEN
              RETURN false;
            END IF;
            network_count := network_count + jsonb_array_length(rule->'networks');
            IF network_count > 128 THEN RETURN false; END IF;
            FOR value IN SELECT jsonb_array_elements(rule->'networks') LOOP
              IF jsonb_typeof(value) <> 'string' THEN RETURN false; END IF;
              network_text := value #>> '{}';
              IF length(network_text) > 64 OR network_text::cidr::text <> network_text THEN
                RETURN false;
              END IF;
            END LOOP;
          WHEN 'countries' THEN
            IF NOT (rule ? 'countries') OR jsonb_typeof(rule->'countries') <> 'array'
               OR rule - ARRAY['action', 'kind', 'countries'] <> '{}'::jsonb THEN
              RETURN false;
            END IF;
            IF jsonb_array_length(rule->'countries') NOT BETWEEN 1 AND 249 THEN RETURN false; END IF;
            FOR value IN SELECT jsonb_array_elements(rule->'countries') LOOP
              IF jsonb_typeof(value) <> 'string' OR (value #>> '{}') !~ '^[A-Z]{2}$' THEN
                RETURN false;
              END IF;
            END LOOP;
          ELSE RETURN false;
        END CASE;
      END LOOP;
      RETURN true;
    EXCEPTION WHEN invalid_text_representation THEN
      RETURN false;
    END;
    $$
    """

    create constraint(:management_dns_acls, :management_dns_acl_description,
             check: "char_length(description) <= 255"
           )

    create constraint(:management_dns_acls, :management_dns_acl_rules,
             check: "management_valid_dns_acl_rules(rules)"
           )
  end
end
