defmodule YellowDog.Worker.Dns.RootHints do
  @moduledoc """
  Built-in root hints: the 13 IANA root servers (source: IANA `named.root`,
  b.root-servers.net as renumbered in 2023).
  """

  @servers [
    {"a.root-servers.net", {198, 41, 0, 4}, {0x2001, 0x503, 0xBA3E, 0, 0, 0, 0x2, 0x30}},
    {"b.root-servers.net", {170, 247, 170, 2}, {0x2801, 0x1B8, 0x10, 0, 0, 0, 0, 0xB}},
    {"c.root-servers.net", {192, 33, 4, 12}, {0x2001, 0x500, 0x2, 0, 0, 0, 0, 0xC}},
    {"d.root-servers.net", {199, 7, 91, 13}, {0x2001, 0x500, 0x2D, 0, 0, 0, 0, 0xD}},
    {"e.root-servers.net", {192, 203, 230, 10}, {0x2001, 0x500, 0xA8, 0, 0, 0, 0, 0xE}},
    {"f.root-servers.net", {192, 5, 5, 241}, {0x2001, 0x500, 0x2F, 0, 0, 0, 0, 0xF}},
    {"g.root-servers.net", {192, 112, 36, 4}, {0x2001, 0x500, 0x12, 0, 0, 0, 0, 0xD0D}},
    {"h.root-servers.net", {198, 97, 190, 53}, {0x2001, 0x500, 0x1, 0, 0, 0, 0, 0x53}},
    {"i.root-servers.net", {192, 36, 148, 17}, {0x2001, 0x7FE, 0, 0, 0, 0, 0, 0x53}},
    {"j.root-servers.net", {192, 58, 128, 30}, {0x2001, 0x503, 0xC27, 0, 0, 0, 0x2, 0x30}},
    {"k.root-servers.net", {193, 0, 14, 129}, {0x2001, 0x7FD, 0, 0, 0, 0, 0, 0x1}},
    {"l.root-servers.net", {199, 7, 83, 42}, {0x2001, 0x500, 0x9F, 0, 0, 0, 0, 0x42}},
    {"m.root-servers.net", {202, 12, 27, 33}, {0x2001, 0xDC3, 0, 0, 0, 0, 0, 0x35}}
  ]

  @spec servers() :: [{String.t(), :inet.ip4_address(), :inet.ip6_address()}]
  def servers, do: @servers
end
