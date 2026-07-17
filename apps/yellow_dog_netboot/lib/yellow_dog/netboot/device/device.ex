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
      hardware_info: Map.get(attrs, :hardware_info, %{}),
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

  @doc "Return whether a MAC is a complete normalized hardware address."
  @spec valid_mac?(term()) :: boolean()
  def valid_mac?(mac) when is_binary(mac) do
    normalized = normalize_mac(mac)
    normalized == mac and Regex.match?(~r/^[0-9A-F]{2}(:[0-9A-F]{2}){5}$/, normalized)
  end

  def valid_mac?(_mac), do: false

  @doc false
  @spec validate(t()) :: :ok | {:error, :invalid_device}
  def validate(%__MODULE__{} = device) do
    valid =
      valid_mac?(device.mac) and
        optional_nonempty_text?(device.uuid) and
        optional_text?(device.hostname) and
        (is_nil(device.arch) or device.arch in @valid_arches) and
        optional_nonempty_text?(device.profile_id) and
        device.state in @valid_states and
        valid_ip_address?(device.ip_address) and
        is_map(device.hardware_info) and
        valid_term?(device.hardware_info) and
        optional_datetime?(device.first_seen) and
        optional_datetime?(device.last_seen) and
        is_integer(device.install_attempts) and device.install_attempts >= 0 and
        optional_text?(device.last_error) and
        is_list(device.tags) and Enum.all?(device.tags, &is_binary/1) and
        valid_state_history?(device.state_history) and
        valid_slot?(device.slot) and
        is_boolean(device.rescue_mode)

    if valid, do: :ok, else: {:error, :invalid_device}
  end

  def validate(_device), do: {:error, :invalid_device}

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

  defp optional_nonempty_text?(nil), do: true
  defp optional_nonempty_text?(value), do: is_binary(value) and value != ""

  defp optional_text?(nil), do: true
  defp optional_text?(value), do: is_binary(value)

  defp optional_datetime?(nil), do: true
  defp optional_datetime?(value), do: is_struct(value, DateTime)

  defp valid_ip_address?(nil), do: true

  defp valid_ip_address?(address) when is_tuple(address) and tuple_size(address) == 4 do
    address
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 in 0..255))
  end

  defp valid_ip_address?(address) when is_tuple(address) and tuple_size(address) == 8 do
    address
    |> Tuple.to_list()
    |> Enum.all?(&(is_integer(&1) and &1 in 0..65_535))
  end

  defp valid_ip_address?(_address), do: false

  defp valid_state_history?(history) when is_list(history) do
    Enum.all?(history, fn
      %{state: state, at: %DateTime{}} -> state in @valid_states
      _entry -> false
    end)
  end

  defp valid_state_history?(_history), do: false

  defp valid_slot?(%{active: active, pending: pending} = slot) do
    map_size(slot) == 2 and active in [:a, :b] and pending in [nil, :a, :b]
  end

  defp valid_slot?(_slot), do: false

  defp valid_term?(value)
       when is_nil(value) or is_boolean(value) or is_binary(value) or is_number(value) or
              is_atom(value),
       do: true

  defp valid_term?(value) when is_list(value), do: Enum.all?(value, &valid_term?/1)

  defp valid_term?(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.all?(&valid_term?/1)
  end

  defp valid_term?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> valid_term?(key) and valid_term?(nested) end)
  end

  defp valid_term?(_value), do: false

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
