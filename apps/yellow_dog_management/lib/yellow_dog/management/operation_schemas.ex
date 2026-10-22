defmodule YellowDog.Management.OperationSchemas do
  @moduledoc false
  def string(max \\ 256), do: %{"type" => "string", "maxLength" => max}
  def text(max \\ 256), do: Map.put(string(max), "minLength", 1)

  def integer(min \\ 0, max \\ 2_147_483_647),
    do: %{"type" => "integer", "minimum" => min, "maximum" => max}

  def boolean, do: %{"type" => "boolean"}
  def enum(values), do: %{"type" => "string", "enum" => values}
  def nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}
  def array(schema, max \\ 100), do: %{"type" => "array", "items" => schema, "maxItems" => max}

  def object(props, required \\ nil),
    do: %{
      "type" => "object",
      "properties" => props,
      "required" => required || Map.keys(props),
      "additionalProperties" => false
    }

  def uuid,
    do:
      Map.put(
        text(36),
        "pattern",
        "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
      )

  def identity, do: Map.put(text(64), "pattern", "^[A-Za-z0-9][A-Za-z0-9._-]*$")
  def digest, do: Map.put(text(64), "pattern", "^[a-f0-9]{64}$")
  def revision, do: integer(1)
  def task_key, do: enum(~w(ip_city ip_country))
  def kind, do: enum(~w(city country))
  def paging, do: %{"page" => integer(1, 100_000), "page_size" => integer(1, 100)}
  def scope, do: %{"worker_id" => identity(), "service_id" => uuid()}
  def expected, do: %{"expected_revision" => revision()}

  def worker_fields,
    do: %{
      "name" => text(128),
      "profile_name" => identity(),
      "expected_capabilities" => Map.put(array(enum(["dns"]), 16), "uniqueItems", true)
    }

  def service_fields,
    do: %{
      "instance_id" => identity(),
      "type" => enum(["dns"]),
      "desired_state" => enum(~w(running stopped)),
      "config" => dns_config()
    }

  def dns_config, do: object(%{"listen_address" => ipv4(), "port" => integer(1, 65_535)})

  def ipv4,
    do:
      Map.put(
        text(15),
        "pattern",
        "^(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$"
      )

  # Views retain their existing IPv4/IPv6 endpoint configuration. WorkerPlan
  # service listeners and A records continue to use the IPv4-only schema.
  defp forwarder_address do
    hex = "[0-9A-Fa-f]{1,4}"
    groups = fn count -> Enum.join(List.duplicate(hex, count), ":") end
    ipv4_pattern = ipv4()["pattern"] |> String.trim_leading("^") |> String.trim_trailing("$")

    compressed =
      for left <- 0..7 do
        right = if left == 7, do: "", else: "(?:#{hex}(?::#{hex}){0,#{6 - left}})?"
        groups.(left) <> "::" <> right
      end

    embedded =
      for left <- 0..5 do
        groups.(left) <> "::(?:#{hex}:){0,#{5 - left}}" <> ipv4_pattern
      end

    alternatives = [groups.(8), groups.(6) <> ":" <> ipv4_pattern] ++ compressed ++ embedded

    ipv6 =
      Map.put(text(64), "pattern", "^(?:" <> Enum.join(alternatives, "|") <> ")$(?![\\s\\S])")

    %{"anyOf" => [ipv4(), ipv6]}
  end

  def record do
    soa =
      object(
        Map.merge(
          %{"mname" => text(253), "rname" => text(253), "serial" => integer(0, 4_294_967_295)},
          Map.new(~w(refresh retry expire minimum), &{&1, integer()})
        )
      )

    variants = [
      {"SOA", soa},
      {"NS", object(%{"host" => text(253)})},
      {"A", object(%{"address" => ipv4()})}
    ]

    %{
      "oneOf" =>
        Enum.map(variants, fn {type, data} ->
          object(%{
            "name" => text(253),
            "type" => enum([type]),
            "ttl" => integer(),
            "data" => data
          })
        end)
    }
  end

  def zone_content, do: object(%{"name" => text(253), "records" => array(record(), 1024)})

  def zone_input(extra \\ %{}) do
    props =
      Map.merge(extra, %{
        "name" => text(253),
        "records" => array(record(), 1024),
        "content" => zone_content()
      })

    object(props, Map.keys(extra))
    |> Map.put("oneOf", [
      %{"required" => ["name", "records"], "not" => %{"required" => ["content"]}},
      %{
        "required" => ["content"],
        "not" => %{"anyOf" => [%{"required" => ["name"]}, %{"required" => ["records"]}]}
      }
    ])
  end

  def rule do
    common = %{"action" => enum(~w(allow deny))}

    %{
      "oneOf" => [
        object(Map.put(common, "kind", enum(["any"]))),
        object(
          Map.merge(common, %{"kind" => enum(["networks"]), "networks" => array(text(64), 128)})
        ),
        object(
          Map.merge(common, %{
            "kind" => enum(["countries"]),
            "countries" => array(Map.put(text(2), "pattern", "^[A-Z]{2}$"), 249)
          })
        )
      ]
    }
  end

  def view_fields,
    do: %{
      "priority" => integer(0, 9_223_372_036_854_775_807),
      "enabled" => boolean(),
      "recursion_enabled" => boolean(),
      "ecs_enabled" => boolean(),
      "client_rules" => array(rule(), 128),
      "fallback_forwarders" =>
        array(object(%{"address" => forwarder_address(), "port" => integer(1, 65_535)}), 128),
      "fallback_timeout" => integer(100, 30_000),
      "fallback_retries" => integer(0, 5)
    }

  def acl_fields,
    do: %{
      "name" => Map.put(text(128), "pattern", "^[A-Za-z0-9][A-Za-z0-9._-]*$"),
      "description" => string(255),
      "rules" => array(rule(), 128)
    }

  def worker do
    object(
      Map.merge(worker_fields(), %{
        "id" => identity(),
        "revision" => revision(),
        "actual_state" => enum(["unknown"]),
        "connection_status" => enum(~w(not_yet_connected connected offline)),
        "last_seen_at" => nullable(string(40)),
        "applied_revision" => nullable(revision()),
        "applied_digest" => nullable(digest())
      })
    )
  end

  def service,
    do:
      object(
        Map.merge(service_fields(), %{
          "id" => uuid(),
          "worker_id" => identity(),
          "actual_state" => enum(["unknown"]),
          "worker_revision" => revision()
        }),
        ~w(id worker_id instance_id type desired_state config actual_state)
      )

  def zone,
    do:
      object(%{
        "id" => uuid(),
        "name" => text(253),
        "revision" => revision(),
        "records" => array(record(), 1024)
      })

  def zone_metadata,
    do:
      object(%{
        "id" => uuid(),
        "name" => text(253),
        "revision" => revision(),
        "record_count" => integer(),
        "latest_version" => nullable(revision()),
        "service_count" => integer(),
        "worker_count" => integer()
      })

  def version(detail \\ false) do
    props = %{
      "id" => uuid(),
      "resource_id" => uuid(),
      "version" => revision(),
      "source_revision" => revision(),
      "digest" => digest()
    }

    object(if(detail, do: Map.put(props, "content", zone_content()), else: props))
  end

  def assignment_input,
    do:
      object(%{
        "worker_id" => identity(),
        "service_id" => uuid(),
        "resource_version_id" => uuid()
      })

  def revisions,
    do: %{
      "type" => "object",
      "maxProperties" => 512,
      "propertyNames" => identity(),
      "additionalProperties" => revision()
    }

  def assignments do
    row =
      object(%{
        "id" => uuid(),
        "worker_id" => identity(),
        "worker_name" => text(128),
        "service_id" => uuid(),
        "service_instance_id" => identity(),
        "zone_id" => uuid(),
        "resource_id" => uuid(),
        "resource_version_id" => uuid(),
        "version" => revision()
      })

    object(%{
      "zone_id" => uuid(),
      "assignment_token" => digest(),
      "worker_revisions" => revisions(),
      "assignments" => array(row, 256)
    })
  end

  def view do
    props =
      Map.merge(view_fields(), %{
        "id" => uuid(),
        "worker_id" => identity(),
        "service_id" => uuid(),
        "name" => text(63),
        "is_default" => boolean(),
        "revision" => revision(),
        "inserted_at" => string(40),
        "updated_at" => string(40)
      })
      |> Map.put("priority", nullable(integer(0, 9_223_372_036_854_775_807)))

    object(props)
  end

  def acl,
    do:
      object(
        Map.merge(acl_fields(), %{
          "id" => uuid(),
          "worker_id" => identity(),
          "service_id" => uuid(),
          "revision" => revision(),
          "inserted_at" => string(40),
          "updated_at" => string(40)
        })
      )

  def plan do
    resource =
      object(%{
        "id" => identity(),
        "type" => enum(["dns_zone"]),
        "schema_version" => %{"const" => 1},
        "version" => revision(),
        "content" => zone_content(),
        "digest" => digest()
      })

    service =
      object(%{
        "id" => identity(),
        "type" => enum(["dns"]),
        "desired_state" => enum(~w(running stopped)),
        "config" => dns_config(),
        "resources" => array(identity(), 256)
      })

    object(%{
      "schema_version" => %{"const" => 1},
      "worker_id" => identity(),
      "revision" => revision(),
      "services" => array(service, 64),
      "resources" => array(resource, 256)
    })
  end

  def target(detail \\ false) do
    props = %{
      "id" => uuid(),
      "worker_id" => identity(),
      "revision" => revision(),
      "digest" => digest(),
      "status" => enum(["prepared"]),
      "actual_state" => enum(["unknown"])
    }

    object(
      if(detail,
        do: Map.put(props, "plan", plan()),
        else: Map.put(props, "prepared_at", string(40))
      )
    )
  end

  def published_target do
    target(true)
    |> Map.update!("properties", fn properties ->
      Map.merge(properties, %{
        "worker_revision" => revision(),
        "export_scope" => export_scope()
      })
    end)
    |> Map.update!("required", &["worker_revision", "export_scope" | &1])
  end

  def export_scope,
    do:
      object(%{
        "scope" => enum(["dns_zones"]),
        "excluded" => array(enum(~w(dns_views dns_acls geoip_artifacts)), 3)
      })

  def preview do
    delta = %{
      "added" => array(identity(), 256),
      "replaced" => array(identity(), 256),
      "removed" => array(identity(), 256)
    }

    lifecycle =
      array(
        object(%{
          "id" => identity(),
          "from" => enum(~w(running stopped)),
          "to" => enum(~w(running stopped))
        }),
        64
      )

    object(%{
      "worker_id" => identity(),
      "worker_revision" => revision(),
      "next_target_revision" => revision(),
      "previous_plan" => nullable(plan()),
      "plan" => plan(),
      "diff" =>
        object(%{
          "services" => object(Map.put(delta, "lifecycle", lifecycle)),
          "resources" => object(delta)
        }),
      "status" => enum(["prepared_preview"]),
      "actual_state" => enum(["unknown"]),
      "export_scope" => export_scope()
    })
  end

  def task,
    do:
      object(%{
        "key" => task_key(),
        "label" => string(128),
        "enabled" => boolean(),
        "cron" => text(128),
        "revision" => revision()
      })

  def job do
    props = %{
      "id" => integer(1, 9_223_372_036_854_775_807),
      "task_key" => task_key(),
      "state" => enum(~w(available scheduled executing retryable completed discarded cancelled)),
      "attempt" => integer(),
      "max_attempts" => integer(1),
      "verification" => enum(["unknown"])
    }

    object(
      Map.merge(
        props,
        Map.new(
          ~w(inserted_at attempted_at completed_at discarded_at scheduled_at),
          &{&1, nullable(string(40))}
        )
      )
    )
  end

  def artifact do
    object(%{
      "digest" => digest(),
      "kind" => kind(),
      "format" => enum(["mmdb"]),
      "size" => integer(0, 9_223_372_036_854_775_807),
      "inserted_at" => string(40),
      "verification" => enum(["unknown"]),
      "available" => %{"type" => "null"}
    })
  end

  def audit,
    do:
      object(%{
        "id" => uuid(),
        "actor" => text(128),
        "operation" => text(64),
        "inserted_at" => string(40)
      })

  def page(item),
    do:
      object(%{
        "items" => array(item),
        "page" => integer(1, 100_000),
        "page_size" => integer(1, 100),
        "has_next" => boolean()
      })

  def error,
    do:
      object(
        %{
          "code" => text(128),
          "message" => text(2048),
          "details" => %{"type" => ["object", "array"]}
        },
        ~w(code message)
      )
end
