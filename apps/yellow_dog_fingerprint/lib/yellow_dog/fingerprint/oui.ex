defmodule YellowDog.Fingerprint.OUI do
  @moduledoc """
  OUI (Organizationally Unique Identifier) vendor lookup.

  Delegates to `GSMLG.MAC.lookup_vendor/1` for manufacturer resolution.
  Provides a consistent API for the fingerprint app.
  """

  use GenServer

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Looks up the vendor for a MAC address.

  Returns `{:ok, vendor}` or `:not_found`.
  """
  @spec lookup(String.t()) :: {:ok, String.t()} | :not_found
  def lookup(mac) do
    normalized = normalize_mac(mac)

    case lookup_runtime_or_compiled(normalized) do
      {:ok, _short, full} -> {:ok, full}
      :error -> :not_found
    end
  end

  @doc """
  Looks up the vendor returning both short and full names.

  Returns `{:ok, short_name, full_name}` or `:not_found`.
  """
  @spec lookup_full(String.t()) :: {:ok, String.t(), String.t()} | :not_found
  def lookup_full(mac) do
    normalized = normalize_mac(mac)

    case lookup_runtime_or_compiled(normalized) do
      {:ok, short, full} -> {:ok, short, full}
      :error -> :not_found
    end
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  # --- Private ---

  defp lookup_runtime_or_compiled(mac) do
    case YellowDog.Fingerprint.OuiDatabase.lookup(mac) do
      {:ok, short, full} -> {:ok, short, full}
      :error -> GSMLG.MAC.lookup_vendor(mac)
    end
  end

  defp normalize_mac(mac) do
    mac
    |> String.downcase()
    |> String.replace(~r/[^0-9a-f]/, ":")
    |> normalize_colons()
  end

  defp normalize_colons(mac) do
    parts =
      mac
      |> String.replace(":", "")
      |> String.replace("-", "")
      |> String.codepoints()
      |> Enum.chunk_every(2)
      |> Enum.map(&Enum.join/1)

    Enum.join(parts, ":")
  end
end
