defmodule YellowDog.Data.Persistence.Toml do
  @moduledoc """
  Persists collection data as TOML files.

  Records are stored as an array of TOML tables (`[[records]]`). On load,
  the file is parsed and records are returned as `{key, map}` pairs. On save,
  records are encoded using `YellowDog.Config.TomlEncoder`.

  ## Persistence opts

    * `:path` — file path for the TOML file (required)
    * `:key_field` — atom key used to extract the primary key from each record
    * `:serialize` — optional `(record -> map)` to transform before writing
    * `:deserialize` — optional `(map -> record)` to transform after reading
    * `:section` — TOML section name (default: `"records"`)

  ## File format

      [[records]]
      name = "my_acl"
      entries = ["10.0.0.0/8"]

      [[records]]
      name = "other_acl"
      entries = ["192.168.0.0/16"]
  """

  @behaviour YellowDog.Data.Persistence

  alias YellowDog.Config.{TomlHelpers, TomlEncoder}

  @impl true
  @spec load(map()) :: {:ok, [{term(), term()}]} | {:error, term()}
  def load(opts) do
    path = Map.fetch!(opts, :path)
    key_field = Map.fetch!(opts, :key_field)
    section = Map.get(opts, :section, "records")
    deserialize = Map.get(opts, :deserialize)

    case TomlHelpers.read_toml_file(path) do
      {:ok, data} ->
        items = Map.get(data, section, [])
        pairs = load_items(items, key_field, deserialize)
        {:ok, pairs}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_items(items, key_field, deserialize) when is_list(items) do
    Enum.map(items, fn item ->
      record = if deserialize, do: deserialize.(item), else: item
      key_str = to_string(key_field)

      key =
        Map.get(record, key_field) ||
          Map.get(record, key_str) ||
          Map.get(item, key_str) ||
          Map.get(item, key_field)

      {key, record}
    end)
  end

  defp load_items(items, _key_field, _deserialize) when is_map(items) do
    # Some TOML files use [section.key] instead of [[section]] arrays
    Enum.map(items, fn {key, value} -> {key, value} end)
  end

  @impl true
  @spec save([{term(), term()}], map()) :: :ok | {:error, term()}
  def save(pairs, opts) do
    path = Map.fetch!(opts, :path)
    section = Map.get(opts, :section, "records")
    serialize = Map.get(opts, :serialize)
    backup = Map.get(opts, :backup, false)

    records =
      Enum.map(pairs, fn {_key, record} ->
        if serialize, do: serialize.(record), else: ensure_string_keys(record)
      end)

    content = TomlEncoder.encode(%{section => records})

    if backup, do: TomlHelpers.maybe_create_backup(path, true)

    TomlHelpers.atomic_write(path, content)
  end

  # TomlEncoder expects string keys for deterministic output
  defp ensure_string_keys(record) when is_map(record) do
    Map.new(record, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp ensure_string_keys(record), do: record
end
