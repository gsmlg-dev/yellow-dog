defmodule YellowDog.Netboot.Manifest.ManagedProfile do
  @moduledoc """
  Lossless managed Netboot profile representation for the fixed control wire.
  """

  @enforce_keys [:profile_id, :name, :boot_asset_id, :arguments]
  defstruct [:profile_id, :name, :boot_asset_id, :arguments]

  @wire_keys ["profile_id", "name", "boot_asset_id", "arguments"]

  @type t :: %__MODULE__{
          profile_id: String.t(),
          name: String.t(),
          boot_asset_id: String.t(),
          arguments: [String.t()]
        }

  @spec from_wire(map()) :: {:ok, t()} | {:error, :invalid_profile}
  def from_wire(wire) when is_map(wire) do
    with true <- Map.keys(wire) |> MapSet.new() |> MapSet.equal?(MapSet.new(@wire_keys)),
         profile_id when is_binary(profile_id) <- Map.get(wire, "profile_id"),
         name when is_binary(name) <- Map.get(wire, "name"),
         boot_asset_id when is_binary(boot_asset_id) <- Map.get(wire, "boot_asset_id"),
         arguments when is_list(arguments) <- Map.get(wire, "arguments"),
         true <- Enum.all?(arguments, &is_binary/1) do
      {:ok,
       %__MODULE__{
         profile_id: profile_id,
         name: name,
         boot_asset_id: boot_asset_id,
         arguments: arguments
       }}
    else
      _other -> {:error, :invalid_profile}
    end
  end

  def from_wire(_wire), do: {:error, :invalid_profile}

  @spec to_wire(t()) :: map()
  def to_wire(%__MODULE__{} = profile) do
    %{
      "profile_id" => profile.profile_id,
      "name" => profile.name,
      "boot_asset_id" => profile.boot_asset_id,
      "arguments" => profile.arguments
    }
  end
end
