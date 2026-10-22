defmodule YellowDog.Management.Database do
  @moduledoc false

  # These are availability failures, not malformed queries or programming errors.
  @availability ~w(connection_exception connection_does_not_exist connection_failure sqlclient_unable_to_establish_sqlconnection sqlserver_rejected_establishment_of_sqlconnection transaction_resolution_unknown admin_shutdown crash_shutdown cannot_connect_now too_many_connections query_canceled lock_not_available)a
  # PostgreSQL JSON rejects NUL in an otherwise valid, rejected user request receipt.
  @constraints ~w(untranslatable_character not_null_violation foreign_key_violation unique_violation check_violation exclusion_violation serialization_failure deadlock_detected)a

  def read(fun) do
    {:ok, fun.()}
  rescue
    _error in DBConnection.ConnectionError -> {:error, unavailable()}
    error in Postgrex.Error -> infrastructure_error(error, __STACKTRACE__, &unavailable/0)
  end

  # A transport failure may lose the commit acknowledgement. Never replay a secret issuance.
  def credential(fun, worker_id) do
    case fun.() do
      {:error, %{code: "database_unavailable"}} -> {:error, uncertain(worker_id)}
      result -> result
    end
  rescue
    _error in DBConnection.ConnectionError ->
      {:error, uncertain(worker_id)}

    error in Postgrex.Error ->
      cond do
        availability?(error) ->
          {:error, uncertain(worker_id)}

        constraint?(error) ->
          {:error,
           %{
             code: "database_constraint",
             message: "Database rejected the credential change; no credential was issued"
           }}

        true ->
          reraise(error, __STACKTRACE__)
      end
  end

  def availability?(%Postgrex.Error{postgres: %{code: code}}), do: code in @availability
  def availability?(_), do: false
  def constraint?(%Postgrex.Error{postgres: %{code: code}}), do: code in @constraints
  def constraint?(_), do: false

  defp infrastructure_error(error, stacktrace, outcome) do
    if availability?(error), do: {:error, outcome.()}, else: reraise(error, stacktrace)
  end

  defp unavailable do
    %{
      code: "database_unavailable",
      message:
        "Management could not read PostgreSQL. Showing last known observations; Worker connectivity is unconfirmed."
    }
  end

  defp uncertain(worker_id) do
    %{
      code: "credential_outcome_unknown",
      message:
        "Credential outcome is unknown. The operation may have committed, and the previous credential may no longer be valid. Issued tokens cannot be recovered. Check this Worker by its ID before explicitly resetting its token.",
      details: %{"worker_id" => worker_id}
    }
  end
end
