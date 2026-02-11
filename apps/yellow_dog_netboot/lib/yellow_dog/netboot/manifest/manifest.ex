defmodule YellowDog.Netboot.Manifest do
  @moduledoc """
  Install manifest struct for device provisioning.

  Defines the installation parameters a device installer
  will use to complete OS installation.
  """

  defstruct [
    :profile,
    :disk_layout,
    :flake,
    slot_strategy: "single",
    post_install_hooks: []
  ]

  @type t :: %__MODULE__{
          profile: String.t(),
          disk_layout: String.t() | nil,
          flake: String.t() | nil,
          slot_strategy: String.t(),
          post_install_hooks: [String.t()]
        }

  @doc "Create a manifest from a config map."
  @spec from_config(map()) :: t()
  def from_config(config) when is_map(config) do
    %__MODULE__{
      profile: Map.get(config, "profile"),
      disk_layout: Map.get(config, "disk_layout"),
      flake: Map.get(config, "flake"),
      slot_strategy: Map.get(config, "slot_strategy", "single"),
      post_install_hooks: Map.get(config, "post_install_hooks", [])
    }
  end

  @doc "Serialize manifest to a JSON-compatible map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = m) do
    %{
      "profile" => m.profile,
      "disk_layout" => m.disk_layout,
      "flake" => m.flake,
      "slot_strategy" => m.slot_strategy,
      "post_install_hooks" => m.post_install_hooks
    }
  end
end
