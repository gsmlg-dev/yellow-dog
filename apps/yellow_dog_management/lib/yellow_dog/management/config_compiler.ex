defmodule YellowDog.Management.ConfigCompiler do
  @moduledoc "Exports a committed DNS/Zone target without contacting a Worker; Views and IP artifacts are excluded."

  alias YellowDog.ConfigSpec
  alias YellowDog.Management.Domain

  def export_target(worker_id, revision \\ :latest) do
    with {:ok, target} <- Domain.get_target(worker_id, revision),
         {:ok, plan} <- ConfigSpec.normalize_plan(target["plan"]),
         {:ok, toml} <- ConfigSpec.encode(plan),
         {:ok, decoded} <- ConfigSpec.decode(toml),
         {:ok, expected_digest} <- ConfigSpec.plan_digest(plan),
         {:ok, actual_digest} <- ConfigSpec.plan_digest(decoded),
         :ok <- ensure_equal(plan, decoded, target["digest"], expected_digest, actual_digest) do
      {:ok, %{"target" => target, "toml" => toml, "plan" => decoded, "digest" => actual_digest}}
    else
      {:error, %{code: _} = error} ->
        {:error, error}

      {:error, details} ->
        {:error,
         %{
           code: "invalid_config",
           message: "Target export failed validation",
           details: %{"errors" => details}
         }}
    end
  end

  defp ensure_equal(plan, decoded, persisted_digest, expected_digest, actual_digest) do
    if plan == decoded and persisted_digest == expected_digest and
         expected_digest == actual_digest do
      :ok
    else
      {:error,
       %{
         code: "round_trip_mismatch",
         message: "Export changed the confirmed target",
         details: %{}
       }}
    end
  end
end
