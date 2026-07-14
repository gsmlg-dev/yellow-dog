defmodule YellowDog.Server.ProfileResolverTest do
  use ExUnit.Case, async: true

  alias YellowDog.Server.ProfileResolver

  describe "resolve/1 with [yellow_dog_server]" do
    test "cloud_dns enables DNS and server agent only" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_server" => %{
            "id" => "srv-cloud-dns-01",
            "name" => "Cloud DNS 01",
            "profile" => "cloud_dns"
          }
        })

      assert %{
               id: "srv-cloud-dns-01",
               name: "Cloud DNS 01",
               profile: :cloud_dns,
               source: :yellow_dog_server,
               services: %{
                 dns: true,
                 mdns: false,
                 dhcpv4: false,
                 dhcpv6: false,
                 netboot: false,
                 identity: false,
                 fingerprint: false,
                 server_agent: true
               }
             } = resolved
    end

    test "local_network enables local network server services" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_server" => %{"profile" => "local_network"}
        })

      assert %{
               profile: :local_network,
               services: %{
                 dns: true,
                 mdns: true,
                 dhcpv4: true,
                 dhcpv6: true,
                 netboot: true,
                 identity: true,
                 fingerprint: true,
                 server_agent: true
               }
             } = resolved
    end

    test "dns_only enables DNS and server agent only" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_server" => %{"profile" => "dns_only"}
        })

      assert %{
               profile: :dns_only,
               services: %{
                 dns: true,
                 mdns: false,
                 dhcpv4: false,
                 dhcpv6: false,
                 netboot: false,
                 identity: false,
                 fingerprint: false,
                 server_agent: true
               }
             } = resolved
    end

    test "dhcp_only enables DHCP services and server agent only" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_server" => %{"profile" => "dhcp_only"}
        })

      assert %{
               profile: :dhcp_only,
               services: %{
                 dns: false,
                 mdns: false,
                 dhcpv4: true,
                 dhcpv6: true,
                 netboot: false,
                 identity: false,
                 fingerprint: false,
                 server_agent: true
               }
             } = resolved
    end

    test "netboot_only enables netboot and server agent only" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_server" => %{"profile" => "netboot_only"}
        })

      assert %{
               profile: :netboot_only,
               services: %{
                 dns: false,
                 mdns: false,
                 dhcpv4: false,
                 dhcpv6: false,
                 netboot: true,
                 identity: false,
                 fingerprint: false,
                 server_agent: true
               }
             } = resolved
    end

    test "explicit service flags override profile defaults including false" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_server" => %{
            "profile" => "local_network",
            "services" => %{
              "dns" => false,
              "dhcpv6" => false,
              "fingerprint" => false,
              "server_agent" => true
            }
          }
        })

      assert %{services: %{dns: false, dhcpv6: false, fingerprint: false, server_agent: true}} =
               resolved

      assert resolved.services.mdns == true
      assert resolved.services.dhcpv4 == true
    end

    test "non-boolean explicit service flags fail closed" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_server" => %{
            "profile" => "local_network",
            "services" => %{
              "dns" => "false",
              "mdns" => true,
              "dhcpv4" => 1
            }
          }
        })

      assert resolved.services.dns == false
      assert resolved.services.mdns == true
      assert resolved.services.dhcpv4 == false
    end

    test "custom profile starts from disabled service defaults" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_server" => %{
            "profile" => "custom",
            "services" => %{"dns" => true, "mdns" => true}
          }
        })

      assert %{
               profile: :custom,
               services: %{
                 dns: true,
                 mdns: true,
                 dhcpv4: false,
                 dhcpv6: false,
                 netboot: false,
                 identity: false,
                 fingerprint: false,
                 server_agent: false
               }
             } = resolved
    end
  end

  describe "legacy [core] fallback" do
    test "falls back to legacy core flags when new server config is absent" do
      resolved =
        ProfileResolver.resolve(%{
          "core" => %{
            "dns" => true,
            "mdns" => false,
            "dhcpv4" => true,
            "dhcpv6" => false,
            "netboot" => true,
            "identity" => false
          }
        })

      assert %{
               profile: :custom,
               source: :legacy_core,
               services: %{
                 dns: true,
                 mdns: false,
                 dhcpv4: true,
                 dhcpv6: false,
                 netboot: true,
                 identity: false,
                 fingerprint: false,
                 server_agent: false
               }
             } = resolved
    end

    test "uses legacy defaults when core flags are omitted" do
      resolved =
        ProfileResolver.resolve(%{
          "core" => %{
            "dns" => false
          }
        })

      assert %{
               profile: :custom,
               source: :legacy_core,
               services: %{
                 dns: false,
                 mdns: true,
                 dhcpv4: true,
                 dhcpv6: true,
                 netboot: false,
                 identity: true,
                 fingerprint: false,
                 server_agent: false
               }
             } = resolved
    end
  end
end
