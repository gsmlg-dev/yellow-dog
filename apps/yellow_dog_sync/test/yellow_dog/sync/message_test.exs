defmodule YellowDog.Sync.MessageTest do
  use ExUnit.Case, async: true

  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Identity
  alias YellowDog.Sync.Message

  alias Message.{
    Command,
    ConfigDelivery,
    ConfigState,
    Event,
    Heartbeat,
    Hello,
    Journal,
    Query,
    Result,
    Status
  }

  @request_id "7f12c5d1-6a5d-4b2e-9a75-4a6d5d8f18c0"
  @idempotency_key "47b8f6f4-9293-4a20-9327-1a15d87fe427"
  @event_id "39c5b8cc-fc32-40c5-9517-3d5c0a423df4"
  @sent_at ~U[2026-07-16 08:30:00Z]

  @messages [
    %Hello{
      identity: %Identity.Server{
        id: "server-1",
        name: "Server 1",
        version: "1.0.0",
        profile: "default",
        capabilities: ["runtime.services"],
        config_revision: String.duplicate("a", 64)
      }
    },
    %Heartbeat{target_type: :server, target_id: "server-1", observed_at: @sent_at},
    %Status{
      target_type: :server,
      target_id: "server-1",
      state: :online,
      details: %{"services" => 4},
      observed_at: @sent_at
    },
    %Query{envelope: nil},
    %Command{envelope: nil},
    %Result{
      request_id: @request_id,
      target_type: :server,
      operation: "server.runtime.services.list",
      value: nil,
      error: nil
    },
    %ConfigDelivery{envelope: nil},
    %ConfigState{
      target_type: :server,
      target_id: "server-1",
      operation: "server.settings.update",
      state: :applied,
      version: "version-1",
      digest: String.duplicate("a", 64),
      applied_revision: String.duplicate("b", 64),
      previous_revision: nil,
      failure: nil,
      rollback: nil,
      observed_at: @sent_at
    },
    %Journal{
      target_type: :server,
      target_id: "server-1",
      entries: [
        %{
          "request_id" => @request_id,
          "operation" => "server.runtime.services.list",
          "status" => "completed",
          "result" => %{
            "items" => [],
            "revision" => String.duplicate("a", 64),
            "observed_at" => DateTime.to_iso8601(@sent_at)
          },
          "error" => nil
        }
      ]
    },
    %Event{
      target_type: :server,
      target_id: "server-1",
      event_id: @event_id,
      name: "runtime.service.started",
      payload: %{"service" => "dns"},
      observed_at: @sent_at
    }
  ]

  test "round trips every required message type through canonical JSON" do
    messages =
      Enum.map(@messages, fn
        %Query{} ->
          %Query{envelope: envelope("server.runtime.services.list", %{})}

        %Command{} ->
          %Command{
            envelope: envelope("server.runtime.services.start", %{"service" => "dns"})
          }

        %Result{} = result ->
          %{result | value: snapshot([])}

        %ConfigDelivery{} ->
          %ConfigDelivery{
            envelope: envelope("server.settings.update", settings_config())
          }

        message ->
          message
      end)

    for message <- messages do
      assert {:ok, encoded} = Message.encode(message)
      assert {:ok, decoded} = Message.decode(encoded)
      assert decoded == message
    end
  end

  test "query command and config delivery reject target or kind mismatches" do
    netman_query = envelope("netman.profiles.list", %{}, target_type: :server)
    command_as_query = envelope("server.runtime.services.start", %{"resource_id" => "dns"})
    query_as_command = envelope("server.runtime.services.list", %{})
    command_as_config = envelope("server.runtime.services.start", %{"resource_id" => "dns"})

    assert_invalid(Message.encode(%Query{envelope: netman_query}))
    assert_invalid(Message.encode(%Query{envelope: command_as_query}))
    assert_invalid(Message.encode(%Command{envelope: query_as_command}))
    assert_invalid(Message.encode(%ConfigDelivery{envelope: command_as_config}))
  end

  test "message boundaries revalidate the complete envelope" do
    envelope = %{
      envelope("server.runtime.services.list", %{})
      | payload_digest: String.duplicate("0", 64)
    }

    assert_invalid(Message.encode(%Query{envelope: envelope}))
  end

  test "decode rejects extraneous fields inside a nested envelope" do
    message = %Query{envelope: envelope("server.runtime.services.list", %{})}
    assert {:ok, encoded} = Message.encode(message)

    wire = Jason.decode!(encoded)
    malformed = put_in(wire, ["payload", "unexpected"], true)

    assert_invalid(Message.decode(Jason.encode!(malformed)))
  end

  test "message wrapper preserves an envelope payload at the reviewed depth limit" do
    payload = depth_limit_payload()
    envelope = envelope("server.settings.update", payload)

    assert {:ok, _encoded_envelope} = Envelope.encode(envelope)
    assert {:ok, encoded_message} = Message.encode(%ConfigDelivery{envelope: envelope})
    assert {:ok, %ConfigDelivery{envelope: decoded}} = Message.decode(encoded_message)
    assert decoded.payload == payload
  end

  test "malformed Result errors return stable invalid values without raising" do
    malformed_errors = [
      %Error{code: :unknown, message: "bad", details: %{}},
      %Error{code: :invalid, message: 42, details: %{}},
      %Error{code: :invalid, message: "bad", details: []},
      %Error{code: :invalid, message: String.duplicate("x", 1_025), details: %{}},
      %Error{code: :invalid, message: "bad", details: %{"path" => "/etc/yellow-dog"}}
    ]

    for malformed_error <- malformed_errors do
      result = %Result{
        request_id: @request_id,
        target_type: :server,
        operation: "server.runtime.services.list",
        value: nil,
        error: malformed_error
      }

      assert_invalid(Message.encode(result))
    end
  end

  test "invalid operation payloads cannot decode to dispatchable messages" do
    payload = %{
      "resource_id" => "office",
      "value" => %{"path" => "/etc/network", "blob" => "raw"}
    }

    envelope = envelope("netman.profiles.put", payload, target_type: :netman)
    encoded = Jason.encode!(%{"type" => "command", "payload" => Envelope.to_wire(envelope)})

    assert_invalid(Message.decode(encoded))
  end

  test "config delivery rejects normalized forbidden setting names and local path values" do
    material_entries =
      for key <-
            ~w(payloads contents blobs certificates bodies byteBuffer tlsCert rawdata blobstore rawpayload payloadbody blobcontent blobdata blobbytes certificatebytes payloadstore tls_pem tlsKey secretKey signingKey privatekey tlskey secretkey signingkey privateKeys privatekeys tls_keys tlskeys secretkeys signingkeys pkcs12 pkcs-12 pfx PEMs PFXs request_payload_cache server_certificate_bundle client_tls_key_store archive_pfx_bundle tls_pem_bundle payload_valid certificate_grid) do
        %{"key" => key, "value" => %{"type" => "string", "value" => "YWJjZA=="}}
      end

    invalid_entries =
      material_entries ++
        [
          %{"key" => "local_path", "value" => %{"type" => "string", "value" => "/etc/shadow"}},
          %{"key" => "expected_revision", "value" => %{"type" => "string", "value" => "other"}},
          %{"key" => "Path", "value" => %{"type" => "string", "value" => "other"}},
          %{"key" => "Content", "value" => %{"type" => "string", "value" => "raw"}},
          %{"key" => "shadow_file", "value" => %{"type" => "string", "value" => "/etc/shadow"}},
          %{
            "key" => "nested",
            "value" => %{"type" => "object", "entries" => [], "Path" => "/etc/shadow"}
          },
          %{
            "key" => "nested",
            "value" => %{"type" => "object", "entries" => [], "Content" => "raw"}
          },
          %{
            "key" => "tls_certificate",
            "value" => %{"type" => "string", "value" => <<0, 1, 2, 3>>}
          },
          %{
            "key" => "rawPayload",
            "value" => %{"type" => "string", "value" => "YWJjZA=="}
          }
        ]

    for entry <- invalid_entries do
      payload = %{"service" => "dns", "entries" => [entry]}
      envelope = envelope("server.settings.update", payload)
      message = %ConfigDelivery{envelope: envelope}
      wire = %{"type" => "config_delivery", "payload" => Envelope.to_wire(envelope)}

      assert_invalid(Message.encode(message))
      assert_invalid(Message.decode(Jason.encode!(wire)))
    end
  end

  test "DNS zone import source and blob alternatives round trip as commands" do
    source = %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "source_type" => "provider",
      "source_id" => "route53",
      "source_revision" => String.duplicate("a", 64)
    }

    blob = %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "filename" => "example.test.zone",
      "size" => 42,
      "blob_digest" => String.duplicate("a", 64)
    }

    for payload <- [source, blob] do
      message = %Command{envelope: envelope("server.dns.zones.import", payload)}
      assert {:ok, encoded} = Message.encode(message)
      assert {:ok, ^message} = Message.decode(encoded)
    end
  end

  test "config state lifecycle contradictions fail at encode and decode boundaries" do
    state = %ConfigState{
      target_type: :server,
      target_id: "server-1",
      operation: "server.settings.update",
      state: :applied,
      version: "version-1",
      digest: String.duplicate("a", 64),
      applied_revision: nil,
      previous_revision: nil,
      failure: nil,
      rollback: nil,
      observed_at: @sent_at
    }

    wire = %{
      "type" => "config_state",
      "payload" => %{
        "target_type" => "server",
        "target_id" => "server-1",
        "operation" => "server.settings.update",
        "state" => %{
          "state" => "applied",
          "version" => "version-1",
          "digest" => String.duplicate("a", 64),
          "applied_revision" => nil,
          "previous_revision" => nil,
          "failure" => nil,
          "rollback" => nil
        },
        "observed_at" => DateTime.to_iso8601(@sent_at)
      }
    }

    assert_invalid(Message.encode(state))
    assert_invalid(Message.decode(Jason.encode!(wire)))
  end

  test "invalid operation results and journal values cannot cross the message boundary" do
    result = dns_view_list()
    invalid_result = %{result | "items" => [%{"path" => "/tmp/view", "blob" => "raw"}]}

    message = %Result{
      request_id: @request_id,
      target_type: :server,
      operation: "server.dns.views.list",
      value: invalid_result,
      error: nil
    }

    journal = %Journal{
      target_type: :server,
      target_id: "server-1",
      entries: [
        %{
          "request_id" => @request_id,
          "operation" => "server.dns.views.list",
          "status" => "completed",
          "result" => invalid_result,
          "error" => nil
        }
      ]
    }

    assert_invalid(Message.encode(message))
    assert_invalid(Message.encode(journal))

    result_wire = %{
      "type" => "result",
      "payload" => %{
        "request_id" => @request_id,
        "target_type" => "server",
        "operation" => "server.dns.views.list",
        "value" => invalid_result,
        "error" => nil
      }
    }

    journal_wire = %{
      "type" => "journal",
      "payload" => %{
        "target_type" => "server",
        "target_id" => "server-1",
        "entries" => journal.entries
      }
    }

    assert_invalid(Message.decode(Jason.encode!(result_wire)))
    assert_invalid(Message.decode(Jason.encode!(journal_wire)))
  end

  test "result and journal validate operation-specific result values" do
    invalid_result = %Result{
      request_id: @request_id,
      target_type: :server,
      operation: "server.runtime.services.list",
      value: %{"items" => []},
      error: nil
    }

    invalid_journal = %Journal{
      target_type: :server,
      target_id: "server-1",
      entries: [
        %{
          "request_id" => @request_id,
          "operation" => "server.runtime.services.list",
          "status" => "completed",
          "result" => %{},
          "error" => nil
        }
      ]
    }

    assert_invalid(Message.encode(invalid_result))
    assert_invalid(Message.encode(invalid_journal))
  end

  test "rejects unknown and extraneous message shapes" do
    assert_invalid(Message.decode(~s({"type":"unknown","payload":{}})))

    encoded =
      Jason.encode!(%{
        "type" => "heartbeat",
        "payload" => %{
          "target_type" => "server",
          "target_id" => "server-1",
          "observed_at" => DateTime.to_iso8601(@sent_at),
          "unexpected" => true
        }
      })

    assert_invalid(Message.decode(encoded))
  end

  test "rejects malformed and oversized message values with stable errors" do
    oversized = %Event{
      target_type: :server,
      target_id: "server-1",
      event_id: @event_id,
      name: String.duplicate("x", 1_025),
      payload: %{},
      observed_at: @sent_at
    }

    assert_invalid(Message.encode(oversized))
    assert_invalid(Message.decode("not json"))
    assert_invalid(Message.decode(String.duplicate(" ", Message.max_document_bytes() + 1)))
  end

  defp envelope(operation, payload, overrides \\ []) do
    target_type = Keyword.get(overrides, :target_type, :server)

    %Envelope{
      protocol_version: 1,
      request_id: @request_id,
      target_type: target_type,
      target_id: if(target_type == :server, do: "server-1", else: "netman-1"),
      operation: operation,
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: digest(payload),
      expected_revision: nil,
      sent_at: @sent_at
    }
  end

  defp digest(payload) do
    {:ok, digest} = Digest.calculate(payload)
    digest
  end

  defp snapshot(items) do
    %{
      "items" => items,
      "revision" => String.duplicate("a", 64),
      "observed_at" => DateTime.to_iso8601(@sent_at)
    }
  end

  defp dns_view_list do
    %{
      "items" => [
        %{
          "view_name" => "default",
          "match_clients" => ["0.0.0.0/0"],
          "recursion" => false
        }
      ],
      "revision" => String.duplicate("a", 64),
      "observed_at" => DateTime.to_iso8601(@sent_at)
    }
  end

  defp settings_config do
    %{
      "service" => "dns",
      "entries" => [
        %{
          "key" => "listen",
          "value" => %{"type" => "string", "value" => "0.0.0.0"}
        }
      ]
    }
  end

  defp depth_limit_payload do
    %{
      "service" => "dns",
      "entries" => [
        %{
          "key" => "nested",
          "value" => %{
            "type" => "object",
            "entries" => [
              %{
                "key" => "leaf",
                "value" => %{"type" => "list", "items" => ["value"]}
              }
            ]
          }
        }
      ]
    }
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} = result
  end
end
