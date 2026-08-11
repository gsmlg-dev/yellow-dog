defmodule YellowDog.Config.ManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Config
  alias YellowDog.Config.Manager

  @storage_magic "YDMC\0"

  @bootstrap %{
    "data_dir" => "/var/lib/yellow-dog/server-a",
    "machine_id" => "machine-a",
    "node_name" => "node-a",
    "global" => %{"node_name" => "global-node-a"},
    "core" => %{"dns" => false, "netboot" => true},
    "dns" => %{
      "listen" => "203.0.113.99",
      "port" => 1053,
      "tls_certificate" => "-----BEGIN CERTIFICATE-----\nlocal-only\n-----END CERTIFICATE-----"
    },
    "mdns" => %{"mode" => "advertiser"},
    "yellow_dog_server" => %{
      "id" => "server-a",
      "name" => "Server A",
      "profile" => "dns_only",
      "services" => %{"dns" => false, "mdns" => true, "server_agent" => true},
      "management" => %{
        "url" => "wss://management.example.test",
        "token" => "bootstrap-management-secret"
      }
    },
    "yellow_dog_server_agent" => %{
      "data_dir" => "/var/lib/yellow-dog/agent-a",
      "management_url" => "wss://management.example.test"
    },
    "netboot" => %{
      "tftp_root" => "/srv/yellow-dog/tftp",
      "tftp_port" => 6969,
      "default_profile" => "old-bootstrap-profile"
    },
    "netman" => %{
      "profile_dir" => "/etc/yellowdog/netman/profiles",
      "socket_path" => "/run/yellowdog/netman.sock",
      "reconciliation_interval_ms" => 10_000
    }
  }

  @managed_a %{
    "schema_version" => 1,
    "profile" => "cloud_dns",
    "entries" => [
      %{
        "setting" => "dhcpv4.default_lease_time",
        "value" => %{"type" => "integer", "value" => 7200}
      },
      %{
        "setting" => "dhcpv4.static_reservations",
        "value" => %{
          "type" => "object",
          "entries" => [
            %{
              "key" => "printer",
              "value" => %{"type" => "string", "value" => "192.0.2.42"}
            },
            %{
              "key" => "removed",
              "value" => %{"type" => "null", "value" => nil}
            }
          ]
        }
      },
      %{
        "setting" => "dns.listen",
        "value" => %{"type" => "string", "value" => "192.0.2.10"}
      },
      %{"setting" => "dns.port", "value" => %{"type" => "integer", "value" => 5353}},
      %{
        "setting" => "dns.search_domains",
        "value" => %{"type" => "list", "items" => ["example.test", "corp.example.test"]}
      },
      %{"setting" => "mdns.mode", "value" => %{"type" => "string", "value" => "querier"}},
      %{
        "setting" => "netboot.default_profile",
        "value" => %{"type" => "string", "value" => "rescue"}
      },
      %{
        "setting" => "netboot.tftp_port",
        "value" => %{"type" => "integer", "value" => 1069}
      },
      %{
        "setting" => "services.dhcpv4.enabled",
        "value" => %{"type" => "boolean", "value" => false}
      },
      %{
        "setting" => "services.dhcpv6.enabled",
        "value" => %{"type" => "boolean", "value" => false}
      },
      %{
        "setting" => "services.dns.enabled",
        "value" => %{"type" => "boolean", "value" => true}
      },
      %{
        "setting" => "services.fingerprint.enabled",
        "value" => %{"type" => "boolean", "value" => false}
      },
      %{
        "setting" => "services.identity.enabled",
        "value" => %{"type" => "boolean", "value" => false}
      },
      %{
        "setting" => "services.mdns.enabled",
        "value" => %{"type" => "boolean", "value" => false}
      },
      %{
        "setting" => "services.netboot.enabled",
        "value" => %{"type" => "boolean", "value" => true}
      }
    ]
  }

  @managed_b update_in(@managed_a, ["entries"], fn entries ->
               Enum.map(entries, fn
                 %{"setting" => "dns.listen"} = entry ->
                   put_in(entry, ["value", "value"], "192.0.2.11")

                 entry ->
                   entry
               end)
             end)

  setup do
    stop_config()
    {:ok, _pid} = Config.start_link(@bootstrap)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-managed-config-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)

    on_exit(fn ->
      stop_config()
      File.rm_rf(data_dir)
    end)

    %{data_dir: Path.expand(data_dir)}
  end

  test "validates the server.config.replace wire document and materializes a full runtime config" do
    assert :ok = Manager.validate_document(@managed_a)
    assert {:ok, runtime} = Manager.materialize(@managed_a, @bootstrap)

    assert runtime["dns"]["listen"] == "192.0.2.10"
    assert runtime["dns"]["port"] == 5353
    assert runtime["dns"]["search_domains"] == ["example.test", "corp.example.test"]
    assert runtime["dns"]["tls_certificate"] == @bootstrap["dns"]["tls_certificate"]
    assert runtime["mdns"]["mode"] == "querier"
    assert runtime["mdns"]["port"] == 5353
    assert runtime["dhcpv4"]["default_lease_time"] == 7200
    assert runtime["dhcpv4"]["static_reservations"] == %{"printer" => "192.0.2.42"}
    assert runtime["data_dir"] == @bootstrap["data_dir"]
    assert runtime["machine_id"] == "machine-a"
    assert runtime["node_name"] == "node-a"
    assert runtime["global"]["node_name"] == "global-node-a"
    assert runtime["netboot"]["tftp_root"] == @bootstrap["netboot"]["tftp_root"]
    assert runtime["netboot"]["tftp_port"] == 1069
    assert runtime["netboot"]["default_profile"] == "rescue"
    assert runtime["netman"]["profile_dir"] == @bootstrap["netman"]["profile_dir"]
    assert runtime["netman"]["socket_path"] == @bootstrap["netman"]["socket_path"]
    assert runtime["yellow_dog_server_agent"] == @bootstrap["yellow_dog_server_agent"]
    assert runtime["netman"]["reconciliation_interval_ms"] == 5000
    assert runtime["core"]["dns"] == true

    assert runtime["yellow_dog_server"] == %{
             "id" => "server-a",
             "name" => "Server A",
             "profile" => "cloud_dns",
             "management" => @bootstrap["yellow_dog_server"]["management"],
             "services" => %{
               "dhcpv4" => false,
               "dhcpv6" => false,
               "dns" => true,
               "fingerprint" => false,
               "identity" => false,
               "mdns" => false,
               "netboot" => true,
               "server_agent" => true
             }
           }
  end

  test "does not retain stale bootstrap values for management-owned settings" do
    managed = %{"schema_version" => 1, "profile" => "custom", "entries" => []}

    assert {:ok, runtime} = Manager.materialize(managed, @bootstrap)

    assert runtime["dns"] |> Map.take(["listen", "port"]) == %{
             "listen" => "0.0.0.0",
             "port" => 53
           }

    assert runtime["mdns"]["mode"] == "responder"
    assert runtime["netboot"]["default_profile"] == ""
    assert runtime["netman"]["reconciliation_interval_ms"] == 5000
    assert runtime["core"]["dns"] == true

    assert runtime["data_dir"] == @bootstrap["data_dir"]
    assert runtime["netboot"]["tftp_root"] == @bootstrap["netboot"]["tftp_root"]
    assert runtime["yellow_dog_server"]["id"] == "server-a"

    assert runtime["yellow_dog_server"]["management"] ==
             @bootstrap["yellow_dog_server"]["management"]
  end

  test "derives an explicit server_agent value from the immutable bootstrap profile" do
    bootstrap = update_in(@bootstrap["yellow_dog_server"], &Map.delete(&1, "services"))

    assert {:ok, runtime} = Manager.materialize(@managed_a, bootstrap)
    assert runtime["yellow_dog_server"]["services"]["server_agent"] == true

    custom_bootstrap = put_in(bootstrap, ["yellow_dog_server", "profile"], "custom")
    assert {:ok, custom_runtime} = Manager.materialize(@managed_a, custom_bootstrap)
    assert custom_runtime["yellow_dog_server"]["services"]["server_agent"] == false
  end

  test "rejects exact-shape, ordering, and typed-value violations" do
    invalid_documents = [
      Map.put(@managed_a, "extra", true),
      Map.put(@managed_a, "schema_version", 2),
      Map.put(@managed_a, "profile", "not-a-profile"),
      Map.put(@managed_a, "entries", Enum.reverse(@managed_a["entries"])),
      Map.put(@managed_a, "entries", [hd(@managed_a["entries"]) | @managed_a["entries"]]),
      wire_document("dns.port", %{"type" => "integer", "value" => "53"}),
      wire_document("services.dns.enabled", %{"type" => "string", "value" => "true"}),
      wire_document("dns.port", %{"type" => "integer", "value" => 53, "extra" => true}),
      wire_document("dns.port", %{"type" => "unknown", "value" => 53}),
      wire_document("dns.label", %{"type" => "string", "value" => "safe\u00ADhidden"}),
      wire_document("dns.label", %{"type" => "string", "value" => "etc／shadow"}),
      wire_document("dns.label", %{
        "type" => "string",
        "value" => "－－－－－BEGIN CERTIFICATE－－－－－"
      }),
      wire_document("dns.payloadref", %{"type" => "boolean", "value" => true}),
      wire_document("dns.nested", %{"type" => "list", "items" => [%{"nested" => true}]}),
      wire_document("dns.nested", %{"type" => "list", "items" => ["value", nil]}),
      wire_document("dns.nested", %{"type" => "list", "items" => ["etc／shadow"]}),
      wire_document("dns.object", %{
        "type" => "object",
        "entries" => [%{"key" => "bad/key", "value" => %{"type" => "boolean", "value" => true}}]
      }),
      wire_document("dns.object", %{
        "type" => "object",
        "entries" => [
          %{"key" => "port", "value" => %{"type" => "integer", "value" => 53}}
        ]
      }),
      wire_document("dns.object", %{
        "type" => "object",
        "entries" => [
          %{"key" => "ordinary_ref", "value" => %{"type" => "string", "value" => "item-1"}}
        ]
      }),
      wire_document("dns.object", %{
        "type" => "object",
        "entries" => [
          %{"key" => "payloadref", "value" => %{"type" => "boolean", "value" => true}}
        ]
      }),
      wire_document("dns.object", %{
        "type" => "object",
        "entries" => [
          %{
            "key" => "nested",
            "value" => %{
              "type" => "object",
              "entries" => [
                %{"key" => "leaf", "value" => %{"type" => "string", "value" => "value"}}
              ]
            }
          }
        ]
      })
    ]

    for document <- invalid_documents do
      assert {:error, {:invalid_document, paths}} = Manager.validate_document(document)
      assert paths != []
    end

    assert {:error, :invalid} = Manager.validate_document(%{schema_version: 1})
    assert {:error, :invalid} = Manager.validate_document(:not_a_document)
  end

  test "treats top-level typed null as unset but rejects null list items" do
    unset = wire_document("dns.optional_value", %{"type" => "null", "value" => nil})
    assert :ok = Manager.validate_document(unset)

    invalid_list =
      wire_document("dns.search_domains", %{
        "type" => "list",
        "items" => ["example.test", nil]
      })

    assert {:error, {:invalid_document, _paths}} = Manager.validate_document(invalid_list)
  end

  test "rejects every typed value for non-reference sensitive material" do
    values = [
      %{"type" => "string", "value" => "inline-value"},
      %{"type" => "integer", "value" => 1},
      %{"type" => "boolean", "value" => true},
      %{"type" => "null", "value" => nil},
      %{"type" => "list", "items" => ["inline-value"]},
      %{
        "type" => "object",
        "entries" => [
          %{"key" => "ordinary", "value" => %{"type" => "string", "value" => "inline-value"}}
        ]
      }
    ]

    for setting <- ["dns.api_secret", "dns.payload", "identity.client_private_key"],
        value <- values do
      assert {:error, {:invalid_document, _paths}} =
               Manager.validate_document(wire_document(setting, value))
    end
  end

  test "rejects every management-owned attempt to set bootstrap-local state" do
    forbidden_settings = [
      "services.server_agent.enabled",
      "server.id",
      "server.name",
      "server.management_url",
      "server.management_token",
      "server.management_credentials_ref",
      "server_agent.data_dir",
      "server_agent.management_url",
      "identity.bootstrap_token_ref",
      "identity.bootstrap.server_id",
      "dns.management.endpoint",
      "dns.agent.reconnect_ms",
      "dns.zone_file",
      "dns.zone_path",
      "dhcpv4.control_socket",
      "mdns.cache_dir",
      "netboot.tftp_root",
      "fingerprint.database_filename",
      "dns.tls_certificate",
      "dns.provider_credential",
      "dns.api_secret",
      "dns.api_key",
      "identity.client_private_key",
      "identity.privatekey",
      "identity.privatekeys",
      "identity.tlskey",
      "identity.secretkey",
      "identity.signingkey",
      "identity.tlskeyref"
    ]

    for setting <- forbidden_settings do
      document = wire_document(setting, %{"type" => "string", "value" => "managed-secret"})
      assert {:error, {:invalid_document, paths}} = Manager.validate_document(document)
      assert paths != []
      refute inspect(paths) =~ "managed-secret"
    end

    for value <- [
          "/etc/shadow",
          "C:\\secret\\key",
          "file:///etc/shadow",
          "-----BEGIN CERTIFICATE-----"
        ] do
      assert {:error, {:invalid_document, _paths}} =
               Manager.validate_document(
                 wire_document("dns.listen", %{"type" => "string", "value" => value})
               )
    end
  end

  test "accepts only safe references for managed material" do
    documents = [
      wire_document("dns.tls_certificate_ref", %{"type" => "string", "value" => "tls-cert-1"}),
      wire_document("dns.api_key_ref", %{"type" => "string", "value" => "dns-api-key"}),
      wire_document("dns.provider_credential_ref", %{
        "type" => "string",
        "value" => "cloudflare-main"
      }),
      wire_document("identity.client_private_key_digest", %{
        "type" => "string",
        "value" => String.duplicate("a", 64)
      }),
      wire_document("netboot.payload_uri", %{
        "type" => "string",
        "value" => "https://assets.example.test/boot.ipxe"
      })
    ]

    assert Enum.all?(documents, &(Manager.validate_document(&1) == :ok))

    invalid_documents = [
      wire_document("dns.tls_certificate_ref", %{"type" => "integer", "value" => 1}),
      wire_document("dns.tls_certificate_ref", %{"type" => "string", "value" => "/etc/cert.pem"}),
      wire_document("dns.tls_certificate_ref", %{"type" => "string", "value" => "cert／one"}),
      wire_document("identity.client_private_key_digest", %{"type" => "string", "value" => "nope"}),
      wire_document("netboot.payload_uri", %{"type" => "string", "value" => "file:///tmp/boot"}),
      wire_document("netboot.payload_uri", %{
        "type" => "string",
        "value" => "https://bad_host.example/boot.ipxe"
      }),
      wire_document("netboot.payload_uri", %{
        "type" => "string",
        "value" => "https://assets.example.test/a/../boot.ipxe"
      }),
      wire_document("netboot.payload_uri", %{
        "type" => "string",
        "value" => "https://assets.example.test../boot.ipxe"
      })
    ]

    assert Enum.all?(invalid_documents, fn document ->
             match?({:error, {:invalid_document, _paths}}, Manager.validate_document(document))
           end)
  end

  test "rejects malformed setting names and runtime values" do
    for setting <- [
          "unknown.listen",
          "DNS.port",
          "dns-port",
          "dns..port",
          "dns.double__underscore",
          "dns"
        ] do
      assert {:error, {:invalid_document, _paths}} =
               Manager.validate_document(
                 wire_document(setting, %{"type" => "integer", "value" => 53})
               )
    end

    assert {:error, {:validation_failed, ["dns.port"]}} =
             Manager.validate_document(
               wire_document("dns.port", %{"type" => "integer", "value" => 70_000})
             )
  end

  test "installs an immutable exact candidate without changing runtime or making it bootable", %{
    data_dir: data_dir
  } do
    before_runtime = Config.get_all()

    assert {:ok, revision} = Manager.install(data_dir, @managed_a)
    assert revision =~ ~r/\A[0-9a-f]{64}\z/
    assert Config.get_all() == before_runtime
    assert {:error, :not_found} = Manager.active_revision(data_dir)
    assert {:error, :not_found} = Manager.read_active(data_dir, @bootstrap)

    assert [revision_path] =
             Path.wildcard(Path.join([data_dir, "managed-config", "revisions", "*.etf"]))

    contents = File.read!(revision_path)
    assert Path.basename(revision_path) == revision <> ".etf"
    assert sha256(contents) == revision
    assert :nomatch == :binary.match(contents, "bootstrap-management-secret")
    assert :nomatch == :binary.match(contents, @bootstrap["data_dir"])

    assert {:ok, @managed_a} = Manager.read_revision(data_dir, revision)
    assert {:ok, ^revision} = Manager.install(data_dir, @managed_a)

    equivalent = Map.new(Enum.reverse(Map.to_list(@managed_a)))
    assert {:ok, ^revision} = Manager.install(data_dir, equivalent)

    File.write!(revision_path, "corrupt")
    assert {:error, :conflict} = Manager.install(data_dir, @managed_a)
    assert File.read!(revision_path) == "corrupt"
  end

  test "round-trips the exact typed null document in immutable history", %{data_dir: data_dir} do
    document = wire_document("dns.optional_value", %{"type" => "null", "value" => nil})

    assert :ok = Manager.validate_document(document)
    assert {:ok, revision} = Manager.install(data_dir, document)
    assert {:ok, ^document} = Manager.read_revision(data_dir, revision)
    assert {:ok, runtime} = Manager.materialize(document, @bootstrap)
    refute Map.has_key?(runtime["dns"], "optional_value")

    default_document = wire_document("dns.port", %{"type" => "null", "value" => nil})
    assert {:ok, without_default} = Manager.materialize(default_document, @bootstrap)
    refute Map.has_key?(without_default["dns"], "port")
  end

  test "rejects malformed and unsafe deterministic-term revisions before use", %{
    data_dir: data_dir
  } do
    malformed_revision = write_raw_revision(data_dir, @storage_magic <> "not-an-external-term")
    assert {:error, :corrupt} = Manager.read_revision(data_dir, malformed_revision)

    unsafe = @storage_magic <> :erlang.term_to_binary({:yellow_dog_managed_config, 1, self()})
    unsafe_revision = write_raw_revision(data_dir, unsafe)
    assert {:error, :corrupt} = Manager.read_revision(data_dir, unsafe_revision)

    wrong_wrapper = @storage_magic <> :erlang.term_to_binary({:other_format, 1, @managed_a})
    wrong_revision = write_raw_revision(data_dir, wrong_wrapper)
    assert {:error, :corrupt} = Manager.read_revision(data_dir, wrong_revision)

    compressed =
      @storage_magic <>
        :erlang.term_to_binary({:yellow_dog_managed_config, 1, @managed_a}, compressed: 9)

    compressed_revision = write_raw_revision(data_dir, compressed)
    assert {:error, :corrupt} = Manager.read_revision(data_dir, compressed_revision)
  end

  test "requires a canonical absolute data directory" do
    assert {:error, :invalid} = Manager.install("relative/data", @managed_a)
    assert {:error, :invalid} = Manager.install("/tmp/../tmp/yellow-dog", @managed_a)
    assert {:error, :invalid} = Manager.active_revision(nil)
    assert {:error, :invalid} = Manager.read_revision("/tmp", <<255>>)
  end

  test "never follows a managed-config directory symlink outside the caller data directory", %{
    data_dir: data_dir
  } do
    outside = data_dir <> "-outside"
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(data_dir, "managed-config"))
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, :storage} = Manager.install(data_dir, @managed_a)
    assert File.ls!(outside) == []
  end

  test "reads only digest-verified immutable revisions", %{data_dir: data_dir} do
    assert {:ok, revision} = Manager.install(data_dir, @managed_a)
    path = revision_path(data_dir, revision)
    File.write!(path, flip_last_byte(File.read!(path)))

    assert {:error, :corrupt} = Manager.read_revision(data_dir, revision)
    assert {:error, :invalid} = Manager.read_revision(data_dir, "not-a-revision")
    assert {:error, :not_found} = Manager.read_revision(data_dir, String.duplicate("f", 64))
  end

  test "activates the exact installed revision and atomically advances one pointer manifest", %{
    data_dir: data_dir
  } do
    assert {:ok, revision_a} = Manager.install(data_dir, @managed_a)
    assert {:ok, revision_b} = Manager.install(data_dir, @managed_b)

    assert {:ok, %{revision: ^revision_a, config: runtime_a}} =
             Manager.activate(data_dir, revision_a, @bootstrap)

    assert Config.get_all() == runtime_a
    assert {:ok, ^revision_a} = Manager.active_revision(data_dir)
    assert {:error, :not_found} = Manager.previous_revision(data_dir)

    assert {:ok, %{revision: ^revision_a, config: ^runtime_a}} =
             Manager.read_active(data_dir, @bootstrap)

    assert {:ok, %{revision: ^revision_b, config: runtime_b}} =
             Manager.activate(data_dir, revision_b, @bootstrap)

    assert Config.get_all() == runtime_b
    assert runtime_b["dns"]["listen"] == "192.0.2.11"
    assert {:ok, ^revision_b} = Manager.active_revision(data_dir)
    assert {:ok, ^revision_a} = Manager.previous_revision(data_dir)

    assert File.regular?(Path.join([data_dir, "managed-config", "pointers.etf"]))
    refute File.exists?(Path.join([data_dir, "managed-config", "active"]))
    refute File.exists?(Path.join([data_dir, "managed-config", "previous"]))
    assert Path.wildcard(Path.join([data_dir, "managed-config", ".pointers.etf.*.stage"])) == []
  end

  test "compensates a first activation exactly back to bootstrap and empty pointers", %{
    data_dir: data_dir
  } do
    assert {:ok, revision} = Manager.install(data_dir, @managed_a)

    assert {:ok, %{revision: ^revision, recovery: recovery}} =
             Manager.activate(data_dir, revision, @bootstrap)

    refute inspect(recovery) =~ "bootstrap-management-secret"
    refute inspect(recovery) =~ data_dir

    assert {:ok, %{revision: nil, config: @bootstrap}} =
             Manager.compensate(data_dir, recovery, @bootstrap)

    assert Config.get_all() == @bootstrap
    assert {:error, :not_found} = Manager.active_revision(data_dir)
    assert {:error, :not_found} = Manager.previous_revision(data_dir)
    assert File.regular?(Path.join([data_dir, "managed-config", "pointers.etf"]))
  end

  test "compensation restores the exact pre-activation manifest and managed runtime", %{
    data_dir: data_dir
  } do
    assert {:ok, revision_a} = Manager.install(data_dir, @managed_a)
    assert {:ok, revision_b} = Manager.install(data_dir, @managed_b)
    assert {:ok, _activated} = Manager.activate(data_dir, revision_a, @bootstrap)

    assert {:ok, %{revision: ^revision_b, recovery: recovery}} =
             Manager.activate(data_dir, revision_b, @bootstrap)

    assert {:ok, %{revision: ^revision_a, config: restored}} =
             Manager.compensate(data_dir, recovery, @bootstrap)

    assert Config.get_all() == restored
    assert restored["dns"]["listen"] == "192.0.2.10"
    assert {:ok, ^revision_a} = Manager.active_revision(data_dir)
    assert {:error, :not_found} = Manager.previous_revision(data_dir)
  end

  test "rejects stale or malformed compensation tokens without changing current state", %{
    data_dir: data_dir
  } do
    assert {:ok, revision_a} = Manager.install(data_dir, @managed_a)
    assert {:ok, revision_b} = Manager.install(data_dir, @managed_b)

    assert {:ok, %{recovery: stale_recovery}} =
             Manager.activate(data_dir, revision_a, @bootstrap)

    assert {:ok, %{config: runtime_b}} = Manager.activate(data_dir, revision_b, @bootstrap)

    assert {:error, :conflict} = Manager.compensate(data_dir, stale_recovery, @bootstrap)
    assert {:error, :invalid} = Manager.compensate(data_dir, :not_a_token, @bootstrap)
    assert Config.get_all() == runtime_b
    assert {:ok, ^revision_b} = Manager.active_revision(data_dir)
    assert {:ok, ^revision_a} = Manager.previous_revision(data_dir)
  end

  test "rejects a recovery token after a repeated activation of the same revision", %{
    data_dir: data_dir
  } do
    assert {:ok, revision} = Manager.install(data_dir, @managed_a)
    assert {:ok, %{recovery: stale_recovery}} = Manager.activate(data_dir, revision, @bootstrap)
    assert {:ok, %{config: current}} = Manager.activate(data_dir, revision, @bootstrap)

    assert {:error, :conflict} = Manager.compensate(data_dir, stale_recovery, @bootstrap)
    assert Config.get_all() == current
    assert {:ok, ^revision} = Manager.active_revision(data_dir)
    assert {:error, :not_found} = Manager.previous_revision(data_dir)
  end

  test "never revalidates a compensated token after bootstrap is activated again", %{
    data_dir: data_dir
  } do
    assert {:ok, revision} = Manager.install(data_dir, @managed_a)

    assert {:ok, %{recovery: original_recovery}} =
             Manager.activate(data_dir, revision, @bootstrap)

    assert {:ok, %{revision: nil}} =
             Manager.compensate(data_dir, original_recovery, @bootstrap)

    assert {:ok, %{config: current, recovery: current_recovery}} =
             Manager.activate(data_dir, revision, @bootstrap)

    assert {:error, :conflict} = Manager.compensate(data_dir, original_recovery, @bootstrap)
    assert Config.get_all() == current
    assert {:ok, ^revision} = Manager.active_revision(data_dir)

    assert {:ok, %{revision: nil}} =
             Manager.compensate(data_dir, current_recovery, @bootstrap)
  end

  test "retry after an unacknowledged activation compensates to the effective known-good revision",
       %{
         data_dir: data_dir
       } do
    assert {:ok, revision_a} = Manager.install(data_dir, @managed_a)
    assert {:ok, revision_b} = Manager.install(data_dir, @managed_b)

    assert {:ok, %{config: runtime_a}} = Manager.activate(data_dir, revision_a, @bootstrap)
    assert {:ok, %{config: runtime_b}} = Manager.activate(data_dir, revision_b, @bootstrap)

    # Model a restart: the durable apply journal selects acknowledged A even
    # though the pointer manifest already contains unacknowledged candidate B.
    assert :ok = Config.replace(runtime_a)
    refute Config.get_all() == runtime_b

    assert {:ok, %{recovery: recovery}} = Manager.activate(data_dir, revision_b, @bootstrap)

    assert {:ok, %{revision: ^revision_a, config: ^runtime_a}} =
             Manager.compensate(data_dir, recovery, @bootstrap)

    assert Config.get_all() == runtime_a
    assert {:ok, ^revision_a} = Manager.active_revision(data_dir)
    assert {:ok, ^revision_b} = Manager.previous_revision(data_dir)
  end

  test "binds recovery to the exact bootstrap used by activation", %{data_dir: data_dir} do
    assert {:ok, revision} = Manager.install(data_dir, @managed_a)

    assert {:ok, %{config: runtime, recovery: recovery}} =
             Manager.activate(data_dir, revision, @bootstrap)

    assert {:error, :invalid} =
             Manager.compensate(data_dir, recovery, %{"unbound" => "replacement"})

    assert Config.get_all() == runtime
    assert {:ok, ^revision} = Manager.active_revision(data_dir)
  end

  test "serializes concurrent activations so the pointer and effective config agree", %{
    data_dir: data_dir
  } do
    assert {:ok, revision_a} = Manager.install(data_dir, @managed_a)
    assert {:ok, revision_b} = Manager.install(data_dir, @managed_b)

    [revision_a, revision_b]
    |> List.duplicate(6)
    |> List.flatten()
    |> Enum.map(fn revision ->
      Task.async(fn -> Manager.activate(data_dir, revision, @bootstrap) end)
    end)
    |> Enum.each(fn task -> assert {:ok, %{revision: _revision}} = Task.await(task, 10_000) end)

    assert {:ok, %{revision: active, config: active_config}} =
             Manager.read_active(data_dir, @bootstrap)

    assert {:ok, ^active} = Manager.active_revision(data_dir)
    assert Config.get_all() == active_config
  end

  test "boot uses the exact acknowledged revision instead of an unacknowledged active candidate",
       %{
         data_dir: data_dir
       } do
    assert {:ok, revision_a} = Manager.install(data_dir, @managed_a)
    assert {:ok, %{revision: ^revision_a}} = Manager.activate(data_dir, revision_a, @bootstrap)
    assert {:ok, revision_b} = Manager.install(data_dir, @managed_b)
    assert {:ok, %{revision: ^revision_b}} = Manager.activate(data_dir, revision_b, @bootstrap)

    assert {:ok, ^revision_b} = Manager.active_revision(data_dir)

    assert {:ok, %{revision: ^revision_a, config: runtime}} =
             Manager.boot_config(data_dir, revision_a, @bootstrap)

    assert runtime["dns"]["listen"] == "192.0.2.10"
    refute revision_a == revision_b
  end

  test "restores and reactivates the previous exact revision", %{data_dir: data_dir} do
    assert {:ok, revision_a} = Manager.install(data_dir, @managed_a)
    assert {:ok, revision_b} = Manager.install(data_dir, @managed_b)
    assert {:ok, _activated} = Manager.activate(data_dir, revision_a, @bootstrap)
    assert {:ok, _activated} = Manager.activate(data_dir, revision_b, @bootstrap)

    assert {:ok, %{revision: ^revision_a, config: restored}} =
             Manager.restore_previous(data_dir, @bootstrap)

    assert Config.get_all() == restored
    assert restored["dns"]["listen"] == "192.0.2.10"
    assert {:ok, ^revision_a} = Manager.active_revision(data_dir)
    assert {:ok, ^revision_b} = Manager.previous_revision(data_dir)
  end

  test "restores a caller-selected revision and subsequent activation is idempotent", %{
    data_dir: data_dir
  } do
    assert {:ok, revision_a} = Manager.install(data_dir, @managed_a)
    assert {:ok, revision_b} = Manager.install(data_dir, @managed_b)
    assert {:ok, _activated} = Manager.activate(data_dir, revision_a, @bootstrap)
    assert {:ok, _activated} = Manager.activate(data_dir, revision_b, @bootstrap)

    assert {:ok, %{revision: ^revision_a, config: restored}} =
             Manager.restore(data_dir, revision_a, @bootstrap)

    assert Config.get_all() == restored
    assert {:ok, ^revision_a} = Manager.active_revision(data_dir)
    assert {:ok, ^revision_b} = Manager.previous_revision(data_dir)

    assert {:ok, %{revision: ^revision_a, config: ^restored}} =
             Manager.activate(data_dir, revision_a, @bootstrap)

    assert {:ok, ^revision_b} = Manager.previous_revision(data_dir)
  end

  test "activation fails closed before pointer mutation when Config is unavailable", %{
    data_dir: data_dir
  } do
    assert {:ok, revision} = Manager.install(data_dir, @managed_a)
    stop_config()

    assert {:error, :not_started} = Manager.activate(data_dir, revision, @bootstrap)
    assert {:error, :not_found} = Manager.active_revision(data_dir)
  end

  test "boot selection ignores a corrupt pointer manifest", %{data_dir: data_dir} do
    assert {:ok, revision} = Manager.install(data_dir, @managed_a)
    assert {:ok, _activated} = Manager.activate(data_dir, revision, @bootstrap)
    manifest_path = Path.join([data_dir, "managed-config", "pointers.etf"])

    File.write!(manifest_path, "corrupt")
    assert {:error, :corrupt} = Manager.active_revision(data_dir)
    assert {:error, :corrupt} = Manager.read_active(data_dir, @bootstrap)

    assert {:ok, %{revision: ^revision, config: runtime}} =
             Manager.boot_config(data_dir, revision, @bootstrap)

    assert runtime["dns"]["listen"] == "192.0.2.10"
    refute function_exported?(Manager, :boot_config, 2)
  end

  test "remains process-free and keeps legacy Settings calls typed unsupported" do
    refute function_exported?(Manager, :start_link, 1)
    refute function_exported?(Manager, :child_spec, 1)
    refute is_pid(Process.whereis(Manager))

    assert Manager.effective("dns") == {:error, :unsupported}
    assert Manager.source("dns") == {:error, :unsupported}
    assert Manager.revision("dns") == {:error, :unsupported}
    assert Manager.validation("dns") == {:error, :unsupported}
    assert Manager.update("dns", []) == {:error, :unsupported}
    assert Manager.apply("dns") == {:error, :unsupported}
    assert Manager.reload("dns") == {:error, :unsupported}
    assert Manager.rollback("dns", String.duplicate("a", 64)) == {:error, :unsupported}
  end

  defp wire_document(setting, value) do
    %{
      "schema_version" => 1,
      "profile" => "custom",
      "entries" => [%{"setting" => setting, "value" => value}]
    }
  end

  defp write_raw_revision(data_dir, contents) do
    revision = sha256(contents)
    path = revision_path(data_dir, revision)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    revision
  end

  defp revision_path(data_dir, revision) do
    Path.join([data_dir, "managed-config", "revisions", revision <> ".etf"])
  end

  defp sha256(contents) do
    contents
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp flip_last_byte(contents) do
    last_index = byte_size(contents) - 1
    <<prefix::binary-size(last_index), last>> = contents
    prefix <> <<Bitwise.bxor(last, 1)>>
  end

  defp stop_config do
    case Process.whereis(Config) do
      nil ->
        :ok

      pid ->
        try do
          Agent.stop(pid)
        catch
          :exit, _reason -> :ok
        end
    end
  end
end
