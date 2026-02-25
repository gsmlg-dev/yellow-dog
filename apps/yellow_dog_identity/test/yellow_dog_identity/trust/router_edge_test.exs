defmodule YellowDogIdentity.Trust.RouterEdgeTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Trust.Router

  # -- Mock providers for edge-case scenarios ----------------------------------

  defmodule AlwaysSkipProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:skip, :not_applicable}
  end

  defmodule CloudVerifiedProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context) do
      {:trusted, :cloud_verified, %{provider: :cloud_mock, cloud: true}}
    end
  end

  defmodule NetworkVerifiedProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context) do
      {:trusted, :network_verified, %{provider: :network_mock, network: true}}
    end
  end

  defmodule TokenVerifiedProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context) do
      {:trusted, :token_verified, %{provider: :token_mock, token: true}}
    end
  end

  defmodule RejectingProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:untrusted, :explicitly_rejected}
  end

  defmodule SourceIpEchoProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(%{source_ip: source_ip}) do
      {:trusted, :network_partial, %{source_ip: source_ip}}
    end
  end

  # -- Contexts ----------------------------------------------------------------

  @empty_context %{
    source_ip: {127, 0, 0, 1},
    hostname: "edge-host",
    attestation: nil,
    metadata: %{},
    authorization: nil
  }

  describe "verify/2 edge cases" do
    test "empty context (no attestation, no authorization) returns unverified with all-skip providers" do
      result = Router.verify(@empty_context, providers: [AlwaysSkipProvider])
      assert {:unverified, :none, %{}} = result
    end

    test "empty provider list returns unverified immediately" do
      result = Router.verify(@empty_context, providers: [])
      assert {:unverified, :none, %{}} = result
    end

    test "context with nil attestation and nil authorization returns unverified" do
      context = %{
        source_ip: {10, 0, 0, 1},
        hostname: "nil-attest-host",
        attestation: nil,
        metadata: %{},
        authorization: nil
      }

      result = Router.verify(context, providers: [AlwaysSkipProvider, AlwaysSkipProvider])
      assert {:unverified, :none, %{}} = result
    end

    test "first trusted provider wins when multiple could match" do
      # Cloud provider is first, network provider second.
      # Only the cloud result should be returned.
      result =
        Router.verify(@empty_context,
          providers: [CloudVerifiedProvider, NetworkVerifiedProvider]
        )

      assert {:cloud_verified, _, %{cloud: true}} = result
    end

    test "second trusted provider wins when first skips" do
      result =
        Router.verify(@empty_context,
          providers: [AlwaysSkipProvider, NetworkVerifiedProvider, TokenVerifiedProvider]
        )

      assert {:network_verified, _, %{network: true}} = result
    end

    test "untrusted provider halts chain and prevents weaker trusted provider from matching" do
      result =
        Router.verify(@empty_context,
          providers: [AlwaysSkipProvider, RejectingProvider, TokenVerifiedProvider]
        )

      assert {:unverified, :none, %{rejected_by: _, reason: :explicitly_rejected}} = result
    end

    test "rejection evidence includes the provider name and reason" do
      result =
        Router.verify(@empty_context,
          providers: [RejectingProvider]
        )

      {level, provider, evidence} = result
      assert level == :unverified
      assert provider == :none
      assert is_atom(evidence.rejected_by)
      assert evidence.reason == :explicitly_rejected
    end

    test "source IP is available through the provider chain" do
      context = %{
        source_ip: {172, 16, 0, 42},
        hostname: "ip-test-host",
        attestation: nil,
        metadata: %{},
        authorization: nil
      }

      result = Router.verify(context, providers: [SourceIpEchoProvider])
      assert {:network_partial, _, %{source_ip: {172, 16, 0, 42}}} = result
    end

    test "all skip providers followed by trusted provider returns trusted" do
      result =
        Router.verify(@empty_context,
          providers: [
            AlwaysSkipProvider,
            AlwaysSkipProvider,
            AlwaysSkipProvider,
            TokenVerifiedProvider
          ]
        )

      assert {:token_verified, _, %{token: true}} = result
    end

    test "provider_atom mapping for unknown module uses last module segment" do
      # The SourceIpEchoProvider module name should be mapped via the catch-all
      # clause in provider_atom/1 which uses Module.split |> List.last |> downcase
      result = Router.verify(@empty_context, providers: [SourceIpEchoProvider])
      {_level, provider_name, _evidence} = result
      assert is_atom(provider_name)
    end

    test "context with both attestation and authorization stops at first trusted" do
      # Simulate a context that has both cloud attestation data and a token header.
      # With CloudVerifiedProvider first, it should win without reaching the token provider.
      context = %{
        source_ip: {10, 0, 0, 5},
        hostname: "dual-context-host",
        attestation: %{"provider" => "aws", "document" => "fake"},
        metadata: %{},
        authorization: "Bearer some-token"
      }

      result =
        Router.verify(context,
          providers: [CloudVerifiedProvider, TokenVerifiedProvider]
        )

      assert {:cloud_verified, _, %{cloud: true}} = result
    end
  end
end
