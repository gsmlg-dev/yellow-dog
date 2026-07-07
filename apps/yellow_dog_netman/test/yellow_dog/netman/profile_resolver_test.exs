defmodule YellowDog.Netman.ProfileResolverTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.ProfileResolver

  describe "resolve/1 with [yellow_dog_netman]" do
    test "local_server defaults to managed local networking features" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_netman" => %{
            "id" => "netman-office-01",
            "name" => "Office Netman",
            "profile" => "local_server"
          }
        })

      assert %{
               id: "netman-office-01",
               name: "Office Netman",
               profile: :local_server,
               source: :yellow_dog_netman,
               apply_mode: :managed,
               features: %{
                 interfaces: true,
                 dhcp_client: true,
                 dns_client: true,
                 routes: true,
                 link_state: true,
                 vpn: false
               }
             } = resolved
    end

    test "cloud_server defaults to observe_first apply mode" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_netman" => %{"profile" => "cloud_server"}
        })

      assert %{
               profile: :cloud_server,
               apply_mode: :observe_first,
               features: %{
                 interfaces: true,
                 dhcp_client: true,
                 dns_client: true,
                 routes: true,
                 link_state: true,
                 vpn: false
               }
             } = resolved
    end

    test "bare_metal defaults to managed networking features" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_netman" => %{"profile" => "bare_metal"}
        })

      assert %{
               profile: :bare_metal,
               apply_mode: :managed,
               features: %{
                 interfaces: true,
                 dhcp_client: true,
                 dns_client: true,
                 routes: true,
                 link_state: true,
                 vpn: false
               }
             } = resolved
    end

    test "vm defaults to static host networking without DHCP client" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_netman" => %{"profile" => "vm"}
        })

      assert %{
               profile: :vm,
               apply_mode: :managed,
               features: %{
                 interfaces: true,
                 dhcp_client: false,
                 dns_client: true,
                 routes: true,
                 link_state: true,
                 vpn: false
               }
             } = resolved
    end

    test "vpn_gateway sets vpn feature as configuration state only" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_netman" => %{"profile" => "vpn_gateway"}
        })

      assert %{
               profile: :vpn_gateway,
               apply_mode: :managed,
               features: %{interfaces: true, routes: true, dns_client: true, vpn: true}
             } = resolved

      assert resolved.features.dhcp_client == false
    end

    test "observe_only defaults to observe apply mode and passive features" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_netman" => %{"profile" => "observe_only"}
        })

      assert %{
               profile: :observe_only,
               apply_mode: :observe,
               features: %{
                 interfaces: true,
                 dhcp_client: false,
                 dns_client: false,
                 routes: false,
                 link_state: true,
                 vpn: false
               }
             } = resolved
    end

    test "explicit feature flags and apply mode override profile defaults" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_netman" => %{
            "profile" => "cloud_server",
            "features" => %{
              "routes" => false,
              "vpn" => true
            },
            "mode" => %{"apply" => "managed"}
          }
        })

      assert %{apply_mode: :managed, features: %{routes: false, vpn: true}} = resolved
      assert resolved.features.interfaces == true
    end

    test "custom profile starts from disabled feature defaults" do
      resolved =
        ProfileResolver.resolve(%{
          "yellow_dog_netman" => %{
            "profile" => "custom",
            "features" => %{"interfaces" => true, "link_state" => true}
          }
        })

      assert %{
               profile: :custom,
               features: %{
                 interfaces: true,
                 dhcp_client: false,
                 dns_client: false,
                 routes: false,
                 link_state: true,
                 vpn: false
               },
               apply_mode: :managed
             } = resolved
    end
  end
end
