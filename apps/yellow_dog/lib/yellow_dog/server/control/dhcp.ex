defmodule YellowDog.Server.Control.Dhcp do
  @moduledoc false

  alias YellowDog.Sync.Error

  @production_adapters %{
    "ipv4" => Module.concat(["YellowDog", "Server", "Control", "Dhcpv4"]),
    "ipv6" => Module.concat(["YellowDog", "Server", "Control", "Dhcpv6"])
  }
  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch(operation, payload) do
    with {:ok, adapter} <- adapter_for(payload, :dispatch) do
      apply(adapter, :dispatch, [operation, payload])
    end
  end

  @spec current(String.t(), map()) :: {:ok, map() | :missing} | {:error, Error.t()}
  def current(operation, payload) do
    with {:ok, adapter} <- adapter_for(payload, :current) do
      apply(adapter, :current, [operation, payload])
    end
  end

  defp adapter_for(payload, function) do
    with {:ok, family} <- family(payload),
         {:ok, adapters} <- adapters() do
      case Map.fetch(adapters, family) do
        {:ok, adapter} ->
          if adapter_available?(adapter, function), do: {:ok, adapter}, else: unsupported_error()

        :error ->
          internal_error()
      end
    end
  end

  defp family(%{"family" => family}) when family in ["ipv4", "ipv6"], do: {:ok, family}
  defp family(_payload), do: invalid_error()

  defp adapter_available?(adapter, function) do
    Code.ensure_loaded?(adapter) and function_exported?(adapter, function, 2)
  end

  if @test_environment do
    defp adapters do
      config = Application.get_env(:yellow_dog, __MODULE__, [])

      with true <- Keyword.keyword?(config),
           overrides when is_map(overrides) <- Keyword.get(config, :adapters, %{}),
           true <- valid_adapter_overrides?(overrides) do
        {:ok, Map.merge(@production_adapters, overrides)}
      else
        _ -> internal_error()
      end
    end

    defp valid_adapter_overrides?(overrides) do
      Enum.all?(overrides, fn {family, adapter} ->
        Map.has_key?(@production_adapters, family) and is_atom(adapter) and not is_nil(adapter)
      end)
    end
  else
    defp adapters, do: {:ok, @production_adapters}
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
  defp unsupported_error, do: {:error, Error.new(:unsupported, "unsupported operation", %{})}
  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
