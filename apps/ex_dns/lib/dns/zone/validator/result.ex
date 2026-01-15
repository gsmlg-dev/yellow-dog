defmodule DNS.Zone.Validator.Result do
  @moduledoc """
  Represents the result of zone validation.

  Contains both errors (blocking issues) and warnings (non-blocking issues).
  A zone is considered valid if there are no errors, even if warnings exist.

  ## Examples

      iex> result = Result.new()
      iex> result = Result.add_error(result, :missing_soa, "Zone must have SOA")
      iex> Result.valid?(result)
      false

      iex> result = Result.new()
      iex> result = Result.add_warning(result, :single_ns, "Only 1 NS record")
      iex> Result.valid?(result)
      true
  """

  @type error :: %{
          code: atom(),
          message: String.t(),
          field: atom() | nil,
          name: String.t() | nil
        }

  @type t :: %__MODULE__{
          errors: [error()],
          warnings: [error()],
          valid?: boolean()
        }

  defstruct errors: [], warnings: [], valid?: true

  @doc """
  Create a new empty validation result.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Add an error to the result. Errors make the zone invalid.
  """
  @spec add_error(t(), atom(), String.t(), keyword()) :: t()
  def add_error(%__MODULE__{} = result, code, message, opts \\ []) do
    error = %{
      code: code,
      message: message,
      field: Keyword.get(opts, :field),
      name: Keyword.get(opts, :name)
    }

    %{result | errors: [error | result.errors], valid?: false}
  end

  @doc """
  Add a warning to the result. Warnings don't make the zone invalid.
  """
  @spec add_warning(t(), atom(), String.t(), keyword()) :: t()
  def add_warning(%__MODULE__{} = result, code, message, opts \\ []) do
    warning = %{
      code: code,
      message: message,
      field: Keyword.get(opts, :field),
      name: Keyword.get(opts, :name)
    }

    %{result | warnings: [warning | result.warnings]}
  end

  @doc """
  Check if the validation result indicates a valid zone.
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{valid?: valid}), do: valid

  @doc """
  Get all errors from the result.
  """
  @spec errors(t()) :: [error()]
  def errors(%__MODULE__{errors: errors}), do: Enum.reverse(errors)

  @doc """
  Get all warnings from the result.
  """
  @spec warnings(t()) :: [error()]
  def warnings(%__MODULE__{warnings: warnings}), do: Enum.reverse(warnings)

  @doc """
  Convert result to a simple tuple for pattern matching.
  """
  @spec to_tuple(t()) :: {:ok, t()} | {:error, t()}
  def to_tuple(%__MODULE__{valid?: true} = result), do: {:ok, result}
  def to_tuple(%__MODULE__{valid?: false} = result), do: {:error, result}

  @doc """
  Merge two validation results.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = r1, %__MODULE__{} = r2) do
    %__MODULE__{
      errors: r2.errors ++ r1.errors,
      warnings: r2.warnings ++ r1.warnings,
      valid?: r1.valid? and r2.valid?
    }
  end
end
