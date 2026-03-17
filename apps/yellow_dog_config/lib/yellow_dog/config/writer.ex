defmodule YellowDog.Config.Writer do
  @moduledoc """
  Unified write pipeline for TOML configuration files.

  Replaces the line-based regex patcher with a proper
  load → apply_updates → validate → encode → atomic_write pipeline.

  Unlike the old approach, this can create new sections and keys freely.
  """

  alias YellowDog.Config.{Schema, TomlEncoder, TomlHelpers}

  @doc """
  Writes a config map to a TOML file.

  Validates the config before writing and uses atomic writes
  (temp file + rename) to prevent corruption.

  ## Options

    * `:header` - comment block to prepend (default: managed-file header)
    * `:validate` - whether to validate before writing (default: true)

  ## Returns

    * `:ok` on success
    * `{:error, {:validation_failed, errors}}` if validation fails
    * `{:error, reason}` on write failure
  """
  @spec write_config(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def write_config(path, config, opts \\ []) do
    validate? = Keyword.get(opts, :validate, true)
    header = Keyword.get(opts, :header, default_header())

    with :ok <- maybe_validate(config, validate?),
         content = TomlEncoder.encode(config, header: header),
         :ok <- TomlHelpers.atomic_write(path, content) do
      :ok
    end
  end

  @doc """
  Applies dot-notation updates to a config map.

  Takes a config map and a map of `"section.key" => value` updates.
  Splits keys on `"."` and uses nested `put_in` to apply changes.

  Can create new sections and keys that don't yet exist.

  ## Examples

      iex> config = %{"dns" => %{"port" => 53}}
      iex> Writer.apply_updates(config, %{"dns.port" => 5353})
      %{"dns" => %{"port" => 5353}}

      iex> Writer.apply_updates(%{}, %{"new_section.key" => "value"})
      %{"new_section" => %{"key" => "value"}}
  """
  @spec apply_updates(map(), map()) :: map()
  def apply_updates(config, updates) when is_map(config) and is_map(updates) do
    Enum.reduce(updates, config, fn {dot_key, value}, acc ->
      path = String.split(dot_key, ".")
      deep_put(acc, path, value)
    end)
  end

  @doc """
  Writes the default configuration to a file.
  """
  @spec write_defaults(Path.t()) :: :ok | {:error, term()}
  def write_defaults(path) do
    write_config(path, Schema.defaults(), validate: false)
  end

  @doc """
  Writes a minimal configuration (all services disabled) to a file.
  """
  @spec write_minimal(Path.t()) :: :ok | {:error, term()}
  def write_minimal(path) do
    write_config(path, Schema.minimal(), validate: false)
  end

  # Puts a value at a nested path, creating intermediate maps as needed.
  defp deep_put(map, [key], value), do: Map.put(map, key, value)

  defp deep_put(map, [key | rest], value) do
    child = Map.get(map, key, %{})
    Map.put(map, key, deep_put(child, rest, value))
  end

  defp maybe_validate(_config, false), do: :ok

  defp maybe_validate(config, true) do
    case Schema.validate(config) do
      :ok -> :ok
      {:error, errors} -> {:error, {:validation_failed, errors}}
    end
  end

  defp default_header do
    "# Yellow Dog Configuration\n# Managed by YellowDog Console — manual edits may be overwritten on save"
  end
end
