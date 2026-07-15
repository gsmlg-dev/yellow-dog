defmodule YellowDog.Sync.Error do
  alias YellowDog.Sync.Bounds

  @codes [
    :not_connected,
    :not_found,
    :invalid,
    :conflict,
    :unsupported,
    :timeout,
    :apply_failed,
    :rollback_failed,
    :internal
  ]

  @type code ::
          :not_connected
          | :not_found
          | :invalid
          | :conflict
          | :unsupported
          | :timeout
          | :apply_failed
          | :rollback_failed
          | :internal

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          details: map()
        }

  @enforce_keys [:code, :message]
  defstruct [:code, :message, details: %{}]

  @spec new(code() | atom(), String.t(), map()) :: t() | {:error, t()}
  def new(code, message, details \\ %{})

  def new(code, message, details) when code in @codes do
    with {:ok, message} <- Bounds.message(message),
         {:ok, details} <- Bounds.map(details) do
      %__MODULE__{code: code, message: message, details: details}
    end
  end

  def new(_code, _message, _details), do: invalid_error()

  @spec from_wire(map()) :: {:ok, t()} | {:error, t()}
  def from_wire(%{"code" => code} = wire) when is_binary(code) do
    with {:ok, code} <- decode_code(code),
         {:ok, message} <- Bounds.message(Map.get(wire, "message", "")),
         {:ok, details} <- Bounds.details(Map.get(wire, "details", %{})) do
      {:ok, %__MODULE__{code: code, message: message, details: details}}
    end
  end

  def from_wire(_wire), do: invalid_error()

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{code: code, message: message, details: details}) do
    %{
      "code" => encode_code(code),
      "message" => message,
      "details" => details
    }
  end

  for code <- @codes do
    wire_code = Atom.to_string(code)

    defp decode_code(unquote(wire_code)), do: {:ok, unquote(code)}
    defp encode_code(unquote(code)), do: unquote(wire_code)
  end

  defp decode_code(_code), do: invalid_error()

  defp invalid_error,
    do: {:error, %__MODULE__{code: :invalid, message: "invalid value", details: %{}}}
end
