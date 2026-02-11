defmodule YellowDog.Netboot.Boot.ScriptEngineTest do
  use ExUnit.Case, async: false

  alias YellowDog.Netboot.Boot.ScriptEngine

  # ScriptEngine is already started by the Application — use it directly.

  describe "render/1" do
    test "renders default iPXE script with assigns" do
      assigns = %{
        server: "192.168.1.1",
        port: 4270,
        kernel: "nixos/bzImage",
        initrd: "nixos/initrd.img",
        kernel_args: "init=/nix/store/init ip=dhcp",
        mac: "AA:BB:CC:DD:EE:FF",
        arch: "x86_64"
      }

      assert {:ok, script} = ScriptEngine.render(assigns)
      assert String.starts_with?(script, "#!ipxe")
      assert String.contains?(script, "192.168.1.1")
      assert String.contains?(script, "nixos/bzImage")
      assert String.contains?(script, "AA:BB:CC:DD:EE:FF")
    end
  end

  describe "render_rescue/1" do
    test "renders rescue script" do
      assigns = %{
        server: "192.168.1.1",
        port: 4270,
        mac: "AA:BB:CC:DD:EE:FF"
      }

      assert {:ok, script} = ScriptEngine.render_rescue(assigns)
      assert String.starts_with?(script, "#!ipxe")
      assert String.contains?(script, "Rescue")
      assert String.contains?(script, "rescue/vmlinuz")
    end
  end

  describe "render_custom/2" do
    test "renders custom template" do
      template = "#!ipxe\necho Hello <%= @name %>"
      assert {:ok, script} = ScriptEngine.render_custom(template, %{name: "World"})
      assert script == "#!ipxe\necho Hello World"
    end

    test "returns error for syntax error in template" do
      assert {:error, _} = ScriptEngine.render_custom("<%= if true do %>unclosed", %{})
    end
  end
end
