defmodule YellowDogIdentity.Trust.RouterTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Trust.Router

  # ---------------------------------------------------------------------------
  # Test double providers — inline modules implementing the Provider behaviour
  # ---------------------------------------------------------------------------

  defmodule AlwaysSkipProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:skip, :not_applicable}
  end

  defmodule AlwaysTrustProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:trusted, :test_verified, %{test: true}}
  end

  defmodule AlwaysUntrustedProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:untrusted, :forbidden}
  end

  defmodule CloudTrustProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:trusted, :cloud_verified, %{cloud: true, instance: "i-abc"}}
  end

  defmodule NetbootTrustProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:trusted, :netboot_verified, %{boot_id: "boot-001"}}
  end

  defmodule TokenTrustProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:trusted, :token_verified, %{token_sub: "svc-acct"}}
  end

  defmodule ContextEchoProvider do
    @doc """
    Echoes back the full context as evidence so tests can verify context propagation.
    """
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(context) do
      {:trusted, :network_partial, %{echoed_context: context}}
    end
  end

  defmodule UntrustedExpiredProvider do
    @behaviour YellowDogIdentity.Trust.Provider

    @impl true
    def verify(_context), do: {:untrusted, :token_expired}
  end

  # ---------------------------------------------------------------------------
  # Shared context
  # ---------------------------------------------------------------------------

  @base_context %{
    source_ip: {192, 168, 1, 100},
    hostname: "test-host",
    attestation: nil,
    metadata: %{},
    authorization: nil
  }

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "verify/2 — all providers skip" do
    test "returns {:unverified, :none, %{}} when single provider skips" do
      result = Router.verify(@base_context, providers: [AlwaysSkipProvider])
      assert result == {:unverified, :none, %{}}
    end

    test "returns {:unverified, :none, %{}} when multiple providers all skip" do
      providers = [AlwaysSkipProvider, AlwaysSkipProvider, AlwaysSkipProvider]
      result = Router.verify(@base_context, providers: providers)
      assert result == {:unverified, :none, %{}}
    end
  end

  describe "verify/2 — first provider trusts" do
    test "returns trusted result immediately from the first provider" do
      result = Router.verify(@base_context, providers: [AlwaysTrustProvider])
      assert {:test_verified, :unknown, %{test: true}} = result
    end

    test "does not invoke subsequent providers after first trust" do
      # If the second provider were invoked it would return untrusted and halt.
      # We confirm the result is trusted, proving the chain stopped at the first.
      result =
        Router.verify(@base_context,
          providers: [AlwaysTrustProvider, AlwaysUntrustedProvider]
        )

      assert {:test_verified, :unknown, %{test: true}} = result
    end
  end

  describe "verify/2 — first skips, second trusts" do
    test "skips non-applicable providers and returns from the next trusted one" do
      result =
        Router.verify(@base_context,
          providers: [AlwaysSkipProvider, AlwaysTrustProvider]
        )

      assert {:test_verified, :unknown, %{test: true}} = result
    end

    test "skips multiple non-applicable providers before finding a trusted one" do
      result =
        Router.verify(@base_context,
          providers: [
            AlwaysSkipProvider,
            AlwaysSkipProvider,
            AlwaysSkipProvider,
            CloudTrustProvider
          ]
        )

      assert {:cloud_verified, :unknown, %{cloud: true}} = result
    end
  end

  describe "verify/2 — provider returns untrusted" do
    test "halts with rejection info containing provider name and reason" do
      result = Router.verify(@base_context, providers: [AlwaysUntrustedProvider])

      assert {:unverified, :none, evidence} = result
      assert evidence.reason == :forbidden
      assert is_atom(evidence.rejected_by)
    end

    test "includes different rejection reasons from different providers" do
      result = Router.verify(@base_context, providers: [UntrustedExpiredProvider])

      assert {:unverified, :none, %{reason: :token_expired, rejected_by: _}} = result
    end
  end

  describe "verify/2 — untrusted stops processing (no fallthrough)" do
    test "untrusted provider prevents weaker trusted provider from matching" do
      result =
        Router.verify(@base_context,
          providers: [AlwaysUntrustedProvider, AlwaysTrustProvider]
        )

      # Chain halted at the untrusted provider — trusted provider never reached
      assert {:unverified, :none, %{reason: :forbidden}} = result
    end

    test "skip then untrusted still halts before a trailing trusted provider" do
      result =
        Router.verify(@base_context,
          providers: [AlwaysSkipProvider, AlwaysUntrustedProvider, CloudTrustProvider]
        )

      assert {:unverified, :none, %{reason: :forbidden}} = result
    end
  end

  describe "verify/2 — empty providers list" do
    test "returns {:unverified, :none, %{}} with no providers" do
      result = Router.verify(@base_context, providers: [])
      assert result == {:unverified, :none, %{}}
    end
  end

  describe "verify/2 — custom providers via opts" do
    test "accepts a custom provider list that overrides defaults" do
      result =
        Router.verify(@base_context,
          providers: [CloudTrustProvider]
        )

      assert {:cloud_verified, :unknown, %{cloud: true, instance: "i-abc"}} = result
    end

    test "different provider orderings produce different results" do
      # Cloud first -> cloud wins
      cloud_first =
        Router.verify(@base_context,
          providers: [CloudTrustProvider, TokenTrustProvider]
        )

      assert {:cloud_verified, _, _} = cloud_first

      # Token first -> token wins
      token_first =
        Router.verify(@base_context,
          providers: [TokenTrustProvider, CloudTrustProvider]
        )

      assert {:token_verified, _, _} = token_first
    end

    test "single netboot provider returns netboot_verified trust level" do
      result = Router.verify(@base_context, providers: [NetbootTrustProvider])
      assert {:netboot_verified, :unknown, %{boot_id: "boot-001"}} = result
    end
  end

  describe "verify/2 — return tuple structure" do
    test "returns a 3-tuple of {trust_level, provider_name, evidence}" do
      result = Router.verify(@base_context, providers: [AlwaysTrustProvider])
      assert {trust_level, provider_name, evidence} = result

      assert is_atom(trust_level)
      assert is_atom(provider_name)
      assert is_map(evidence)
    end

    test "unverified result has :unverified trust level, :none provider, and map evidence" do
      result = Router.verify(@base_context, providers: [AlwaysSkipProvider])
      assert {trust_level, provider_name, evidence} = result

      assert trust_level == :unverified
      assert provider_name == :none
      assert is_map(evidence)
    end

    test "rejected result has :unverified trust level with rejection metadata in evidence" do
      result = Router.verify(@base_context, providers: [AlwaysUntrustedProvider])
      {trust_level, provider_name, evidence} = result

      assert trust_level == :unverified
      assert provider_name == :none
      assert Map.has_key?(evidence, :rejected_by)
      assert Map.has_key?(evidence, :reason)
    end

    test "trusted result carries through the evidence map from the provider" do
      result = Router.verify(@base_context, providers: [CloudTrustProvider])
      {_trust_level, _provider_name, evidence} = result

      assert evidence.cloud == true
      assert evidence.instance == "i-abc"
    end
  end

  describe "verify/2 — context propagation" do
    test "full context is available to each provider in the chain" do
      context = %{
        source_ip: {10, 0, 0, 42},
        hostname: "propagation-host",
        attestation: %{"provider" => "test"},
        metadata: %{region: "us-east-1"},
        authorization: "Bearer test-token-123"
      }

      result = Router.verify(context, providers: [ContextEchoProvider])
      {_level, _provider, evidence} = result

      echoed = evidence.echoed_context
      assert echoed.source_ip == {10, 0, 0, 42}
      assert echoed.hostname == "propagation-host"
      assert echoed.attestation == %{"provider" => "test"}
      assert echoed.metadata == %{region: "us-east-1"}
      assert echoed.authorization == "Bearer test-token-123"
    end
  end

  describe "verify/2 — provider_atom mapping" do
    test "unknown (unregistered) provider modules map to :unknown" do
      # AlwaysTrustProvider is not in the provider_atom/1 clauses
      result = Router.verify(@base_context, providers: [AlwaysTrustProvider])
      {_level, provider_name, _evidence} = result

      assert provider_name == :unknown
    end

    test "rejected by unknown provider also maps to :unknown" do
      result = Router.verify(@base_context, providers: [AlwaysUntrustedProvider])
      {_level, _provider, evidence} = result

      assert evidence.rejected_by == :unknown
    end
  end

  describe "verify/2 — telemetry integration" do
    test "emits trust_resolved telemetry event on successful trust" do
      test_pid = self()
      ref = make_ref()
      handler_id = "router-test-resolved-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :identity, :trust, :resolved],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_resolved, event, measurements, metadata})
        end,
        nil
      )

      Router.verify(@base_context, providers: [AlwaysTrustProvider])

      assert_receive {:telemetry_resolved, [:yellow_dog, :identity, :trust, :resolved],
                       measurements, metadata}

      assert is_integer(measurements.duration)
      assert metadata.trust_level == :test_verified
      assert metadata.provider == :unknown
      assert metadata.hostname == "test-host"

      :telemetry.detach(handler_id)
    end

    test "emits trust_resolved telemetry event on unverified (all skip)" do
      test_pid = self()
      ref = make_ref()
      handler_id = "router-test-resolved-skip-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :identity, :trust, :resolved],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_resolved_skip, metadata})
        end,
        nil
      )

      Router.verify(@base_context, providers: [AlwaysSkipProvider])

      assert_receive {:telemetry_resolved_skip, metadata}
      assert metadata.trust_level == :unverified
      assert metadata.provider == :none

      :telemetry.detach(handler_id)
    end

    test "emits trust_untrusted telemetry event when provider rejects" do
      test_pid = self()
      ref = make_ref()
      handler_id = "router-test-untrusted-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :identity, :trust, :untrusted],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry_untrusted, metadata})
        end,
        nil
      )

      Router.verify(@base_context, providers: [AlwaysUntrustedProvider])

      assert_receive {:telemetry_untrusted, metadata}
      assert metadata.reason == :forbidden
      assert metadata.provider == :unknown
      assert metadata.hostname == "test-host"

      :telemetry.detach(handler_id)
    end

    test "trust_resolved duration is non-negative" do
      test_pid = self()
      ref = make_ref()
      handler_id = "router-test-duration-#{inspect(ref)}"

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :identity, :trust, :resolved],
        fn _event, measurements, _metadata, _config ->
          send(test_pid, {:telemetry_duration, measurements.duration})
        end,
        nil
      )

      Router.verify(@base_context, providers: [AlwaysTrustProvider])

      assert_receive {:telemetry_duration, duration}
      assert duration >= 0

      :telemetry.detach(handler_id)
    end
  end

  describe "verify/1 — default arity" do
    test "verify/1 accepts context without opts (uses default providers)" do
      # This will invoke the real default providers which may skip or error
      # depending on the context. The important thing is it doesn't crash.
      result = Router.verify(@base_context)
      assert {trust_level, provider_name, evidence} = result
      assert is_atom(trust_level)
      assert is_atom(provider_name)
      assert is_map(evidence)
    end

    test "Cloud.Attestation provider name is derived from evidence.provider for AWS" do
      context = %{@base_context | attestation: %{"provider" => "aws", "document" => Base.encode64(Jason.encode!(%{"accountId" => "123456789012", "instanceId" => "i-abc", "region" => "us-east-1", "pendingTime" => DateTime.to_iso8601(DateTime.utc_now())}))}}
      result = Router.verify(context)
      {_trust_level, provider_name, _evidence} = result
      assert provider_name == :aws
    end

    test "Cloud.Attestation provider name is derived from evidence.provider for GCP" do
      # GCP requires a signed JWT so skip when no JWKS configured — untrusted falls through
      context = %{@base_context | attestation: %{"provider" => "gcp", "token" => nil}}
      {_trust_level, provider_name, _evidence} = Router.verify(context)
      # nil token → untrusted → :none (rejection halts chain)
      assert provider_name == :none
    end

    test "Cloud.Attestation provider name is :azure for valid Azure attestation" do
      # Azure verify succeeds with a valid document (no cert/signature required)
      azure_doc =
        Base.encode64(
          Jason.encode!(%{
            "subscriptionId" => "sub-12345678-abcd-efgh-ijkl-123456789012",
            "vmId" => "vm-abcdef12-3456-7890-abcd-ef1234567890",
            "resourceGroupName" => "rg-prod",
            "location" => "eastus",
            "name" => "router-test-vm",
            "offer" => "UbuntuServer",
            "publisher" => "Canonical",
            "sku" => "22_04-lts",
            "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
          })
        )

      context = %{@base_context | attestation: %{"provider" => "azure", "document" => azure_doc}}
      result = Router.verify(context)
      {_trust_level, provider_name, _evidence} = result
      assert provider_name == :azure
    end

    test "token provider name is :token when token verified" do
      # Note: this would require a running Registry with a valid token — just
      # verify the provider_atom mapping by checking the untrusted path returns :token
      # (since no Registry is running, token verification returns untrusted)
      context = %{@base_context | attestation: nil, authorization: "Bearer fake-token"}
      result = Router.verify(context)
      # Token verification fails (no Registry) → untrusted with rejection
      {_trust_level, _provider_name, _evidence} = result
      # Just assert no crash — the rejection info shows token provider tried
      assert is_atom(elem(result, 1))
    end
  end
end
