defmodule YellowDog.Server.Control.DnsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control.Dns
  alias YellowDog.ServerDnsControlFake
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @observed_at "2026-07-16T00:00:00Z"
  @read_operations [
    "server.dns.views.list",
    "server.dns.zones.list",
    "server.dns.records.list",
    "server.dns.acls.list",
    "server.dns.providers.list",
    "server.dns.logs.list",
    "server.dns.metrics.get"
  ]
  @mutation_operations [
    "server.dns.views.create",
    "server.dns.views.update",
    "server.dns.views.delete",
    "server.dns.zones.create",
    "server.dns.zones.update",
    "server.dns.zones.delete",
    "server.dns.records.create",
    "server.dns.records.update",
    "server.dns.records.delete",
    "server.dns.acls.create",
    "server.dns.acls.update",
    "server.dns.acls.delete",
    "server.dns.providers.create",
    "server.dns.providers.update",
    "server.dns.providers.delete",
    "server.dns.zones.import",
    "server.dns.zones.sync",
    "server.dns.conflicts.resolve"
  ]

  setup do
    previous = Application.get_env(:yellow_dog, Dns)

    Application.put_env(:yellow_dog, Dns,
      view_manager: ServerDnsControlFake.ViewManager,
      zone_store: ServerDnsControlFake.ZoneStore,
      acl_registry: ServerDnsControlFake.AclRegistry,
      provider_store: ServerDnsControlFake.ProviderStore,
      query_logger: ServerDnsControlFake.QueryLogger,
      metrics_collector: ServerDnsControlFake.MetricsCollector,
      clock: ServerDnsControlFake.Clock
    )

    start_supervised!(ServerDnsControlFake)

    on_exit(fn -> restore_env(previous) end)

    :ok
  end

  test "projects active views without runtime process fields" do
    ServerDnsControlFake.configure(%{
      views: [{"external", self(), 20}, {"internal", self(), 10}],
      view_stats: %{
        views: %{
          "external" => %{match_clients: ["0.0.0.0/0"], recursion_enabled: false},
          "internal" => %{
            match_clients: ["10.0.0.0/8"],
            recursion_enabled: true,
            pid: self(),
            cache_path: "/var/lib/yellowdog/view-cache"
          }
        }
      }
    })

    assert {:ok, result} = Dns.dispatch("server.dns.views.list", %{})

    assert result ==
             list_result(
               [
                 %{
                   "view_name" => "external",
                   "match_clients" => ["0.0.0.0/0"],
                   "recursion" => false
                 },
                 %{
                   "view_name" => "internal",
                   "match_clients" => ["10.0.0.0/8"],
                   "recursion" => true
                 }
               ],
               result["revision"]
             )

    assert_valid_result("server.dns.views.list", result)
    refute inspect(result) =~ inspect(self())
    refute inspect(result) =~ "/var/lib/yellowdog"

    assert [{:view_manager, :list_control_views, []}, {:clock, :utc_now, []}] =
             ServerDnsControlFake.take_calls()
  end

  test "projects authoritative and forward zones in deterministic order" do
    ServerDnsControlFake.configure(%{
      zones: %{
        "default" =>
          {:ok,
           [
             %{
               view_name: "default",
               origin: "Forward.Example.",
               zone_type: :forward,
               forwarders: [%{address: "192.0.2.53", port: 53}],
               config_path: "/etc/yellowdog/zones.toml"
             },
             %{
               view_name: "default",
               origin: "Example.Test.",
               zone_type: :auth,
               cloud_mirror: %{connector_name: "aws-main", secret: "do-not-leak"},
               manager_pid: self()
             },
             %{view_name: "default", origin: "root", zone_type: :root}
           ]}
      }
    })

    assert {:ok, result} =
             Dns.dispatch("server.dns.zones.list", %{"view_name" => "default"})

    assert result["items"] == [
             %{
               "view_name" => "default",
               "zone_name" => "example.test",
               "zone_type" => "authoritative",
               "provider_id" => "aws-main"
             },
             %{
               "view_name" => "default",
               "zone_name" => "forward.example",
               "zone_type" => "forward",
               "provider_id" => nil
             }
           ]

    assert_valid_result("server.dns.zones.list", result)
    refute inspect(result) =~ "do-not-leak"
    refute inspect(result) =~ "/etc/yellowdog"
    refute inspect(result) =~ inspect(self())
  end

  test "projects RRsets with canonical owners, fixed types, values, and stable IDs" do
    expected_id = record_id("www.example.test", "A")

    ServerDnsControlFake.configure(%{
      records: %{
        {"default", "example.test"} =>
          {:ok,
           [
             %{
               owner: "WWW.Example.Test.",
               type: :a,
               rrset: [
                 %{rdata: %{address: "192.0.2.10", ttl: 300}},
                 %{rdata: {192, 0, 2, 11}, ttl: 300}
               ],
               store_module: YellowDog.Store.Zone,
               table: :dns_records,
               path: "/var/lib/yellowdog/records"
             },
             %{owner: "ignored", type: :caa, rrset: [%{rdata: "0 issue ca.example"}]}
           ]}
      }
    })

    assert {:ok, result} =
             Dns.dispatch("server.dns.records.list", %{
               "view_name" => "default",
               "zone_name" => "example.test"
             })

    assert result["items"] == [
             %{
               "view_name" => "default",
               "zone_name" => "example.test",
               "record_id" => expected_id,
               "name" => "www.example.test",
               "type" => "A",
               "ttl" => 300,
               "values" => ["192.0.2.10", "192.0.2.11"]
             }
           ]

    assert_valid_result("server.dns.records.list", result)
    refute inspect(result) =~ "YellowDog.Store"
    refute inspect(result) =~ "dns_records"
    refute inspect(result) =~ "/var/lib/yellowdog"
  end

  test "projects only the eight fixed Store RR types without atom conversion" do
    records = [
      %{owner: "a.example", type: :a, rrset: [%{rdata: {192, 0, 2, 1}, ttl: 120}]},
      %{
        owner: "aaaa.example",
        type: :aaaa,
        rrset: [%{rdata: {8193, 3512, 0, 0, 0, 0, 0, 1}, ttl: 120}]
      },
      %{
        owner: "alias.example",
        type: :cname,
        rrset: [%{rdata: "Target.Example.", ttl: 120}]
      },
      %{
        owner: "example",
        type: :mx,
        rrset: [%{rdata: "Mail.Example.", priority: 10, ttl: 120}]
      },
      %{owner: "example", type: :ns, rrset: [%{rdata: "NS1.Example.", ttl: 120}]},
      %{owner: "1.2.0.192.in-addr.arpa", type: :ptr, rrset: [%{rdata: "Ptr.Example.", ttl: 120}]},
      %{
        owner: "_sip._tcp.example",
        type: :srv,
        rrset: [%{rdata: {0, 5, 5060, "Sip.Example."}, ttl: 120}]
      },
      %{owner: "txt.example", type: :txt, rrset: [%{rdata: ["part", "two"], ttl: 120}]},
      %{owner: "ignored.example", type: :soa, rrset: [%{rdata: "internal", ttl: 120}]}
    ]

    ServerDnsControlFake.configure(%{
      records: %{{"default", "example"} => {:ok, records}}
    })

    assert {:ok, result} =
             Dns.dispatch("server.dns.records.list", %{
               "view_name" => "default",
               "zone_name" => "example"
             })

    by_type = Map.new(result["items"], &{&1["type"], &1["values"]})

    assert by_type == %{
             "A" => ["192.0.2.1"],
             "AAAA" => ["2001:db8::1"],
             "CNAME" => ["target.example"],
             "MX" => ["10 mail.example"],
             "NS" => ["ns1.example"],
             "PTR" => ["ptr.example"],
             "SRV" => ["0 5 5060 sip.example"],
             "TXT" => ["parttwo"]
           }

    assert_valid_result("server.dns.records.list", result)
  end

  test "projects ACLs and providers while removing unsupported and secret fields" do
    ServerDnsControlFake.configure(%{
      acls: [
        %{
          name: "blocked",
          rules: [%{action: "deny", network: "203.0.113.0/24"}],
          source_path: "/etc/yellowdog/acls.toml",
          owner_pid: self()
        },
        %{name: "trusted", rules: [%{action: :allow, network: "10.0.0.0/8"}]}
      ],
      providers:
        {:ok,
         [
           %{
             name: "legacy-aws",
             type: :aws,
             credentials: %{access_key_id: "AKIA-SECRET", secret_access_key: "secret"},
             adapter: YellowDog.DnsProvider.Provider.Aws,
             config_path: "/etc/yellowdog/providers.toml"
           },
           %{name: "cf-main", type: :cloudflare, credentials: %{api_token: "cf-secret"}},
           %{name: "gcp-hidden", type: :gcp, credentials: %{token: "hidden"}}
         ]}
    })

    assert {:ok, acl_result} = Dns.dispatch("server.dns.acls.list", %{})
    assert {:ok, provider_result} = Dns.dispatch("server.dns.providers.list", %{})

    assert acl_result["items"] == [
             %{
               "acl_id" => "blocked",
               "networks" => ["203.0.113.0/24"],
               "action" => "deny"
             },
             %{"acl_id" => "trusted", "networks" => ["10.0.0.0/8"], "action" => "allow"}
           ]

    assert provider_result["items"] == [
             %{
               "provider_id" => "cf-main",
               "provider_type" => "cloudflare",
               "endpoint" => nil,
               "credential_ref" => credential_ref("cf-main")
             },
             %{
               "provider_id" => "legacy-aws",
               "provider_type" => "route53",
               "endpoint" => nil,
               "credential_ref" => credential_ref("legacy-aws")
             }
           ]

    assert_valid_result("server.dns.acls.list", acl_result)
    assert_valid_result("server.dns.providers.list", provider_result)

    encoded = inspect({acl_result, provider_result})
    refute encoded =~ "SECRET"
    refute encoded =~ "cf-secret"
    refute encoded =~ "DnsProvider.Provider"
    refute encoded =~ "/etc/yellowdog"
    refute encoded =~ inspect(self())
  end

  test "rejects mixed-action and geo ACLs instead of projecting altered policies" do
    for acl <- [
          %{
            name: "mixed",
            rules: [
              %{action: "allow", network: "10.0.0.0/8"},
              %{action: "deny", network: "10.1.0.0/16"}
            ]
          },
          %{
            name: "geo",
            rules: [%{action: "allow", geo_countries: ["US", "CA"]}]
          }
        ] do
      ServerDnsControlFake.configure(%{acls: [acl]})

      assert {:error, %Error{code: :unsupported}} =
               Dns.dispatch("server.dns.acls.list", %{})

      assert {:error, %Error{code: :unsupported}} =
               Dns.current("server.dns.acls.update", %{"acl_id" => acl.name})
    end
  end

  test "projects query logs and metrics through their read facades" do
    ServerDnsControlFake.configure(%{
      logs: [
        %{
          id: "log-forwarded",
          qname: "WWW.Example.Test.",
          response_code: :noerror,
          resolution_type: :recursive,
          timestamp: ~U[2026-07-15 23:59:59Z],
          client_ip: {192, 0, 2, 20},
          error: "token=must-not-leak"
        },
        %{
          id: "log-refused",
          qname: "blocked.example.test",
          response_code: :refused,
          timestamp: ~U[2026-07-15 23:59:58Z]
        }
      ],
      metrics: %{
        counters: %{queries_total: 42, cache_hits: 7},
        responses_by_code: [noerror: 38, refused: 2, servfail: 2],
        table: :dns_metrics,
        started_at: ~U[2026-07-15 00:00:00Z]
      }
    })

    assert {:ok, log_result} =
             Dns.dispatch("server.dns.logs.list", %{
               "view_name" => "default",
               "limit" => 10
             })

    assert log_result["items"] == [
             %{
               "log_id" => "log-forwarded",
               "query_name" => "www.example.test",
               "action" => "forwarded",
               "occurred_at" => "2026-07-15T23:59:59Z"
             },
             %{
               "log_id" => "log-refused",
               "query_name" => "blocked.example.test",
               "action" => "refused",
               "occurred_at" => "2026-07-15T23:59:58Z"
             }
           ]

    assert {:ok, %{"queries" => 42, "failures" => 4} = metrics_result} =
             Dns.dispatch("server.dns.metrics.get", %{})

    assert_valid_result("server.dns.logs.list", log_result)
    assert_valid_result("server.dns.metrics.get", metrics_result)
    refute inspect(log_result) =~ "must-not-leak"

    assert {:query_logger, :control_snapshot, ["default"]} in ServerDnsControlFake.take_calls()
  end

  test "query-log revision is page-size independent and cursors reach older entries" do
    ServerDnsControlFake.configure(%{
      logs: [
        log_entry("log-c", "c.example", ~U[2026-07-16 00:00:03Z]),
        log_entry("log-a", "a.example", ~U[2026-07-16 00:00:01Z]),
        log_entry("log-b", "b.example", ~U[2026-07-16 00:00:02Z])
      ]
    })

    assert {:ok, one} =
             Dns.dispatch("server.dns.logs.list", %{"view_name" => "default", "limit" => 1})

    assert {:ok, two} =
             Dns.dispatch("server.dns.logs.list", %{"view_name" => "default", "limit" => 2})

    assert one["revision"] == two["revision"]
    assert Enum.map(one["items"], & &1["log_id"]) == ["log-a"]

    assert {:ok, older} =
             Dns.dispatch("server.dns.logs.list", %{
               "view_name" => "default",
               "cursor" => "log-a",
               "limit" => 2
             })

    assert Enum.map(older["items"], & &1["log_id"]) == ["log-b", "log-c"]
    assert older["revision"] == one["revision"]
  end

  test "every approved read returns an exact Operation.validate_result shape" do
    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      view_stats: %{views: %{"default" => %{recursion_enabled: false}}},
      zones: %{"default" => {:ok, []}},
      records: %{{"default", "example.test"} => {:ok, []}},
      acls: [],
      providers: {:ok, []},
      logs: [],
      metrics: %{counters: %{queries_total: 0}, responses_by_code: []}
    })

    payloads = %{
      "server.dns.views.list" => %{},
      "server.dns.zones.list" => %{"view_name" => "default"},
      "server.dns.records.list" => %{
        "view_name" => "default",
        "zone_name" => "example.test"
      },
      "server.dns.acls.list" => %{},
      "server.dns.providers.list" => %{},
      "server.dns.logs.list" => %{"view_name" => "default"},
      "server.dns.metrics.get" => %{}
    }

    for operation <- @read_operations do
      assert {:ok, result} = Dns.dispatch(operation, Map.fetch!(payloads, operation))
      assert_valid_result(operation, result)
    end
  end

  test "list results are bounded, cursor-aware, deterministic, and clock-testable" do
    views =
      for index <- 0..1_004 do
        {"view-#{index |> Integer.to_string() |> String.pad_leading(4, "0")}", self(), index}
      end

    ServerDnsControlFake.configure(%{views: Enum.reverse(views)})

    assert {:ok, first} = Dns.dispatch("server.dns.views.list", %{})
    assert length(first["items"]) == 1_000
    assert hd(first["items"])["view_name"] == "view-0000"
    assert List.last(first["items"])["view_name"] == "view-0999"

    assert {:ok, page} =
             Dns.dispatch("server.dns.views.list", %{"cursor" => "view-0002", "limit" => 2})

    assert Enum.map(page["items"], & &1["view_name"]) == ["view-0003", "view-0004"]
    assert page["revision"] == first["revision"]

    ServerDnsControlFake.configure(%{now: ~U[2026-07-16 12:34:56Z]})
    assert {:ok, later} = Dns.dispatch("server.dns.views.list", %{})
    assert later["observed_at"] == "2026-07-16T12:34:56Z"
    assert later["revision"] == first["revision"]
  end

  test "sorts RRset values before calculating the collection revision" do
    first = %{
      owner: "www",
      type: :a,
      rrset: [%{rdata: {192, 0, 2, 2}, ttl: 60}, %{rdata: {192, 0, 2, 1}, ttl: 60}]
    }

    second = %{first | rrset: Enum.reverse(first.rrset)}

    ServerDnsControlFake.configure(%{
      records: %{{"default", "example.test"} => {:ok, [first]}}
    })

    assert {:ok, unsorted} =
             Dns.dispatch("server.dns.records.list", %{
               "view_name" => "default",
               "zone_name" => "example.test"
             })

    ServerDnsControlFake.configure(%{
      records: %{{"default", "example.test"} => {:ok, [second]}}
    })

    assert {:ok, reversed} =
             Dns.dispatch("server.dns.records.list", %{
               "view_name" => "default",
               "zone_name" => "example.test"
             })

    assert hd(unsorted["items"])["values"] == ["192.0.2.1", "192.0.2.2"]
    assert unsorted["revision"] == reversed["revision"]
  end

  test "validates projected reads and current snapshots before returning ok" do
    ServerDnsControlFake.configure(%{
      views: [{"a-valid", self(), 0}, {"default", self(), 1}],
      view_stats: %{
        views: %{
          "a-valid" => %{match_clients: ["10.0.0.0/8"], recursion_enabled: false},
          "default" => %{match_clients: ["not-a-cidr"], recursion_enabled: false}
        }
      }
    })

    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} =
             Dns.dispatch("server.dns.views.list", %{"limit" => 1})

    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} =
             Dns.current("server.dns.views.update", %{"view_name" => "default"})
  end

  test "current snapshots use the same canonical view, zone, ACL, and provider resources" do
    expected_credential_ref = credential_ref("cf-main")

    ServerDnsControlFake.configure(%{
      views: [{"default", self(), 0}],
      view_stats: %{
        views: %{"default" => %{match_clients: ["0.0.0.0/0"], recursion_enabled: false}}
      },
      zones: %{
        "default" =>
          {:ok,
           [
             %{
               view_name: "default",
               origin: "example.test",
               zone_type: :auth,
               cloud_mirror: %{connector_name: "cf-main"}
             }
           ]}
      },
      acls: [%{name: "trusted", rules: [%{action: :allow, network: "10.0.0.0/8"}]}],
      providers: {:ok, [%{name: "cf-main", type: :cloudflare, credentials: %{token: "secret"}}]}
    })

    assert {:ok,
            %{
              "view_name" => "default",
              "match_clients" => ["0.0.0.0/0"],
              "recursion" => false
            }} = Dns.current("server.dns.views.update", %{"view_name" => "default"})

    assert {:ok,
            %{
              "view_name" => "default",
              "zone_name" => "example.test",
              "zone_type" => "authoritative",
              "provider_id" => "cf-main"
            }} =
             Dns.current("server.dns.zones.delete", %{
               "view_name" => "default",
               "zone_name" => "example.test"
             })

    assert {:ok, %{"acl_id" => "trusted", "networks" => ["10.0.0.0/8"], "action" => "allow"}} =
             Dns.current("server.dns.acls.update", %{"acl_id" => "trusted"})

    assert {:ok,
            %{
              "provider_id" => "cf-main",
              "provider_type" => "cloudflare",
              "endpoint" => nil,
              "credential_ref" => ^expected_credential_ref
            }} = Dns.current("server.dns.providers.delete", %{"provider_id" => "cf-main"})
  end

  test "current returns missing only for absent creates and not_found for update/delete" do
    ServerDnsControlFake.configure(%{
      views: [],
      zones: %{"default" => {:ok, []}},
      acls: [],
      providers: {:ok, []}
    })

    assert {:ok, :missing} =
             Dns.current("server.dns.views.create", %{"view_name" => "new-view"})

    assert {:ok, :missing} =
             Dns.current("server.dns.zones.create", %{
               "view_name" => "default",
               "zone_name" => "new.example"
             })

    assert {:ok, :missing} =
             Dns.current("server.dns.acls.create", %{"acl_id" => "new-acl"})

    assert {:ok, :missing} =
             Dns.current("server.dns.providers.create", %{"provider_id" => "new-provider"})

    for {operation, payload} <- [
          {"server.dns.views.update", %{"view_name" => "missing"}},
          {"server.dns.zones.delete",
           %{"view_name" => "default", "zone_name" => "missing.example"}},
          {"server.dns.acls.update", %{"acl_id" => "missing"}},
          {"server.dns.providers.delete", %{"provider_id" => "missing"}}
        ] do
      assert {:error, %Error{code: :not_found}} = Dns.current(operation, payload)
    end
  end

  test "record current snapshots are stable and scoped to the supplied view and zone" do
    id = record_id("www", "A")
    record = %{owner: "WWW.", type: :a, rrset: [%{rdata: {192, 0, 2, 10}, ttl: 60}]}

    ServerDnsControlFake.configure(%{
      records: %{
        {"default", "one.example"} => {:ok, [record]},
        {"default", "two.example"} => {:ok, [record]}
      }
    })

    assert {:ok, snapshot} =
             Dns.current("server.dns.records.update", %{
               "view_name" => "default",
               "zone_name" => "one.example",
               "record_id" => id,
               "name" => "www",
               "type" => "A"
             })

    assert snapshot == %{
             "view_name" => "default",
             "zone_name" => "one.example",
             "record_id" => id,
             "name" => "www",
             "type" => "A",
             "ttl" => 60,
             "values" => ["192.0.2.10"]
           }

    ServerDnsControlFake.take_calls()

    assert {:error, %Error{code: :not_found}} =
             Dns.current("server.dns.records.delete", %{
               "view_name" => "default",
               "zone_name" => "absent.example",
               "record_id" => id
             })

    assert [{:zone_store, :list_records, ["default", "absent.example"]}] =
             ServerDnsControlFake.take_calls()
  end

  test "record IDs reject malformed, missing, duplicate, and mismatched references" do
    id = record_id("www", "A")
    duplicate_a = %{owner: "WWW.", type: :a, rrset: [%{rdata: {192, 0, 2, 1}, ttl: 60}]}
    duplicate_b = %{owner: "www", type: :a, rrset: [%{rdata: {192, 0, 2, 2}, ttl: 60}]}

    ServerDnsControlFake.configure(%{
      records: %{
        {"default", "empty.example"} => {:ok, []},
        {"default", "duplicate.example"} => {:ok, [duplicate_a, duplicate_b]}
      }
    })

    assert {:error, %Error{code: :invalid}} =
             Dns.current("server.dns.records.delete", %{
               "view_name" => "default",
               "zone_name" => "empty.example",
               "record_id" => "rr-not-a-digest"
             })

    assert [] = ServerDnsControlFake.take_calls()

    assert {:error, %Error{code: :not_found}} =
             Dns.current("server.dns.records.delete", %{
               "view_name" => "default",
               "zone_name" => "empty.example",
               "record_id" => id
             })

    assert {:error, %Error{code: :conflict}} =
             Dns.current("server.dns.records.delete", %{
               "view_name" => "default",
               "zone_name" => "duplicate.example",
               "record_id" => id
             })

    assert {:error, %Error{code: :invalid}} =
             Dns.current("server.dns.records.create", %{
               "view_name" => "default",
               "zone_name" => "empty.example",
               "record_id" => id,
               "name" => "mail",
               "type" => "A"
             })
  end

  test "caller record types never create atoms" do
    payload = %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "record_id" => String.duplicate("f", 64) |> then(&("rr-" <> &1)),
      "name" => "www",
      "type" => "UNREGISTERED-TYPE-WARMUP"
    }

    assert {:error, %Error{code: :invalid}} =
             Dns.current("server.dns.records.create", payload)

    initial_atom_count = :erlang.system_info(:atom_count)

    for index <- 1..100 do
      assert {:error, %Error{code: :invalid}} =
               Dns.current(
                 "server.dns.records.create",
                 %{payload | "type" => "UNREGISTERED-TYPE-#{index}"}
               )
    end

    assert :erlang.system_info(:atom_count) == initial_atom_count
    assert [] = ServerDnsControlFake.take_calls()
  end

  test "missing processes and unavailable stores return stable typed errors" do
    ServerDnsControlFake.configure(%{views: {:exit, :noproc}})

    assert {:error, %Error{code: :not_found, message: "resource not found", details: %{}}} =
             Dns.dispatch("server.dns.views.list", %{})

    ServerDnsControlFake.configure(%{zones: {:error, :backend_unavailable}})

    assert {:error, %Error{code: :apply_failed, message: "apply failed", details: %{}}} =
             Dns.dispatch("server.dns.zones.list", %{"view_name" => "default"})
  end

  test "mutation dispatch and unknown names are unsupported before dependency calls" do
    for operation <- @mutation_operations ++ ["server.dns.records.list.extra", "dns.views.list"] do
      assert {:error, %Error{code: :unsupported, message: "unsupported operation", details: %{}}} =
               Dns.dispatch(operation, %{
                 "view_name" => "default",
                 "zone_name" => "example.test",
                 "record_id" => record_id("www", "A")
               })
    end

    assert {:error, %Error{code: :unsupported}} =
             Dns.current("server.dns.unknown", %{})

    for operation <- [
          "server.dns.zones.import",
          "server.dns.zones.sync",
          "server.dns.conflicts.resolve"
        ] do
      assert {:error, %Error{code: :unsupported}} = Dns.current(operation, %{})
    end

    assert [] = ServerDnsControlFake.take_calls()
  end

  defp list_result(items, revision) do
    %{"items" => items, "revision" => revision, "observed_at" => @observed_at}
  end

  defp assert_valid_result(name, result) do
    assert {:ok, operation} = ServerOperation.fetch(name)
    assert {:ok, ^result} = Operation.validate_result(operation, result)
  end

  defp record_id(owner, type) do
    digest = :crypto.hash(:sha256, canonical_owner(owner) <> <<0>> <> String.upcase(type))
    "rr-" <> Base.encode16(digest, case: :lower)
  end

  defp credential_ref(provider_id) do
    digest = :crypto.hash(:sha256, provider_id)
    "local-provider-" <> Base.encode16(digest, case: :lower)
  end

  defp log_entry(id, qname, timestamp) do
    %{
      id: id,
      qname: qname,
      response_code: :noerror,
      resolution_type: :auth,
      timestamp: timestamp
    }
  end

  defp canonical_owner("@"), do: "@"

  defp canonical_owner(owner) do
    owner
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp restore_env(nil), do: Application.delete_env(:yellow_dog, Dns)
  defp restore_env(config), do: Application.put_env(:yellow_dog, Dns, config)
end
