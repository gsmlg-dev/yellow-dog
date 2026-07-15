defmodule YellowDog.Sync.Identity do
  @moduledoc false

  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  defmodule Server do
    @enforce_keys [:id, :name, :version, :profile, :capabilities, :config_revision]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            version: String.t(),
            profile: String.t(),
            capabilities: [String.t()],
            config_revision: String.t()
          }
  end

  defmodule Netman do
    @enforce_keys [:id, :name, :version, :profile, :capabilities, :config_revision]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            version: String.t(),
            profile: String.t(),
            capabilities: [String.t()],
            config_revision: String.t()
          }
  end

  @type t :: Server.t() | Netman.t()

  @spec to_wire(t()) :: map()
  def to_wire(%Server{} = identity), do: to_wire(identity, "server")
  def to_wire(%Netman{} = identity), do: to_wire(identity, "netman")

  @spec from_wire(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(wire) when is_map(wire) do
    with {:ok, wire} <- Bounds.map(wire) do
      decode_wire(wire)
    else
      _ -> invalid_error()
    end
  end

  def from_wire(_wire), do: invalid_error()

  @spec from_wire(map(), :server | :netman) :: {:ok, t()} | {:error, Error.t()}
  def from_wire(wire, expected_type) when expected_type in [:server, :netman] do
    with {:ok, identity} <- from_wire(wire),
         true <- target_type(identity) == expected_type do
      {:ok, identity}
    else
      _ -> invalid_error()
    end
  end

  def from_wire(_wire, _expected_type), do: invalid_error()

  defp decode_wire(%{"target_type" => "server"} = wire), do: decode(Server, wire)
  defp decode_wire(%{"target_type" => "netman"} = wire), do: decode(Netman, wire)
  defp decode_wire(_wire), do: invalid_error()

  defp to_wire(identity, target_type) do
    %{
      "target_type" => target_type,
      "id" => identity.id,
      "name" => identity.name,
      "version" => identity.version,
      "profile" => identity.profile,
      "capabilities" => identity.capabilities,
      "config_revision" => identity.config_revision
    }
  end

  defp decode(module, wire) do
    with {:ok, id} <- fetch_and_validate(wire, "id", &valid_id/1),
         {:ok, name} <- fetch_and_validate(wire, "name", &Bounds.message/1),
         {:ok, version} <- fetch_and_validate(wire, "version", &Bounds.message/1),
         {:ok, profile} <- fetch_and_validate(wire, "profile", &Bounds.message/1),
         {:ok, capabilities} <- fetch_and_validate(wire, "capabilities", &capabilities/1),
         {:ok, config_revision} <- fetch_and_validate(wire, "config_revision", &Digest.validate/1) do
      {:ok,
       struct!(module,
         id: id,
         name: name,
         version: version,
         profile: profile,
         capabilities: capabilities,
         config_revision: config_revision
       )}
    else
      _ -> invalid_error()
    end
  end

  defp capabilities(value) do
    with {:ok, values} <- Bounds.list(value) do
      Enum.reduce_while(values, {:ok, []}, fn value, {:ok, capabilities} ->
        case Bounds.message(value) do
          {:ok, value} -> {:cont, {:ok, [value | capabilities]}}
          {:error, %Error{}} -> {:halt, invalid_error()}
        end
      end)
      |> case do
        {:ok, capabilities} -> {:ok, Enum.reverse(capabilities)}
        error -> error
      end
    end
  end

  defp fetch_and_validate(wire, key, validator) do
    with {:ok, value} <- Map.fetch(wire, key),
         {:ok, value} <- validator.(value) do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp valid_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _ -> invalid_error()
    end
  end

  defp target_type(%Server{}), do: :server
  defp target_type(%Netman{}), do: :netman

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
