defmodule DNS.Result do
  @moduledoc """
  Standardized result types for DNS operations.

  This module provides consistent error handling patterns throughout the DNS library,
  replacing the mix of throw/1 and {:error, reason} tuples with a unified approach.
  """

  @type t(a) :: {:ok, a} | {:error, DNS.Error.t()}

  @doc """
  Wrap a successful result in the standard format.
  """
  @spec ok(any()) :: t(any())
  def ok(value), do: {:ok, value}

  @doc """
  Create a standardized error result.
  """
  @spec error(DNS.Error.error_type(), module(), term(), map()) :: t(any())
  def error(type, module, reason, context \\ %{}) do
    {:error, DNS.Error.new(type, module, reason, context)}
  end

  @doc """
  Map over a successful result, leaving errors unchanged.
  """
  @spec map(t(a), (a -> b)) :: t(b) when a: any(), b: any()
  def map({:ok, value}, fun), do: {:ok, fun.(value)}
  def map({:error, _error} = result, _fun), do: result

  @doc """
  Chain operations that return results.
  """
  @spec flat_map(t(a), (a -> t(b))) :: t(b) when a: any(), b: any()
  def flat_map({:ok, value}, fun), do: fun.(value)
  def flat_map({:error, _error} = result, _fun), do: result

  @doc """
  Execute a function with a value, catching throws and converting to errors.
  """
  @spec catch_throw((-> a)) :: t(a) when a: any()
  def catch_throw(fun) do
    try do
      {:ok, fun.()}
    rescue
      RuntimeError ->
        # Convert runtime errors to standardized errors
        {:error, "DNS operation failed"}
    catch
      :throw, reason ->
        # Handle legacy throw patterns
        case reason do
          {error_type, module, details} when is_atom(error_type) and is_atom(module) ->
            {:error, DNS.Error.new(error_type, module, details)}

          {message, _details} when is_binary(message) ->
            {:error, message}

          _other ->
            {:error, "DNS operation failed"}
        end
    end
  end

  @doc """
  Convert legacy throw-based functions to result-based functions.
  """
  defmacro __using__(_opts) do
    quote do
      import DNS.Result, only: [result: 1]
    end
  end

  @doc """
  Macro to wrap throw-based functions with result handling.
  """
  defmacro result(do: block) do
    quote do
      DNS.Result.catch_throw(fn -> unquote(block) end)
    end
  end

  @doc """
  Extract the value from a result or return a default.
  """
  @spec unwrap(t(a), a) :: a when a: any()
  def unwrap({:ok, value}, _default), do: value
  def unwrap({:error, _}, default), do: default

  @doc """
  Get the error from a result or nil if successful.
  """
  @spec error(t(any())) :: DNS.Error.t() | nil
  def error({:ok, _}), do: nil
  def error({:error, error}), do: error
end
