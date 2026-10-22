defmodule YellowDog.Management.Caller do
  @moduledoc "Verified identity and authorization lifetime; never contains credentials."
  @enforce_keys [
    :issuer,
    :subject,
    :scopes,
    :source,
    :correlation_id,
    :expires_at,
    :policy_revision,
    :authentication
  ]
  defstruct [
    :issuer,
    :subject,
    :client_id,
    :scopes,
    :source,
    :correlation_id,
    :expires_at,
    :policy_revision,
    :authentication
  ]

  def actor(%__MODULE__{} = caller), do: "principal:" <> hash(identity(caller))

  def request_key(%__MODULE__{} = caller, key) when is_binary(key) and byte_size(key) in 1..128,
    do: {:ok, "r1:" <> hash(["management-request-v1" | identity(caller)] ++ [key])}

  def request_key(_, _),
    do:
      {:error,
       %{code: "invalid_request", message: "Logical request key must contain 1..128 bytes"}}

  def audit_context(caller) do
    %{
      "issuer" => caller.issuer,
      "subject" => caller.subject,
      "client_id" => caller.client_id,
      "source" => to_string(caller.source),
      "correlation_id" => caller.correlation_id,
      "authentication" => to_string(caller.authentication)
    }
  end

  def session(caller),
    do: Map.from_struct(caller) |> Map.new(fn {key, value} -> {to_string(key), value} end)

  def from_session(
        %{
          "issuer" => issuer,
          "subject" => subject,
          "scopes" => scopes,
          "expires_at" => expires_at,
          "policy_revision" => policy,
          "authentication" => auth
        } = data
      )
      when is_binary(issuer) and is_binary(subject) and is_list(scopes) and is_integer(expires_at) do
    authentication =
      case auth do
        :gateway -> :gateway
        "gateway" -> :gateway
        :trusted_local -> :trusted_local
        "trusted_local" -> :trusted_local
        _ -> :invalid
      end

    {:ok,
     %__MODULE__{
       issuer: issuer,
       subject: subject,
       client_id: data["client_id"],
       scopes: scopes,
       source: :ui,
       correlation_id: Ecto.UUID.generate(),
       expires_at: expires_at,
       policy_revision: policy,
       authentication: authentication
     }}
  end

  def from_session(_),
    do: {:error, %{code: "authentication_required", message: "Verified UI session required"}}

  def same_identity?(a, b), do: identity(a) == identity(b)
  defp identity(caller), do: [caller.issuer, caller.subject, caller.client_id]

  defp hash(value),
    do: :crypto.hash(:sha256, Jason.encode!(value)) |> Base.url_encode64(padding: false)
end
