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
          %Command{envelope: envelope("server.runtime.services.start", %{"resource_id" => "dns"})}

        %Result{} = result ->
          %{result | value: snapshot([])}

        %ConfigDelivery{} ->
          %ConfigDelivery{
            envelope:
              envelope("server.settings.update", %{"resource_id" => "dns", "value" => %{}})
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

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} = result
  end
end
