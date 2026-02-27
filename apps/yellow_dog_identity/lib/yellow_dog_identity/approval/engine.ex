defmodule YellowDogIdentity.Approval.Engine do
  @moduledoc """
  Policy-driven approval engine.

  Evaluates approval policies in order against a registration context.
  First matching policy determines the action. Falls back to default action.
  """

  alias YellowDogIdentity.Approval.Policy
  alias YellowDogIdentity.Host

  @type approval_result :: %{
          action: Policy.action(),
          policy_name: String.t() | nil,
          auto: boolean()
        }

  @doc """
  Evaluates the approval policies against a host and trust result.

  Returns `{action, policy_name}` where action is `:approve`, `:reject`, or `:pending`.
  """
  @spec evaluate(Host.t(), map()) :: approval_result()
  def evaluate(%Host{} = host, trust_result \\ %{}) do
    policies = load_policies()
    default_action = get_default_action()

    context = build_context(host, trust_result)

    case find_matching_policy(policies, context) do
      %Policy{action: action, name: name} ->
        %{action: action, policy_name: name, auto: true}

      nil ->
        %{action: default_action, policy_name: nil, auto: false}
    end
  end

  @doc """
  Evaluates with explicitly provided policies (for testing).
  """
  @spec evaluate_with_policies(Host.t(), [Policy.t()], Policy.action(), map()) ::
          approval_result()
  def evaluate_with_policies(%Host{} = host, policies, default_action, trust_result \\ %{}) do
    context = build_context(host, trust_result)

    case find_matching_policy(policies, context) do
      %Policy{action: action, name: name} ->
        %{action: action, policy_name: name, auto: true}

      nil ->
        %{action: default_action, policy_name: nil, auto: false}
    end
  end

  @doc """
  Returns the loaded policies and default action for display in the UI.
  """
  @spec list_policies() :: %{policies: [Policy.t()], default_action: Policy.action()}
  def list_policies do
    %{policies: load_policies(), default_action: get_default_action()}
  end

  defp find_matching_policy(policies, context) do
    Enum.find(policies, fn policy -> Policy.matches?(policy, context) end)
  end

  defp build_context(%Host{} = host, trust_result) do
    %{
      "trust_level" => to_string(host.trust_level),
      "trust_provider" => to_string(host.trust_provider),
      "role" => host.role,
      "datacenter" => host.datacenter,
      "hostname" => host.hostname,
      "hostname_pattern" => host.hostname,
      "fingerprint_class" => get_in_evidence(host.trust_evidence, "fingerprint_class"),
      "mac_prefix" => get_mac_prefix(host.trust_evidence),
      "cloud_account" => get_cloud_account(host.trust_evidence),
      "cloud_region" => get_cloud_region(host.trust_evidence),
      "cloud_image" => get_cloud_image(host.trust_evidence)
    }
    |> Map.merge(trust_result)
  end

  defp get_in_evidence(evidence, key) when is_map(evidence) do
    Map.get(evidence, key) ||
      try do
        Map.get(evidence, String.to_existing_atom(key))
      rescue
        ArgumentError -> nil
      end
  end

  defp get_in_evidence(_, _), do: nil

  defp get_mac_prefix(evidence) when is_map(evidence) do
    mac = Map.get(evidence, "mac") || Map.get(evidence, :mac, "")
    if byte_size(to_string(mac)) >= 8, do: String.slice(to_string(mac), 0, 8), else: nil
  end

  defp get_mac_prefix(_), do: nil

  defp get_cloud_account(evidence) when is_map(evidence) do
    Map.get(evidence, "account_id") ||
      Map.get(evidence, :account_id) ||
      Map.get(evidence, "project_id") ||
      Map.get(evidence, :project_id) ||
      Map.get(evidence, "subscription_id") ||
      Map.get(evidence, :subscription_id)
  end

  defp get_cloud_account(_), do: nil

  defp get_cloud_region(evidence) when is_map(evidence) do
    Map.get(evidence, "region") ||
      Map.get(evidence, :region) ||
      Map.get(evidence, "zone") ||
      Map.get(evidence, :zone) ||
      Map.get(evidence, "location") ||
      Map.get(evidence, :location)
  end

  defp get_cloud_region(_), do: nil

  defp get_cloud_image(evidence) when is_map(evidence) do
    Map.get(evidence, "image_id") || Map.get(evidence, :image_id)
  end

  defp get_cloud_image(_), do: nil

  defp load_policies do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          policy_list = get_in(config, ["identity", "approval", "policies"]) || []
          Policy.from_config(policy_list)
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end
  end

  defp get_default_action do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          action_str = get_in(config, ["identity", "approval", "default_action"]) || "pending"

          case action_str do
            "approve" -> :approve
            "reject" -> :reject
            _ -> :pending
          end
        rescue
          _ -> :pending
        catch
          :exit, _ -> :pending
        end

      _ ->
        :pending
    end
  end
end
