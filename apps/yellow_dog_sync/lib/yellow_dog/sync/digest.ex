defmodule YellowDog.Sync.Digest do
  @moduledoc false

  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Error

  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @spec calculate(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def calculate(value) do
    with {:ok, encoded} <- Codec.encode(value) do
      {:ok, :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)}
    end
  end

  @spec verify(term(), term()) :: :ok | {:error, Error.t()}
  def verify(value, digest) do
    with {:ok, digest} <- validate(digest),
         {:ok, calculated} <- calculate(value),
         true <- calculated == digest do
      :ok
    else
      _ -> invalid_error()
    end
  end

  @spec validate(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate(digest) when is_binary(digest) do
    if String.match?(digest, @digest_pattern), do: {:ok, digest}, else: invalid_error()
  end

  def validate(_digest), do: invalid_error()

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
