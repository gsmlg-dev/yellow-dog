defmodule YellowDogIdentity.Trust.RouterTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Trust.Router

  defmodule MockTrustedProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context) do
      {:trusted, :network_verified, %{provider: :mock, mock: true}}
    end
  end

  defmodule MockSkipProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context) do
      {:skip, :not_applicable}
    end
  end

  defmodule MockUntrustedProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context) do
      {:untrusted, :test_reason}
    end
  end

  @base_context %{
    source_ip: {192, 168, 1, 100},
    hostname: "test-host",
    attestation: nil,
    metadata: %{},
    authorization: nil
  }

  describe "verify/2" do
    test "returns trusted from first matching provider" do
      result = Router.verify(@base_context, providers: [MockTrustedProvider])
      assert {:network_verified, provider_name, %{provider: :mock}} = result
      assert is_atom(provider_name)
    end

    test "skips non-applicable providers" do
      result =
        Router.verify(@base_context,
          providers: [MockSkipProvider, MockTrustedProvider]
        )

      assert {:network_verified, _, _} = result
    end

    test "returns unverified when all providers skip" do
      result = Router.verify(@base_context, providers: [MockSkipProvider])
      assert {:unverified, :none, %{}} = result
    end

    test "halts on untrusted provider (does not fall through to weaker providers)" do
      result =
        Router.verify(@base_context,
          providers: [MockUntrustedProvider, MockTrustedProvider]
        )

      # Untrusted halts — does NOT continue to the trusted provider
      assert {:unverified, :none, %{rejected_by: _, reason: :test_reason}} = result
    end

    test "returns unverified with rejection info when provider rejects" do
      result =
        Router.verify(@base_context,
          providers: [MockUntrustedProvider, MockSkipProvider]
        )

      assert {:unverified, :none, %{rejected_by: _, reason: :test_reason}} = result
    end

    test "skips provider that skips, then uses next trusted provider" do
      result =
        Router.verify(@base_context,
          providers: [MockSkipProvider, MockTrustedProvider]
        )

      assert {:network_verified, _, _} = result
    end
  end
end
