defmodule YellowDog.Console.ManagementResultTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Sync.Error

  test "normalizes successful runtime and cached values into LiveView-ready assigns" do
    observed_at = DateTime.utc_now()
    snapshot = %{revision: String.duplicate("a", 64), observed_at: observed_at}

    runtime = ManagementResult.normalize({:ok, %{"items" => []}}, source: :runtime)

    cached =
      ManagementResult.normalize({:ok, %{"items" => ["cached"]}},
        source: :cache,
        observed_at: observed_at,
        snapshot: snapshot
      )

    assert %ManagementResult{status: :ok, source: :runtime, observed_at: nil} = runtime

    assert %{
             management_status: :ok,
             management_value: %{"items" => ["cached"]},
             management_source: :cache,
             management_observed_at: ^observed_at,
             management_error: nil
           } = ManagementResult.assigns(cached)

    assert cached.snapshot == snapshot
    assert ManagementResult.flash(cached) == nil
  end

  test "preserves safe conflict and validation metadata for rendering" do
    conflict =
      Error.new(:conflict, "stale revision", %{
        "expected_revision" => String.duplicate("a", 64),
        "current_revision" => String.duplicate("b", 64)
      })

    invalid =
      Error.new(:invalid, "validation failed", %{
        "field" => "interface",
        "errors" => ["is invalid"]
      })

    assert %ManagementResult{
             status: :error,
             code: :conflict,
             message: "stale revision",
             details: %{
               "expected_revision" => expected,
               "current_revision" => current
             }
           } = conflict_result = ManagementResult.normalize({:error, conflict})

    assert expected == String.duplicate("a", 64)
    assert current == String.duplicate("b", 64)
    assert ManagementResult.flash(conflict_result) == {:error, "stale revision"}

    assert %ManagementResult{
             code: :invalid,
             details: %{"field" => "interface", "errors" => ["is invalid"]}
           } = ManagementResult.normalize({:error, invalid})
  end

  test "normalizes timeout and unsupported errors to their stable codes" do
    for code <- [
          :not_connected,
          :not_found,
          :unsupported,
          :timeout,
          :apply_failed,
          :rollback_failed
        ] do
      error = Error.new(code, "stable #{code}", %{"capability" => "example"})

      assert %ManagementResult{status: :error, code: ^code, message: message} =
               ManagementResult.normalize({:error, error})

      assert message == "stable #{code}"
    end
  end

  test "internal and malformed failures are bounded and never expose paths or stack traces" do
    internal = %Error{
      code: :internal,
      message: String.duplicate("x", 4_000) <> " /etc/yellowdog/secret.toml",
      details: %{
        "path" => "/etc/yellowdog/secret.toml",
        "stacktrace" => "lib/private.ex:42"
      }
    }

    assert %ManagementResult{
             status: :error,
             code: :internal,
             message: "The management request failed",
             details: %{}
           } = result = ManagementResult.normalize({:error, internal})

    rendered = inspect({ManagementResult.assigns(result), ManagementResult.flash(result)})
    refute rendered =~ "/etc/yellowdog"
    refute rendered =~ "private.ex"

    assert %ManagementResult{
             status: :error,
             code: :internal,
             message: "The management request failed",
             details: %{}
           } = ManagementResult.normalize({:exit, {:enoent, "/private/path"}})
  end

  test "non-internal errors retain safe metadata but redact accidental local diagnostics" do
    invalid = %Error{
      code: :invalid,
      message: "validation failed in /etc/yellowdog/netman.toml",
      details: %{
        "field" => "interface",
        "reason" => "raised at lib/yellow_dog/private.ex:42",
        "stacktrace" => "hidden"
      }
    }

    assert %ManagementResult{
             code: :invalid,
             message: "The management request was invalid",
             details: %{"field" => "interface", "reason" => "[redacted]"}
           } = result = ManagementResult.normalize({:error, invalid})

    rendered = inspect(result)
    refute rendered =~ "/etc/yellowdog"
    refute rendered =~ "private.ex"
    refute rendered =~ "stacktrace"
  end
end
