defmodule DNS.ConstantsTest do
  use ExUnit.Case

  alias DNS.Constants

  describe "DNS limits and constants" do
    test "returns correct maximum domain length" do
      assert Constants.max_domain_length() == 253
    end

    test "returns correct maximum label length" do
      assert Constants.max_label_length() == 63
    end

    test "returns correct maximum labels per name" do
      assert Constants.max_labels_per_name() == 127
    end

    test "returns correct DNS message size limits" do
      assert Constants.max_dns_message_size() == 65535
      assert Constants.max_udp_message_size() == 512
    end

    test "returns correct compression limits" do
      assert Constants.max_compression_depth() == 5
      assert Constants.max_compression_pointers() == 16
    end

    test "returns correct record data limits" do
      assert Constants.max_rdlength() == 8192
      assert Constants.max_txt_string_length() == 255
      assert Constants.max_txt_strings() == 16
    end

    test "returns correct TTL limits" do
      assert Constants.max_ttl() == 2_147_483_647
      assert Constants.min_ttl() == 0
    end

    test "returns correct port numbers" do
      assert Constants.dns_port() == 53
      assert Constants.dns_over_tls_port() == 853
      assert Constants.dns_over_https_port() == 443
    end
  end

  describe "Domain validation functions" do
    test "validates domain length correctly" do
      assert Constants.valid_domain_length?("example.com")
      assert Constants.valid_domain_length?("a.very.long.domain.name.that.is.still.within.limits")

      # Maximum length domain (254 characters with dot, 253 without)
      max_length_domain = String.duplicate("a", 249) <> ".com"
      assert byte_size(max_length_domain) <= Constants.max_domain_length()

      # Too long
      too_long_domain = String.duplicate("a", 254)
      refute Constants.valid_domain_length?(too_long_domain)
    end

    test "validates label length correctly" do
      assert Constants.valid_label_length?("example")
      assert Constants.valid_label_length?(String.duplicate("a", 63))

      # Too long
      refute Constants.valid_label_length?(String.duplicate("a", 64))
    end

    test "validates compression depth correctly" do
      assert Constants.valid_compression_depth?(0)
      assert Constants.valid_compression_depth?(5)
      refute Constants.valid_compression_depth?(6)
      refute Constants.valid_compression_depth?(10)
    end
  end

  describe "TTL validation functions" do
    test "validates TTL range correctly" do
      assert Constants.valid_ttl?(0)
      assert Constants.valid_ttl?(1)
      assert Constants.valid_ttl?(3600)
      assert Constants.valid_ttl?(86400)
      assert Constants.valid_ttl?(Constants.max_ttl())

      refute Constants.valid_ttl?(-1)
      refute Constants.valid_ttl?(Constants.max_ttl() + 1)
    end
  end

  describe "Record length validation functions" do
    test "validates rdlength correctly" do
      assert Constants.valid_rdlength?(0)
      assert Constants.valid_rdlength?(1)
      assert Constants.valid_rdlength?(1000)
      assert Constants.valid_rdlength?(Constants.max_rdlength())

      # Negative values should be handled by the function - check implementation
      # The function uses is_integer/1 check, so let's test that behavior
      refute Constants.valid_rdlength?(Constants.max_rdlength() + 1)
    end
  end

  describe "Constants consistency" do
    test "constants are reasonable values" do
      # Basic sanity checks
      assert Constants.max_domain_length() > Constants.max_label_length()
      assert Constants.max_dns_message_size() > Constants.max_udp_message_size()
      assert Constants.max_ttl() > Constants.min_ttl()
      assert Constants.max_rdlength() > 0
      assert Constants.max_compression_depth() > 0
    end

    test "port numbers are in valid range" do
      dns_port = Constants.dns_port()
      tls_port = Constants.dns_over_tls_port()
      https_port = Constants.dns_over_https_port()

      assert dns_port > 0 and dns_port <= 65535
      assert tls_port > 0 and tls_port <= 65535
      assert https_port > 0 and https_port <= 65535
    end
  end

  describe "Edge cases" do
    test "handles boundary conditions" do
      # Test exact boundary values
      assert Constants.valid_domain_length?(String.duplicate("a", 253))
      refute Constants.valid_domain_length?(String.duplicate("a", 254))

      assert Constants.valid_label_length?(String.duplicate("a", 63))
      refute Constants.valid_label_length?(String.duplicate("a", 64))

      assert Constants.valid_rdlength?(Constants.max_rdlength())
      refute Constants.valid_rdlength?(Constants.max_rdlength() + 1)
    end

    test "handles empty strings and edge inputs" do
      assert Constants.valid_domain_length?("")
      assert Constants.valid_label_length?("")
      assert Constants.valid_rdlength?(0)
      assert Constants.valid_ttl?(0)
    end
  end
end
