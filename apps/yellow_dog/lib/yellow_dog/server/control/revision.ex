defmodule YellowDog.Server.Control.Revision do
  @moduledoc false

  alias YellowDog.Server.Control.Result
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @unstable_keys [
    "local_metadata",
    "observation_time",
    "observation_timestamp",
    "observed_at",
    "revision"
  ]

  @type policy :: :query | :create | :mutation

  @spec calculate(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def calculate(resource) do
    with stable <- stable_content(resource),
         {:ok, normalized} <- Result.normalize(stable) do
      Digest.calculate(normalized)
    end
  end

  @spec check(String.t() | nil, term() | :missing, policy()) ::
          :ok | {:error, Error.t()}
  def check(nil, _current, :query), do: :ok
  def check(nil, :missing, :create), do: :ok

  def check(_expected_revision, :missing, policy) when policy in [:query, :create, :mutation],
    do: not_found_error()

  def check(nil, current, :mutation) do
    with {:ok, _current_revision} <- calculate(current) do
      {:error,
       Error.new(:invalid, "expected revision required", %{
         "field" => "expected_revision"
       })}
    end
  end

  def check(nil, current, :create) do
    with {:ok, current_revision} <- calculate(current) do
      {:error,
       Error.new(:conflict, "resource already exists", %{
         "current_revision" => current_revision
       })}
    end
  end

  def check(expected_revision, current, policy) when policy in [:query, :create, :mutation] do
    with {:ok, expected_revision} <- Digest.validate(expected_revision),
         {:ok, current_revision} <- calculate(current) do
      if expected_revision == current_revision do
        :ok
      else
        stale_error(expected_revision, current_revision)
      end
    end
  end

  def check(_expected_revision, _current, _policy), do: invalid_error()

  defp stable_content(value) when is_struct(value), do: value

  defp stable_content(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, stable_content(nested)} end)
    |> Enum.reject(fn {key, _nested} -> unstable_key?(key) end)
    |> Map.new()
  end

  defp stable_content(value) when is_list(value), do: Enum.map(value, &stable_content/1)
  defp stable_content(value), do: value

  defp unstable_key?(key) when is_atom(key), do: key |> Atom.to_string() |> unstable_key?()
  defp unstable_key?(key) when is_binary(key), do: key in @unstable_keys
  defp unstable_key?(_key), do: false

  defp stale_error(expected_revision, current_revision) do
    {:error,
     Error.new(:conflict, "stale revision", %{
       "expected_revision" => expected_revision,
       "current_revision" => current_revision
     })}
  end

  defp not_found_error do
    {:error, Error.new(:not_found, "resource not found", %{})}
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
