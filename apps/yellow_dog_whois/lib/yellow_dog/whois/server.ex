defmodule YellowDog.Whois.Server do
  @moduledoc """
  Define whois server address.
  Find whois server of Domain, IP or AS.
  """
  defstruct [:host, port: 43]

  @type t :: %__MODULE__{host: binary(), port: :inet.port_number()}

  def root() do
    %YellowDog.Whois.Server{host: "whois.iana.org"}
  end

  @spec for_domain(binary()) :: {:ok, t}
  def for_domain(_) do
    {:ok, root()}
  end

  @spec for_ip(binary()) :: {:ok, t}
  def for_ip(_) do
    {:ok, root()}
  end

  @spec for_asn(binary() | integer()) :: {:ok, t}
  def for_asn(_) do
    {:ok, root()}
  end
end
