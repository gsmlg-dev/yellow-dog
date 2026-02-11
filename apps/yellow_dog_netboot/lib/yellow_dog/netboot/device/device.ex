defmodule YellowDog.Netboot.Device do
  @moduledoc """
  Device struct and state machine for netboot lifecycle.

  State transitions:
    discovered → booting → installing → installed
                   ↓            ↓
                 failed ←───────┘
                   ↓
              discovered (reset)
                                installed → reinstall_requested → booting
  """

  @valid_states ~w(discovered booting installing installed failed reinstall_requested)a
  @valid_arches ~w(x86_64 aarch64 bios_x86)a

  @transitions %{
    discovered: [:booting],
    booting: [:installing, :failed],
    installing: [:installed, :failed],
    installed: [:reinstall_requested],
    failed: [:discovered, :booting],
    reinstall_requested: [:booting]
  }

  @enforce_keys [:mac]
  defstruct [
    :mac,
    :uuid,
    :hostname,
    :arch,
    :profile_id,
    :ip_address,
    :last_error,
    state: :discovered,
    hardware_info: %{},
    first_seen: nil,
    last_seen: nil,
    install_attempts: 0,
    tags: [],
    state_history: [],
    slot: %{active: :a, pending: nil},
    rescue_mode: false
  ]

  @type state_entry :: %{state: atom(), at: DateTime.t()}

  @type t :: %__MODULE__{
          mac: String.t(),
          uuid: String.t() | nil,
          hostname: String.t() | nil,
          arch: atom() | nil,
          profile_id: String.t() | nil,
          state: atom(),
          ip_address: :inet.ip_address() | nil,
          hardware_info: map(),
          first_seen: DateTime.t() | nil,
          last_seen: DateTime.t() | nil,
          install_attempts: non_neg_integer(),
          last_error: String.t() | nil,
          tags: [String.t()],
          state_history: [state_entry()],
          slot: map(),
          rescue_mode: boolean()
        }

  @doc "Create a new device with the given MAC and optional attributes."
  @spec new(String.t(), map()) :: t()
  def new(mac, attrs \\ %{}) do
    now = DateTime.utc_now()

    %__MODULE__{
      mac: normalize_mac(mac),
      uuid: Map.get(attrs, :uuid),
      hostname: Map.get(attrs, :hostname),
      arch: validate_arch(Map.get(attrs, :arch)),
      profile_id: Map.get(attrs, :profile_id),
      ip_address: Map.get(attrs, :ip_address),
      state: :discovered,
      first_seen: now,
      last_seen: now,
      tags: Map.get(attrs, :tags, []),
      state_history: [%{state: :discovered, at: now}]
    }
  end

  @doc "Attempt to transition a device to a new state."
  @spec transition(t(), atom(), map()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition(%__MODULE__{state: current} = device, new_state, metadata \\ %{}) do
    allowed = Map.get(@transitions, current, [])

    if new_state in allowed do
      now = DateTime.utc_now()

      device =
        device
        |> Map.put(:state, new_state)
        |> Map.put(:last_seen, now)
        |> Map.update!(:state_history, &[%{state: new_state, at: now} | &1])
        |> apply_transition_side_effects(new_state, metadata)

      {:ok, device}
    else
      {:error, :invalid_transition}
    end
  end

  @doc "Return valid transitions from the current state."
  @spec valid_transitions(t()) :: [atom()]
  def valid_transitions(%__MODULE__{state: current}) do
    Map.get(@transitions, current, [])
  end

  @doc "Return all valid states."
  @spec valid_states() :: [atom()]
  def valid_states, do: @valid_states

  @doc "Return all valid architectures."
  @spec valid_arches() :: [atom()]
  def valid_arches, do: @valid_arches

  @doc "Normalize a MAC address to uppercase colon-separated format."
  @spec normalize_mac(String.t()) :: String.t()
  def normalize_mac(mac) do
    mac
    |> String.upcase()
    |> String.replace(~r/[^0-9A-F]/, "")
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map_join(":", &Enum.join/1)
  end

  # --- Private ---

  defp validate_arch(nil), do: nil
  defp validate_arch(arch) when arch in @valid_arches, do: arch

  defp validate_arch(arch) when is_binary(arch) do
    atom = String.to_existing_atom(arch)
    if atom in @valid_arches, do: atom, else: nil
  rescue
    ArgumentError -> nil
  end

  defp validate_arch(_), do: nil

  defp apply_transition_side_effects(device, :booting, _metadata) do
    %{device | install_attempts: device.install_attempts + 1}
  end

  defp apply_transition_side_effects(device, :failed, metadata) do
    %{device | last_error: Map.get(metadata, :error)}
  end

  defp apply_transition_side_effects(device, :installed, _metadata) do
    %{device | last_error: nil}
  end

  defp apply_transition_side_effects(device, _state, _metadata), do: device
end
