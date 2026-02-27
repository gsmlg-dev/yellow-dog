defmodule YellowDog.Netman.SecretStore do
  @moduledoc """
  Stub secret store for Phase 1 (file-based backend).

  In future phases, this will handle WiFi passwords, 802.1X credentials, etc.
  """

  @spec get(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def get(_key), do: {:error, :not_found}

  @spec put(String.t(), String.t()) :: :ok
  def put(_key, _value), do: :ok

  @spec delete(String.t()) :: :ok
  def delete(_key), do: :ok
end
