defmodule YellowDogIdentity.Export do
  @moduledoc """
  Recipient export for approved host identities.

  Exports age recipients in YAML or sops format for integration
  with GitOps secret management workflows.
  """

  alias YellowDogIdentity.Registry

  @doc """
  Exports approved host age recipients as a YAML list.

  Returns:
      age:
        - age1hostA
        - age1hostB
  """
  @spec recipients_yaml() :: String.t()
  def recipients_yaml do
    start_time = System.monotonic_time()
    recipients = get_approved_recipients()
    yaml = manual_yaml_list("age", recipients)

    duration = System.monotonic_time() - start_time
    YellowDogIdentity.Telemetry.export_recipients(length(recipients), duration)

    yaml
  end

  @doc """
  Exports approved host age recipients in sops format.

  Returns:
      creation_rules:
        - age: >-
            age1hostA,
            age1hostB
  """
  @spec recipients_sops() :: String.t()
  def recipients_sops do
    start_time = System.monotonic_time()

    recipients = get_approved_recipients()

    sops =
      if recipients == [] do
        "creation_rules:\n  - age: \"\"\n"
      else
        joined = Enum.join(recipients, ",\n      ")
        "creation_rules:\n  - age: >-\n      #{joined}\n"
      end

    duration = System.monotonic_time() - start_time
    YellowDogIdentity.Telemetry.export_recipients(length(recipients), duration)

    sops
  end

  @doc """
  Returns the list of approved age recipients.
  """
  @spec get_approved_recipients() :: [String.t()]
  def get_approved_recipients do
    Registry.list_hosts_by_status(:approved)
    |> Enum.map(& &1.age_recipient)
    |> Enum.sort()
  end

  defp manual_yaml_list(key, items) do
    if items == [] do
      "#{key}: []\n"
    else
      lines = Enum.map_join(items, "\n", fn item -> "  - #{item}" end)
      "#{key}:\n#{lines}\n"
    end
  end
end
