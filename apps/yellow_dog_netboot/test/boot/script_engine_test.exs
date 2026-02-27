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

    test "renders custom template with string keys" do
      template = "#!ipxe\necho <%= @name %>"
      assert {:ok, script} = ScriptEngine.render_custom(template, %{"name" => "Hi"})
      assert script == "#!ipxe\necho Hi"
    end

    test "skips unknown string keys to prevent atom exhaustion" do
      template = "hello"
      # Unknown string keys that are not existing atoms should be silently skipped
      assert {:ok, "hello"} =
               ScriptEngine.render_custom(template, %{
                 "zzz_unknown_key_#{System.unique_integer()}" => "ignored"
               })
    end

    test "renders custom template with multiple assigns" do
      template = "<%= @a %> + <%= @b %> = <%= @c %>"
      assert {:ok, script} = ScriptEngine.render_custom(template, %{a: 1, b: 2, c: 3})
      assert script == "1 + 2 = 3"
    end

    test "missing assign returns empty string (EEx default behavior)" do
      assert {:ok, ""} = ScriptEngine.render_custom("<%= @missing %>", %{})
    end
  end

  describe "render/1 with string keys" do
    test "renders with string-keyed assigns" do
      assigns = %{
        "server" => "10.0.0.1",
        "port" => 8080,
        "kernel" => "test/vmlinuz",
        "initrd" => "test/initrd",
        "kernel_args" => "quiet",
        "mac" => "00:11:22:33:44:55",
        "arch" => "x86_64"
      }

      assert {:ok, script} = ScriptEngine.render(assigns)
      assert String.contains?(script, "10.0.0.1")
      assert String.contains?(script, "test/vmlinuz")
    end
  end

  describe "render/1 content verification" do
    test "includes kernel_args in output" do
      assigns = %{
        server: "10.0.0.1",
        port: 4270,
        kernel: "k",
        initrd: "i",
        kernel_args: "quiet splash",
        mac: "AA:BB:CC:DD:EE:FF",
        arch: "x86_64"
      }

      assert {:ok, script} = ScriptEngine.render(assigns)
      assert String.contains?(script, "quiet splash")
      assert String.contains?(script, "yellowdog.mac=AA:BB:CC:DD:EE:FF")
      assert String.contains?(script, "yellowdog.api=http://10.0.0.1:4270")
    end

    test "includes base-url with correct port" do
      assigns = %{
        server: "192.168.1.1",
        port: 9999,
        kernel: "k",
        initrd: "i",
        kernel_args: "",
        mac: "00:00:00:00:00:00",
        arch: "aarch64"
      }

      assert {:ok, script} = ScriptEngine.render(assigns)
      assert String.contains?(script, "http://192.168.1.1:9999/boot/assets")
      assert String.contains?(script, "(aarch64)")
    end
  end

  describe "render_rescue/1 content verification" do
    test "includes rescue-specific paths and server info" do
      assigns = %{
        server: "172.16.0.1",
        port: 4270,
        mac: "11:22:33:44:55:66"
      }

      assert {:ok, script} = ScriptEngine.render_rescue(assigns)
      assert String.contains?(script, "Rescue Shell")
      assert String.contains?(script, "rescue/initrd.img")
      assert String.contains?(script, "rescue shell")
      assert String.contains?(script, "172.16.0.1")
      assert String.contains?(script, "11:22:33:44:55:66")
    end
  end

  describe "init/1 via start_link" do
    test "starts a standalone ScriptEngine instance" do
      name = :"script_engine_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(ScriptEngine, [], name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert Process.alive?(pid)

      # Should be able to render using the named server
      assigns = %{
        server: "10.0.0.1",
        port: 4270,
        kernel: "test/k",
        initrd: "test/i",
        kernel_args: "",
        mac: "AA:BB:CC:DD:EE:FF",
        arch: "x86_64"
      }

      assert {:ok, script} = GenServer.call(name, {:render, :default, assigns})
      assert String.contains?(script, "test/k")
    end

    test "unknown template name falls back to default" do
      name = :"script_engine_test_#{System.unique_integer([:positive])}"
      {:ok, pid} = GenServer.start_link(ScriptEngine, [], name: name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assigns = %{
        server: "10.0.0.1",
        port: 4270,
        kernel: "k",
        initrd: "i",
        kernel_args: "",
        mac: "00:00:00:00:00:00",
        arch: "x86_64"
      }

      # Requesting a non-existent template name should use the default template
      assert {:ok, script} = GenServer.call(name, {:render, :nonexistent, assigns})
      assert String.contains?(script, "#!ipxe")
    end
  end

  describe "render_custom/2 edge cases" do
    test "handles template with no assigns" do
      assert {:ok, "static text"} = ScriptEngine.render_custom("static text", %{})
    end

    test "handles empty template" do
      assert {:ok, ""} = ScriptEngine.render_custom("", %{})
    end

    test "handles template with embedded Elixir logic" do
      template = "<%= if @flag, do: \"yes\", else: \"no\" %>"
      assert {:ok, "yes"} = ScriptEngine.render_custom(template, %{flag: true})
      assert {:ok, "no"} = ScriptEngine.render_custom(template, %{flag: false})
    end
  end
end
