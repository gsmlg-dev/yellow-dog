defmodule YellowDog.Netman.DevConfigTest do
  use ExUnit.Case, async: true

  test "macOS dev config uses local mock-safe netman settings" do
    if :os.type() == {:unix, :darwin} do
      config_path = Path.expand("../../../config/dev.exs", __DIR__)
      config = Config.Reader.read!(config_path, env: :dev)

      netman_config = Keyword.fetch!(config, :yellow_dog_netman)
      assert Keyword.fetch!(netman_config, :netlink_backend) == :mock

      profile_dir = Keyword.fetch!(netman_config, :profile_dir)
      socket_path = Keyword.fetch!(netman_config, :socket_path)

      assert String.ends_with?(profile_dir, "/yellowdog/netman/profiles")
      refute String.starts_with?(profile_dir, "/etc/")

      assert String.ends_with?(socket_path, "/yellowdog/netman/netman.sock")
      refute String.starts_with?(socket_path, "/run/")

      dhcp_client_config = Keyword.fetch!(config, :yellow_dog_dhcp_client)

      assert Keyword.fetch!(dhcp_client_config, :socket_impl) ==
               YellowDog.DhcpClient.DhcpSocket.UdpFallback
    end
  end
end
