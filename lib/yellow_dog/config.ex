defmodule YellowDog.Config do
  # https://hexdocs.pm/elixir/Agent.html
  use Agent

  def start_link(config) do
    Agent.start_link(fn -> config end, name: __MODULE__)
  end

  def config do
    Agent.get(__MODULE__, fn state -> state end)
  end

  def config(name) do
    Agent.get(__MODULE__, fn state -> Map.get(state, name) end)
  end

  @default_config %{
    "port" => 1053,
    "base" => "test",
    "nameserver" => "ns1.test=::1",
    "maintainer" => "root.invalid",
    "logging-facility" => "local0",
    "logging-level" => "warning",
    "console" => true,
    "bind" => [:any],
    "negative-ttl" => 86400,
    "server-bufsize" => 1440,
    "default-nonnull-ttl" => 30,
    "secret-salt-for-cookies" => "I hate wasabi",
    "dnssec_key" => nil,
    "dnssec_key_tag" => nil,
    "ipc-socket" => nil,
    "services" => ["date", "random", "ip", "connection", "hello", "ecs", "unit", "op"],
    "ipv4-only" => false,
    "ipv6-only" => false,
    "max-random-value" => 1000,
    # False by default since
    "statistics" => false,
    # they can probably
    # seriously slow down the
    # server
    "dot-cert" => nil,
    "dot-key" => nil,
    "dot-port" => 853,
    "padding" => true,
    # RFC 9567, DNS Error Reporting
    "reporting-agent" => nil,
    "report-via-dns" => false,
    # Now the IETF experimental stuff
    # https://datatracker.ietf.org/doc/draft-ietf-dnsop-zoneversion/,
    "zoneversion" => false
  }

  @config_file_home System.get_env("HOME") <> "/.yellowdog.toml"
  @config_file_etc "/etc/yellowdog.toml"
  def config_files do
    [@config_file_home, @config_file_etc]
  end

  def default_config do
    @default_config
  end
end
