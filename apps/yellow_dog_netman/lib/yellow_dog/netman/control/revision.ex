defmodule YellowDog.Netman.Control.Revision do
  @moduledoc false

  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @type policy :: :create | :mutation
  @type current :: String.t() | :missing

  @spec check(String.t() | nil, current(), policy()) :: :ok | {:error, Error.t()}
  def check(nil, :missing, :create), do: :ok
  def check(_expected_revision, :missing, _policy), do: not_found_error()

  def check(nil, current_revision, :mutation) do
    with {:ok, _current_revision} <- validate_current(current_revision) do
      {:error,
       Error.new(:invalid, "expected revision required", %{"field" => "expected_revision"})}
    end
  end

  def check(nil, current_revision, :create) do
    with {:ok, current_revision} <- validate_current(current_revision) do
      {:error,
       Error.new(:conflict, "resource already exists", %{"current_revision" => current_revision})}
    end
  end

  def check(expected_revision, current_revision, policy)
      when policy in [:create, :mutation] do
    with {:ok, current_revision} <- validate_current(current_revision),
         {:ok, expected_revision} <- Digest.validate(expected_revision) do
      if expected_revision == current_revision do
        :ok
      else
        {:error,
         Error.new(:conflict, "stale revision", %{
           "expected_revision" => expected_revision,
           "current_revision" => current_revision
         })}
      end
    end
  end

  def check(_expected_revision, _current, _policy), do: invalid_error()

  defp validate_current(current_revision) do
    case Digest.validate(current_revision) do
      {:ok, revision} -> {:ok, revision}
      _error -> internal_error()
    end
  end

  defp not_found_error, do: {:error, Error.new(:not_found, "resource not found", %{})}
  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
