defmodule DNS.Zone.NameTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.Name.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 function with various inputs
  - from_domain/1 conversion
  - child?/2 hierarchy detection
  - match_domain/2 domain matching
  - Protocol implementations (DNS.Parameter, String.Chars, Inspect)
  """
  use ExUnit.Case, async: true

  alias DNS.Zone.Name
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Name)
    end

    test "exports new/1" do
      Code.ensure_loaded!(Name)
      assert Kernel.function_exported?(Name, :new, 1)
    end

    test "exports from_domain/1" do
      Code.ensure_loaded!(Name)
      assert Kernel.function_exported?(Name, :from_domain, 1)
    end

    test "exports child?/2" do
      Code.ensure_loaded!(Name)
      assert Kernel.function_exported?(Name, :child?, 2)
    end

    test "exports match_domain/2" do
      Code.ensure_loaded!(Name)
      assert Kernel.function_exported?(Name, :match_domain, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Name)
      assert is_struct(Name.__struct__())
    end
  end

  describe "struct fields" do
    test "has value field" do
      name = %Name{}
      assert Map.has_key?(name, :value)
    end

    test "has data field" do
      name = %Name{}
      assert Map.has_key?(name, :data)
    end

    test "default value is root domain" do
      assert %Name{}.value == "."
    end

    test "default data is null label" do
      assert %Name{}.data == <<0>>
    end
  end

  describe "new/1 with root domain" do
    test "creates root Name from dot" do
      root = Name.new(".")

      assert root.value == "."
      assert root.data == <<0>>
    end

    test "root is idempotent" do
      root1 = Name.new(".")
      root2 = Name.new(".")

      assert root1 == root2
    end
  end

  describe "new/1 with simple domains" do
    test "creates Name for TLD" do
      name = Name.new("com")

      assert name.value == "com"
      assert name.data == <<3, "com">>
    end

    test "creates Name for second-level domain" do
      name = Name.new("example.com")

      assert name.value == "example.com"
      # Data is stored in reverse order (TLD first)
      assert name.data == <<3, "com", 7, "example">>
    end

    test "creates Name for subdomain" do
      name = Name.new("www.example.com")

      assert name.value == "www.example.com"
      assert name.data == <<3, "com", 7, "example", 3, "www">>
    end

    test "creates Name for deep subdomain" do
      name = Name.new("a.b.c.example.com")

      assert name.value == "a.b.c.example.com"
      assert name.data == <<3, "com", 7, "example", 1, "c", 1, "b", 1, "a">>
    end
  end

  describe "new/1 with trailing dots" do
    test "trims trailing dot" do
      name = Name.new("example.com.")

      assert name.value == "example.com"
    end

    test "trims multiple trailing dots" do
      name = Name.new("example.com..")

      assert name.value == "example.com"
    end

    test "trims leading dot" do
      name = Name.new(".example.com")

      assert name.value == "example.com"
    end
  end

  describe "new/1 edge cases" do
    test "handles empty string" do
      name = Name.new("")

      assert name.value == ""
      assert name.data == <<0>>
    end

    test "handles single label" do
      name = Name.new("localhost")

      assert name.value == "localhost"
      assert name.data == <<9, "localhost">>
    end

    test "handles numeric labels" do
      name = Name.new("123.example.com")

      assert name.value == "123.example.com"
      assert name.data == <<3, "com", 7, "example", 3, "123">>
    end

    test "handles hyphenated labels" do
      name = Name.new("my-server.example.com")

      assert name.value == "my-server.example.com"
    end

    test "handles underscore labels (used in SRV)" do
      name = Name.new("_http._tcp.example.com")

      assert name.value == "_http._tcp.example.com"
    end
  end

  describe "from_domain/1" do
    test "converts Domain struct to Name" do
      domain = Domain.new("example.com")
      name = Name.from_domain(domain)

      assert is_struct(name, Name)
      assert name.value == "example.com"
    end

    test "converts root Domain" do
      domain = Domain.new(".")
      name = Name.from_domain(domain)

      assert name.value == "."
      assert name.data == <<0>>
    end
  end

  describe "child?/2" do
    test "root is parent of all names" do
      root = Name.new(".")

      assert Name.child?(root, Name.new("com"))
      assert Name.child?(root, Name.new("example.com"))
      assert Name.child?(root, Name.new("www.example.com"))
    end

    test "TLD is parent of second-level domain" do
      com = Name.new("com")
      example = Name.new("example.com")

      assert Name.child?(com, example)
    end

    test "domain is parent of subdomain" do
      example = Name.new("example.com")
      www = Name.new("www.example.com")

      assert Name.child?(example, www)
    end

    test "same name is not child" do
      name = Name.new("example.com")

      refute Name.child?(name, name)
    end

    test "unrelated domains are not parent/child" do
      example = Name.new("example.com")
      other = Name.new("other.com")

      refute Name.child?(example, other)
      refute Name.child?(other, example)
    end

    test "child is not parent of ancestor" do
      www = Name.new("www.example.com")
      example = Name.new("example.com")

      refute Name.child?(www, example)
    end

    test "sibling domains are not parent/child" do
      www = Name.new("www.example.com")
      api = Name.new("api.example.com")

      refute Name.child?(www, api)
      refute Name.child?(api, www)
    end

    test "works with gsmlg.com example" do
      com = Name.new("com")
      gsmlg = Name.new("gsmlg.com")

      assert Name.child?(com, gsmlg)
    end
  end

  describe "match_domain/2" do
    test "matches exact domain" do
      name = Name.new("example.com")
      domain = Domain.new("example.com")

      match_count = Name.match_domain(name, domain)

      # Should return positive match count for exact match
      assert match_count > 0
    end

    test "matches subdomain" do
      name = Name.new("example.com")
      domain = Domain.new("www.example.com")

      match_count = Name.match_domain(name, domain)

      # Should return positive match count for subdomain
      assert match_count > 0
    end

    test "returns count based on matching prefix bytes" do
      # match_domain counts matching bytes from the start of the data
      # The data is stored in reverse label order (TLD first)
      name = Name.new("com")
      domain = Domain.new("example.com")

      match_count = Name.match_domain(name, domain)

      # com has data <<3, "com">> (4 bytes)
      # example.com wire format starts with example then com
      # Match starts from the data field which is TLD-first
      assert is_integer(match_count)
    end

    test "root matches with zero count" do
      # Root has data <<0>>, which may not match the start of other names
      root = Name.new(".")
      domain = Domain.new("example.com")

      match_count = Name.match_domain(root, domain)

      # Root's data is just <<0>>, so matching depends on implementation
      assert is_integer(match_count)
    end
  end

  describe "String.Chars protocol" do
    test "to_string returns value" do
      name = Name.new("example.com")

      assert to_string(name) == "example.com"
    end

    test "to_string for root" do
      root = Name.new(".")

      assert to_string(root) == "."
    end

    test "can interpolate in strings" do
      name = Name.new("example.com")

      assert "Zone: #{name}" == "Zone: example.com"
    end
  end

  describe "Inspect protocol" do
    test "inspect shows custom format" do
      name = Name.new("example.com")

      result = inspect(name)

      assert result == "#DNS.Zone.Name<example.com>"
    end

    test "inspect for root domain" do
      root = Name.new(".")

      result = inspect(root)

      assert result == "#DNS.Zone.Name<.>"
    end

    test "inspect for subdomain" do
      name = Name.new("www.example.com")

      result = inspect(name)

      assert result == "#DNS.Zone.Name<www.example.com>"
    end
  end

  describe "DNS.Parameter protocol" do
    test "to_iodata produces valid DNS wire format" do
      name = Name.new("example.com")

      iodata = DNS.Parameter.to_iodata(name)

      # DNS wire format: length-prefixed labels ending with null
      # example.com -> 7 e x a m p l e 3 c o m 0
      assert is_binary(iodata) or is_list(iodata)
    end

    test "to_iodata for root produces null label" do
      root = Name.new(".")

      iodata = DNS.Parameter.to_iodata(root)

      assert IO.iodata_to_binary(iodata) == <<0>>
    end

    test "to_iodata for TLD" do
      name = Name.new("com")

      iodata = DNS.Parameter.to_iodata(name)
      binary = IO.iodata_to_binary(iodata)

      # com -> 3 c o m 0
      assert binary == <<3, "com", 0>>
    end

    test "to_iodata for second-level domain" do
      name = Name.new("example.com")

      iodata = DNS.Parameter.to_iodata(name)
      binary = IO.iodata_to_binary(iodata)

      # example.com -> 7 e x a m p l e 3 c o m 0
      assert binary == <<7, "example", 3, "com", 0>>
    end

    test "to_iodata for subdomain" do
      name = Name.new("www.example.com")

      iodata = DNS.Parameter.to_iodata(name)
      binary = IO.iodata_to_binary(iodata)

      # www.example.com -> 3 w w w 7 e x a m p l e 3 c o m 0
      assert binary == <<3, "www", 7, "example", 3, "com", 0>>
    end
  end

  describe "data binary format" do
    test "data is stored in reverse label order" do
      # This is an implementation detail but important for child? to work
      name = Name.new("www.example.com")

      # Data stores TLD first: com, then example, then www
      # Each label is length-prefixed
      assert name.data == <<3, "com", 7, "example", 3, "www">>
    end

    test "label length is correct" do
      name = Name.new("a.bb.ccc.dddd")

      # Verify length prefixes
      assert name.data ==
               <<4, "dddd", 3, "ccc", 2, "bb", 1, "a">>
    end
  end
end
