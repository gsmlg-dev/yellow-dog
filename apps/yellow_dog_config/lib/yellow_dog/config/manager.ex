defmodule YellowDog.Config.Manager do
  @moduledoc """
  Stable Settings owner boundary for unsupported configuration operations.

  The current runtime cannot provide a crash-safe durable configuration
  lifecycle or losslessly project its configuration through the fixed Settings
  grammar. This module validates bounded owner inputs and returns typed errors
  without reading or mutating runtime state.
  """

  @max_service_bytes 128
  @max_key_bytes 128
  @max_text_bytes 1_024
  @max_entries 100
  @max_depth 8
  @max_integer 9_223_372_036_854_775_807
  @service_pattern ~r/\A[a-z][a-z0-9_]*\z/
  @setting_pattern ~r/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/
  @digest_pattern ~r/\A[0-9a-f]{64}\z/

  @type error :: {:error, :invalid | :unsupported}

  @spec effective(term()) :: error()
  def effective(service), do: service_operation(service)

  @spec source(term()) :: error()
  def source(service), do: service_operation(service)

  @spec revision(term()) :: error()
  def revision(service), do: service_operation(service)

  @spec validation(term()) :: error()
  def validation(service), do: service_operation(service)

  @spec update(term(), term()) :: error()
  def update(service, entries) do
    with :ok <- validate_service(service),
         :ok <- validate_entries(entries, 1) do
      unsupported()
    end
  end

  @spec apply(term()) :: error()
  def apply(service), do: service_operation(service)

  @spec reload(term()) :: error()
  def reload(service), do: service_operation(service)

  @spec rollback(term(), term()) :: error()
  def rollback(service, target_revision) do
    with :ok <- validate_service(service),
         :ok <- validate_digest(target_revision) do
      unsupported()
    end
  end

  defp service_operation(service) do
    with :ok <- validate_service(service), do: unsupported()
  end

  defp validate_service(service) when is_binary(service) do
    if bounded_text?(service, @max_service_bytes) and
         Regex.match?(@service_pattern, service) do
      :ok
    else
      invalid()
    end
  end

  defp validate_service(_service), do: invalid()

  defp validate_digest(digest) when is_binary(digest) do
    if Regex.match?(@digest_pattern, digest), do: :ok, else: invalid()
  end

  defp validate_digest(_digest), do: invalid()

  defp validate_entries(entries, depth) when is_list(entries) and depth <= @max_depth do
    if bounded_all?(entries, @max_entries, &valid_entry?(&1, depth)), do: :ok, else: invalid()
  end

  defp validate_entries(_entries, _depth), do: invalid()

  defp valid_entry?(
         %{"key" => key, "value" => value} = entry,
         depth
       )
       when map_size(entry) == 2 and is_binary(key) do
    bounded_text?(key, @max_key_bytes) and
      Regex.match?(@setting_pattern, key) and
      valid_setting_value?(value, depth)
  end

  defp valid_entry?(_entry, _depth), do: false

  defp valid_setting_value?(
         %{"type" => "string", "value" => value} = setting,
         _depth
       )
       when map_size(setting) == 2,
       do: bounded_text?(value, @max_text_bytes)

  defp valid_setting_value?(
         %{"type" => "integer", "value" => value} = setting,
         _depth
       )
       when map_size(setting) == 2 and is_integer(value),
       do: value >= -@max_integer and value <= @max_integer

  defp valid_setting_value?(
         %{"type" => "boolean", "value" => value} = setting,
         _depth
       )
       when map_size(setting) == 2,
       do: is_boolean(value)

  defp valid_setting_value?(
         %{"type" => "null", "value" => nil} = setting,
         _depth
       )
       when map_size(setting) == 2,
       do: true

  defp valid_setting_value?(
         %{"type" => "list", "items" => items} = setting,
         _depth
       )
       when map_size(setting) == 2 and is_list(items),
       do: bounded_all?(items, @max_entries, &valid_scalar?/1)

  defp valid_setting_value?(
         %{"type" => "object", "entries" => entries} = setting,
         depth
       )
       when map_size(setting) == 2 and depth < @max_depth,
       do: validate_entries(entries, depth + 1) == :ok

  defp valid_setting_value?(_setting, _depth), do: false

  defp valid_scalar?(value) when is_nil(value) or is_boolean(value) or is_float(value), do: true

  defp valid_scalar?(value) when is_integer(value),
    do: value >= -@max_integer and value <= @max_integer

  defp valid_scalar?(value) when is_binary(value), do: bounded_text?(value, @max_text_bytes)
  defp valid_scalar?(_value), do: false

  defp bounded_text?(value, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum,
       do: String.valid?(value) and not Regex.match?(~r/\p{C}/u, value)

  defp bounded_text?(_value, _maximum), do: false

  defp bounded_all?([], _remaining, _validator), do: true
  defp bounded_all?([_value | _rest], 0, _validator), do: false

  defp bounded_all?([value | rest], remaining, validator),
    do: validator.(value) and bounded_all?(rest, remaining - 1, validator)

  defp bounded_all?(_value, _remaining, _validator), do: false

  defp invalid, do: {:error, :invalid}
  defp unsupported, do: {:error, :unsupported}
end
