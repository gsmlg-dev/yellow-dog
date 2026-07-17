defmodule YellowDog.Server.Control.SettingsControlTest do
  use ExUnit.Case, async: false

  alias YellowDog.Server.Control
  alias YellowDog.Server.Control.Dispatcher
  alias YellowDog.Server.Control.Settings
  alias YellowDog.ServerSettingsControlFake
  alias YellowDog.ServerSettingsControlFake.Manager
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @request_id "00000000-0000-0000-0000-0000000007d1"
  @idempotency_key "00000000-0000-0000-0000-0000000007d2"
  @sent_at ~U[2026-07-17 00:00:00Z]
  @digest String.duplicate("a", 64)

  setup do
    previous_settings_config = Application.get_env(:yellow_dog, Settings)
    previous_dispatcher_config = Application.get_env(:yellow_dog, Dispatcher)

    Application.put_env(:yellow_dog, Settings, manager: Manager)
    Application.put_env(:yellow_dog, Dispatcher, adapters: %{settings: Settings})
    start_supervised!(ServerSettingsControlFake)

    on_exit(fn ->
      restore_env(Settings, previous_settings_config)
      restore_env(Dispatcher, previous_dispatcher_config)
    end)

    :ok
  end

  test "delegates every validated Settings operation through the fixed Manager boundary" do
    operations = [
      {"server.settings.effective.get", %{"service" => "dns"}, {:effective, ["dns"]}},
      {"server.settings.source.get", %{"service" => "dns"}, {:source, ["dns"]}},
      {"server.settings.revision.get", %{"service" => "dns"}, {:revision, ["dns"]}},
      {"server.settings.validation.get", %{"service" => "dns"}, {:validation, ["dns"]}},
      {"server.settings.update", update_payload([]), {:update, ["dns", []]}},
      {"server.settings.apply", %{"service" => "dns"}, {:apply, ["dns"]}},
      {"server.settings.reload", %{"service" => "dns"}, {:reload, ["dns"]}},
      {"server.settings.rollback", rollback_payload(), {:rollback, ["dns", @digest]}}
    ]

    for {operation, payload, _call} <- operations do
      assert_unsupported(Settings.dispatch(operation, payload))
    end

    assert Enum.map(operations, &elem(&1, 2)) == ServerSettingsControlFake.take_calls()
  end

  test "rejects malformed payloads before Manager delegation" do
    cases = [
      {"server.settings.effective.get", %{"service" => "../dns"}},
      {"server.settings.source.get", %{"service" => "dns", "limit" => 0}},
      {"server.settings.revision.get", %{"service" => "dns", "cursor" => "/tmp"}},
      {"server.settings.validation.get", %{"service" => "dns", "extra" => true}},
      {"server.settings.update",
       update_payload([%{"key" => "path", "value" => %{"type" => "string", "value" => "/tmp"}}])},
      {"server.settings.apply", %{"service" => "dns", "extra" => true}},
      {"server.settings.reload", %{"service" => "dns", "limit" => 1}},
      {"server.settings.rollback", %{"service" => "dns", "target_revision" => "not-a-digest"}}
    ]

    for {operation, payload} <- cases do
      assert_invalid(Settings.dispatch(operation, payload))
      assert_invalid(Settings.current(operation, payload))
    end

    assert [] = ServerSettingsControlFake.take_calls()
  end

  test "real Dispatcher paths delegate each Settings read after envelope validation" do
    operations = [
      {"server.settings.effective.get", %{"service" => "dns"}, :effective},
      {"server.settings.source.get", %{"service" => "dns"}, :source},
      {"server.settings.revision.get", %{"service" => "dns"}, :revision},
      {"server.settings.validation.get", %{"service" => "dns"}, :validation}
    ]

    for {operation, payload, _manager_operation} <- operations do
      assert_unsupported(Control.dispatch(envelope(operation, payload)))
    end

    assert Enum.map(operations, fn {_operation, _payload, manager_operation} ->
             {manager_operation, ["dns"]}
           end) == ServerSettingsControlFake.take_calls()
  end

  test "Dispatcher validates malformed Settings payloads before the adapter" do
    assert_invalid(
      Control.dispatch(
        envelope("server.settings.update", update_payload([], "../dns"), config_version: 1)
      )
    )

    assert [] = ServerSettingsControlFake.take_calls()
  end

  test "unsupported mutation current snapshots prevent stale revision fabrication" do
    operations = [
      {"server.settings.update", update_payload([]), [config_version: 1]},
      {"server.settings.apply", %{"service" => "dns"}, []},
      {"server.settings.reload", %{"service" => "dns"}, []},
      {"server.settings.rollback", rollback_payload(), []}
    ]

    for {operation, payload, overrides} <- operations do
      assert_unsupported(
        Control.dispatch(
          envelope(operation, payload, Keyword.merge(overrides, expected_revision: @digest))
        )
      )
    end

    assert [] = ServerSettingsControlFake.take_calls()
  end

  test "bounds Settings entries before Manager delegation" do
    maximum = Bounds.max_list_entries()
    entries = List.duplicate(entry(), 8)

    assert_unsupported(Settings.dispatch("server.settings.update", update_payload(entries)))

    assert [{:update, ["dns", ^entries]}] = ServerSettingsControlFake.take_calls()

    assert_invalid(
      Settings.dispatch(
        "server.settings.update",
        update_payload(List.duplicate(entry(), maximum + 1))
      )
    )

    assert [] = ServerSettingsControlFake.take_calls()
  end

  test "maps Manager failures and exceptions to fixed errors without leaking details" do
    for {response, code} <- [
          {{:error, :invalid}, :invalid},
          {{:error, :not_found}, :not_found},
          {{:error, :conflict}, :conflict},
          {{:error, :apply_failed}, :apply_failed},
          {{:error, :rollback_failed}, :rollback_failed},
          {{:error, :unsupported}, :unsupported},
          {{:raise, "token=settings-secret path=/tmp/settings"}, :apply_failed},
          {{:throw, "token=settings-secret path=/tmp/settings"}, :apply_failed},
          {{:exit, "token=settings-secret path=/tmp/settings"}, :apply_failed}
        ] do
      ServerSettingsControlFake.configure(:source, response)

      assert {:error, %Error{code: ^code, details: %{}} = error} =
               Settings.dispatch("server.settings.source.get", %{"service" => "dns"})

      refute inspect(error) =~ "settings-secret"
      refute inspect(error) =~ "/tmp/settings"
    end
  end

  test "returns not found for an unavailable Manager owner and rejects invalid overrides" do
    Application.put_env(:yellow_dog, Settings, manager: YellowDog.MissingSettingsManager)

    assert {:error, %Error{code: :not_found, details: %{}}} =
             Settings.dispatch("server.settings.source.get", %{"service" => "dns"})

    Application.put_env(:yellow_dog, Settings, unexpected: Manager)

    assert {:error, %Error{code: :internal, details: %{}}} =
             Settings.dispatch("server.settings.source.get", %{"service" => "dns"})
  end

  test "uses Dispatcher normalization to redact recursively sensitive effective settings" do
    secret = "nested-settings-secret"

    ServerSettingsControlFake.configure(:effective, {
      :ok,
      %{
        "service" => "dns",
        "entries" => [
          %{
            "key" => "database",
            "value" => %{
              "type" => "object",
              "entries" => [
                %{
                  "key" => "client_secret",
                  "value" => %{"type" => "string", "value" => secret}
                }
              ]
            }
          }
        ]
      }
    })

    assert {:ok,
            %{
              "entries" => [
                %{
                  "value" => %{
                    "entries" => [
                      %{"value" => %{"type" => "string", "value" => "[redacted]"}}
                    ]
                  }
                }
              ]
            } = result} =
             Control.dispatch(envelope("server.settings.effective.get", %{"service" => "dns"}))

    refute inspect(result) =~ secret
  end

  test "Dispatcher enforces bounded effective entries and validation diagnostics from Manager results" do
    maximum = Bounds.max_list_entries()
    validation_error = %{"field" => "service", "message" => "invalid"}

    ServerSettingsControlFake.configure(:validation, {
      :ok,
      %{"service" => "dns", "valid" => false, "errors" => [validation_error]}
    })

    assert {:ok, %{"errors" => errors}} =
             Control.dispatch(envelope("server.settings.validation.get", %{"service" => "dns"}))

    assert errors == [validation_error]

    ServerSettingsControlFake.configure(:validation, {
      :ok,
      %{
        "service" => "dns",
        "valid" => false,
        "errors" => List.duplicate(validation_error, maximum + 1)
      }
    })

    assert_invalid(
      Control.dispatch(envelope("server.settings.validation.get", %{"service" => "dns"}))
    )
  end

  test "adapter source contains no direct Config Agent, filesystem, runtime, or TOML access" do
    source =
      File.read!(Path.expand("../../../../lib/yellow_dog/server/control/settings.ex", __DIR__))

    for forbidden <- [
          "YellowDog.Config.get",
          "YellowDog.Config.Writer",
          "File.",
          ":file.",
          "Toml",
          "System.",
          "YellowDog.ServiceManager"
        ] do
      refute source =~ forbidden
    end
  end

  defp update_payload(entries, service \\ "dns"),
    do: %{"service" => service, "entries" => entries}

  defp rollback_payload, do: %{"service" => "dns", "target_revision" => @digest}

  defp entry do
    %{"key" => "enabled", "value" => %{"type" => "boolean", "value" => true}}
  end

  defp envelope(operation, payload, overrides \\ []) do
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: Keyword.get(overrides, :request_id, @request_id),
      target_type: :server,
      target_id: "server-settings-test",
      operation: operation,
      idempotency_key: Keyword.get(overrides, :idempotency_key, @idempotency_key),
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: Keyword.get(overrides, :expected_revision),
      config_version: Keyword.get(overrides, :config_version),
      sent_at: @sent_at
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:yellow_dog, module)
  defp restore_env(module, config), do: Application.put_env(:yellow_dog, module, config)

  defp assert_invalid({:error, %Error{code: :invalid}}), do: :ok
  defp assert_invalid(other), do: flunk("expected invalid error, got: #{inspect(other)}")

  defp assert_unsupported({:error, %Error{code: :unsupported}}), do: :ok

  defp assert_unsupported(other),
    do: flunk("expected unsupported error, got: #{inspect(other)}")
end
