defmodule YellowDog.DnsProvider.SyncConflict do
  @moduledoc """
  Represents a conflict between local and remote DNS records
  detected during sync when using the `:manual` conflict strategy.
  """

  @enforce_keys [:id, :provider_name, :zone, :owner, :type]
  defstruct [
    :id,
    :provider_name,
    :zone,
    :owner,
    :type,
    :local_records,
    :remote_records,
    :detected_at
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          provider_name: String.t(),
          zone: String.t(),
          owner: String.t(),
          type: String.t(),
          local_records: [map()],
          remote_records: [map()],
          detected_at: integer()
        }

  @spec new(map()) :: t()
  def new(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id, generate_id()),
      provider_name: Map.fetch!(attrs, :provider_name),
      zone: Map.fetch!(attrs, :zone),
      owner: Map.fetch!(attrs, :owner),
      type: Map.fetch!(attrs, :type),
      local_records: Map.get(attrs, :local_records, []),
      remote_records: Map.get(attrs, :remote_records, []),
      detected_at: Map.get(attrs, :detected_at, System.system_time(:second))
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
