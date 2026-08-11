defmodule YellowDog.ServerAgent.BootConfig do
  @moduledoc """
  Selects the last acknowledged managed revision before Server-agent processes start.
  """

  alias YellowDog.ServerAgent.ConfigApplyStore

  @type result :: {:ok, String.t()} | :no_managed_config | {:error, :corrupt | :invalid_options}

  @spec select(Path.t(), term()) :: result()
  def select(data_dir, server_id) do
    case ConfigApplyStore.read_boot_state(data_dir, server_id) do
      {:ok, %{known_good: %{revision: revision}}} -> {:ok, revision}
      {:ok, %{known_good: nil}} -> :no_managed_config
      {:error, :missing} -> :no_managed_config
      {:error, reason} when reason in [:corrupt, :invalid_options] -> {:error, reason}
      _invalid -> {:error, :corrupt}
    end
  end
end
