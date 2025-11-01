defmodule YellowDog.Dns.RootZone.Hints do
  @moduledoc """
  Embedded DNS root server addresses (a-m.root-servers.net).

  Provides hardcoded root server addresses for the :hints strategy.
  These addresses are used when the DNS server needs to resolve queries
  recursively without fetching or loading the full root zone.

  The root server addresses are updated as of October 2024.
  Source: https://www.iana.org/domains/root/servers

  ## Usage

      # Get all root servers (IPv4 and IPv6)
      Hints.get_root_servers()

      # Get only IPv4 root servers
      Hints.get_root_servers_ipv4()

      # Get only IPv6 root servers
      Hints.get_root_servers_ipv6()
  """

  @root_servers_ipv4 [
    {"a.root-servers.net", {198, 41, 0, 4}},
    {"b.root-servers.net", {199, 9, 14, 201}},
    {"c.root-servers.net", {192, 33, 4, 12}},
    {"d.root-servers.net", {199, 7, 91, 13}},
    {"e.root-servers.net", {192, 203, 230, 10}},
    {"f.root-servers.net", {192, 5, 5, 241}},
    {"g.root-servers.net", {192, 112, 36, 4}},
    {"h.root-servers.net", {198, 97, 190, 53}},
    {"i.root-servers.net", {192, 36, 148, 17}},
    {"j.root-servers.net", {192, 58, 128, 30}},
    {"k.root-servers.net", {193, 0, 14, 129}},
    {"l.root-servers.net", {199, 7, 83, 42}},
    {"m.root-servers.net", {202, 12, 27, 33}}
  ]

  @root_servers_ipv6 [
    {"a.root-servers.net", {0x2001, 0x0503, 0xBA3E, 0x0000, 0x0000, 0x0000, 0x0002, 0x0030}},
    {"b.root-servers.net", {0x2001, 0x0500, 0x0200, 0x0000, 0x0000, 0x0000, 0x0000, 0x000B}},
    {"c.root-servers.net", {0x2001, 0x0500, 0x0002, 0x0000, 0x0000, 0x0000, 0x0000, 0x000C}},
    {"d.root-servers.net", {0x2001, 0x0500, 0x002D, 0x0000, 0x0000, 0x0000, 0x0000, 0x000D}},
    {"e.root-servers.net", {0x2001, 0x0500, 0x00A8, 0x0000, 0x0000, 0x0000, 0x0000, 0x000E}},
    {"f.root-servers.net", {0x2001, 0x0500, 0x002F, 0x0000, 0x0000, 0x0000, 0x0000, 0x000F}},
    {"g.root-servers.net", {0x2001, 0x0500, 0x0012, 0x0000, 0x0000, 0x0000, 0x0000, 0x0D0D}},
    {"h.root-servers.net", {0x2001, 0x0500, 0x0001, 0x0000, 0x0000, 0x0000, 0x0000, 0x0053}},
    {"i.root-servers.net", {0x2001, 0x07FE, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0053}},
    {"j.root-servers.net", {0x2001, 0x0503, 0x0C27, 0x0000, 0x0000, 0x0000, 0x0002, 0x0030}},
    {"k.root-servers.net", {0x2001, 0x07FD, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0001}},
    {"l.root-servers.net", {0x2001, 0x0500, 0x009F, 0x0000, 0x0000, 0x0000, 0x0000, 0x0042}},
    {"m.root-servers.net", {0x2001, 0x0DC3, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0035}}
  ]

  @doc """
  Returns all root servers (IPv4 and IPv6).

  ## Examples

      iex> servers = YellowDog.Dns.RootZone.Hints.get_root_servers()
      iex> length(servers)
      26
  """
  @spec get_root_servers() :: [{String.t(), :inet.ip_address()}]
  def get_root_servers do
    get_root_servers_ipv4() ++ get_root_servers_ipv6()
  end

  @doc """
  Returns IPv4 root server addresses.

  ## Examples

      iex> servers = YellowDog.Dns.RootZone.Hints.get_root_servers_ipv4()
      iex> length(servers)
      13
      iex> {"a.root-servers.net", {198, 41, 0, 4}} in servers
      true
  """
  @spec get_root_servers_ipv4() :: [{String.t(), :inet.ip4_address()}]
  def get_root_servers_ipv4, do: @root_servers_ipv4

  @doc """
  Returns IPv6 root server addresses.

  ## Examples

      iex> servers = YellowDog.Dns.RootZone.Hints.get_root_servers_ipv6()
      iex> length(servers)
      13
  """
  @spec get_root_servers_ipv6() :: [{String.t(), :inet.ip6_address()}]
  def get_root_servers_ipv6, do: @root_servers_ipv6

  @doc """
  Returns only IPv4 addresses (without names).
  """
  @spec get_ipv4_addresses() :: [:inet.ip4_address()]
  def get_ipv4_addresses do
    Enum.map(@root_servers_ipv4, fn {_name, ip} -> ip end)
  end

  @doc """
  Returns only IPv6 addresses (without names).
  """
  @spec get_ipv6_addresses() :: [:inet.ip6_address()]
  def get_ipv6_addresses do
    Enum.map(@root_servers_ipv6, fn {_name, ip} -> ip end)
  end

  @doc """
  Returns all IP addresses (IPv4 and IPv6 without names).

  ## Examples

      iex> addresses = YellowDog.Dns.RootZone.Hints.get_all_addresses()
      iex> length(addresses)
      26
  """
  @spec get_all_addresses() :: [:inet.ip_address()]
  def get_all_addresses do
    get_ipv4_addresses() ++ get_ipv6_addresses()
  end

  @doc """
  Gets a specific root server address by name.

  ## Examples

      iex> YellowDog.Dns.RootZone.Hints.get_server("a.root-servers.net")
      {:ok, {198, 41, 0, 4}}

      iex> YellowDog.Dns.RootZone.Hints.get_server("invalid")
      {:error, :not_found}
  """
  @spec get_server(String.t()) :: {:ok, :inet.ip_address()} | {:error, :not_found}
  def get_server(name) do
    case Enum.find(get_root_servers(), fn {server_name, _ip} -> server_name == name end) do
      {_name, ip} -> {:ok, ip}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Returns the number of root servers.

  ## Examples

      iex> YellowDog.Dns.RootZone.Hints.count()
      %{ipv4: 13, ipv6: 13, total: 26}
  """
  @spec count() :: %{ipv4: non_neg_integer(), ipv6: non_neg_integer(), total: non_neg_integer()}
  def count do
    %{
      ipv4: length(@root_servers_ipv4),
      ipv6: length(@root_servers_ipv6),
      total: length(@root_servers_ipv4) + length(@root_servers_ipv6)
    }
  end
end
