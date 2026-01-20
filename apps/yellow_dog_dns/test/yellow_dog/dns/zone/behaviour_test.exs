defmodule YellowDog.Dns.Zone.BehaviourTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.Zone.Behaviour.

  Tests cover:
  - Module structure and compilation
  - Behaviour callback definitions
  - Callback specifications
  - Zone implementations compliance
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.Zone.Behaviour

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Behaviour)
    end

    test "module has @moduledoc" do
      Code.ensure_loaded!(Behaviour)
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Behaviour)

      assert module_doc != :hidden
      assert module_doc != :none
    end

    test "module defines behaviour" do
      Code.ensure_loaded!(Behaviour)
      # Behaviour modules define callbacks
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert is_list(callbacks)
    end
  end

  describe "behaviour callbacks" do
    test "defines get_name/1 callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert {:get_name, 1} in callbacks
    end

    test "defines resolve/2 callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert {:resolve, 2} in callbacks
    end

    test "defines reload/2 callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert {:reload, 2} in callbacks
    end

    test "defines stats/1 callback" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert {:stats, 1} in callbacks
    end

    test "has exactly 4 callbacks" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert length(callbacks) == 4
    end
  end

  describe "callback specifications" do
    test "get_name/1 expects pid parameter" do
      # Verify callback exists with arity 1
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:get_name, 1} in callbacks
    end

    test "resolve/2 expects pid and query parameters" do
      # Verify callback exists with arity 2
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:resolve, 2} in callbacks
    end

    test "reload/2 expects pid and config parameters" do
      # Verify callback exists with arity 2
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:reload, 2} in callbacks
    end

    test "stats/1 expects pid parameter" do
      # Verify callback exists with arity 1
      callbacks = Behaviour.behaviour_info(:callbacks)
      assert {:stats, 1} in callbacks
    end
  end

  describe "zone implementations compliance" do
    # Test that known zone types implement the behaviour
    # Note: __info__(:attributes) returns behaviours as [{:behaviour, [Module]}, ...]

    defp implements_behaviour?(module, behaviour) do
      Code.ensure_loaded!(module)
      attrs = module.__info__(:attributes)

      # Behaviours may appear as multiple {:behaviour, [Module]} entries
      Enum.any?(attrs, fn
        {:behaviour, behaviours} -> behaviour in behaviours
        _ -> false
      end)
    end

    test "Zone.Auth implements Behaviour" do
      assert implements_behaviour?(YellowDog.Dns.Zone.Auth, Behaviour)
    end

    test "Zone.Cache implements Behaviour" do
      assert implements_behaviour?(YellowDog.Dns.Zone.Cache, Behaviour)
    end

    test "Zone.Forward implements Behaviour" do
      assert implements_behaviour?(YellowDog.Dns.Zone.Forward, Behaviour)
    end

    test "Zone.Stub implements Behaviour" do
      assert implements_behaviour?(YellowDog.Dns.Zone.Stub, Behaviour)
    end

    test "Zone.Root implements Behaviour" do
      assert implements_behaviour?(YellowDog.Dns.Zone.Root, Behaviour)
    end

    test "Zone.RPZ implements Behaviour" do
      assert implements_behaviour?(YellowDog.Dns.Zone.RPZ, Behaviour)
    end
  end

  describe "Zone.Auth callback implementations" do
    test "implements get_name/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Auth)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Auth, :get_name, 1)
    end

    test "implements resolve/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Auth)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Auth, :resolve, 2)
    end

    test "implements reload/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Auth)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Auth, :reload, 2)
    end

    test "implements stats/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Auth)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Auth, :stats, 1)
    end
  end

  describe "Zone.Cache callback implementations" do
    test "implements get_name/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Cache)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Cache, :get_name, 1)
    end

    test "implements resolve/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Cache)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Cache, :resolve, 2)
    end

    test "implements reload/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Cache)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Cache, :reload, 2)
    end

    test "implements stats/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Cache)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Cache, :stats, 1)
    end
  end

  describe "Zone.Forward callback implementations" do
    test "implements get_name/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Forward)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Forward, :get_name, 1)
    end

    test "implements resolve/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Forward)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Forward, :resolve, 2)
    end

    test "implements reload/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Forward)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Forward, :reload, 2)
    end

    test "implements stats/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Forward)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Forward, :stats, 1)
    end
  end

  describe "Zone.Stub callback implementations" do
    test "implements get_name/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Stub)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Stub, :get_name, 1)
    end

    test "implements resolve/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Stub)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Stub, :resolve, 2)
    end

    test "implements reload/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Stub)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Stub, :reload, 2)
    end

    test "implements stats/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Stub)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Stub, :stats, 1)
    end
  end

  describe "Zone.Root callback implementations" do
    test "implements get_name/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Root)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Root, :get_name, 1)
    end

    test "implements resolve/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Root)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Root, :resolve, 2)
    end

    test "implements reload/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Root)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Root, :reload, 2)
    end

    test "implements stats/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.Root)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.Root, :stats, 1)
    end
  end

  describe "Zone.RPZ callback implementations" do
    test "implements get_name/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.RPZ)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.RPZ, :get_name, 1)
    end

    test "implements resolve/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.RPZ)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.RPZ, :resolve, 2)
    end

    test "implements reload/2" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.RPZ)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.RPZ, :reload, 2)
    end

    test "implements stats/1" do
      Code.ensure_loaded!(YellowDog.Dns.Zone.RPZ)
      assert Kernel.function_exported?(YellowDog.Dns.Zone.RPZ, :stats, 1)
    end
  end

  describe "documentation" do
    test "behaviour has @moduledoc documentation" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(Behaviour)

      assert %{"en" => doc_string} = module_doc
      assert String.contains?(doc_string, "Behaviour")
    end

    test "get_name callback has @doc" do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Behaviour)

      get_name_docs =
        Enum.find(docs, fn
          {{:callback, :get_name, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert get_name_docs != nil
    end

    test "resolve callback has @doc" do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Behaviour)

      resolve_docs =
        Enum.find(docs, fn
          {{:callback, :resolve, 2}, _, _, _, _} -> true
          _ -> false
        end)

      assert resolve_docs != nil
    end

    test "reload callback has @doc" do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Behaviour)

      reload_docs =
        Enum.find(docs, fn
          {{:callback, :reload, 2}, _, _, _, _} -> true
          _ -> false
        end)

      assert reload_docs != nil
    end

    test "stats callback has @doc" do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(Behaviour)

      stats_docs =
        Enum.find(docs, fn
          {{:callback, :stats, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert stats_docs != nil
    end
  end
end
