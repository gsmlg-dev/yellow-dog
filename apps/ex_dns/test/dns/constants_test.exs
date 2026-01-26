defmodule DNS.ConstantsTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Constants module.

  Tests cover:
  - Module structure and exports
  - All constant accessor functions
  - All validation functions
  - RFC compliance for limits
  - Edge cases and boundary conditions
  - Security-related constants
  - EDNS0-related constants
  """
  use ExUnit.Case, async: true

  alias DNS.Constants

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Constants)
    end

    test "exports max_domain_length/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_domain_length, 0)
    end

    test "exports max_label_length/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_label_length, 0)
    end

    test "exports max_labels_per_name/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_labels_per_name, 0)
    end

    test "exports max_dns_message_size/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_dns_message_size, 0)
    end

    test "exports max_udp_message_size/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_udp_message_size, 0)
    end

    test "exports max_edns0_message_size/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_edns0_message_size, 0)
    end

    test "exports max_compression_depth/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_compression_depth, 0)
    end

    test "exports max_compression_pointers/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_compression_pointers, 0)
    end

    test "exports max_rdlength/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_rdlength, 0)
    end

    test "exports max_txt_string_length/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_txt_string_length, 0)
    end

    test "exports max_txt_strings/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_txt_strings, 0)
    end

    test "exports max_edns0_option_code/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_edns0_option_code, 0)
    end

    test "exports max_edns0_option_length/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_edns0_option_length, 0)
    end

    test "exports max_ttl/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :max_ttl, 0)
    end

    test "exports min_ttl/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :min_ttl, 0)
    end

    test "exports dns_port/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :dns_port, 0)
    end

    test "exports dns_over_tls_port/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :dns_over_tls_port, 0)
    end

    test "exports dns_over_https_port/0" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :dns_over_https_port, 0)
    end

    test "exports validation functions" do
      Code.ensure_loaded!(Constants)
      assert Kernel.function_exported?(Constants, :valid_domain_length?, 1)
      assert Kernel.function_exported?(Constants, :valid_label_length?, 1)
      assert Kernel.function_exported?(Constants, :valid_ttl?, 1)
      assert Kernel.function_exported?(Constants, :valid_rdlength?, 1)
      assert Kernel.function_exported?(Constants, :valid_compression_depth?, 1)
    end
  end

  describe "domain name limits (RFC 1035)" do
    test "returns correct maximum domain length" do
      assert Constants.max_domain_length() == 253
    end

    test "returns correct maximum label length" do
      assert Constants.max_label_length() == 63
    end

    test "returns correct maximum labels per name" do
      assert Constants.max_labels_per_name() == 127
    end

    test "domain length matches RFC 1035 specification" do
      # RFC 1035 Section 2.3.4: domain name max 255 octets total
      # But excluding the root label and its length byte, it's 253
      assert Constants.max_domain_length() == 253
    end

    test "label length matches RFC 1035 specification" do
      # RFC 1035 Section 2.3.4: labels limited to 63 octets
      assert Constants.max_label_length() == 63
    end

    test "labels per name is reasonable" do
      # 127 labels is RFC-compliant maximum
      assert Constants.max_labels_per_name() == 127
      # With 63-octet labels plus length bytes, 127 labels would exceed 253 bytes
      # So this is a theoretical maximum
    end
  end

  describe "DNS message size limits" do
    test "returns correct DNS message size limits" do
      assert Constants.max_dns_message_size() == 65535
      assert Constants.max_udp_message_size() == 512
    end

    test "returns correct EDNS0 message size" do
      assert Constants.max_edns0_message_size() == 65535
    end

    test "UDP message size matches RFC 1035" do
      # RFC 1035 Section 4.2.1: UDP messages limited to 512 bytes
      assert Constants.max_udp_message_size() == 512
    end

    test "max DNS message size is 16-bit limit" do
      # Maximum message size is 65535 (2^16 - 1) for TCP
      assert Constants.max_dns_message_size() == 65535
    end

    test "EDNS0 allows larger messages" do
      # EDNS0 (RFC 6891) allows advertising larger buffer sizes
      assert Constants.max_edns0_message_size() >= Constants.max_udp_message_size()
    end
  end

  describe "compression limits" do
    test "returns correct compression limits" do
      assert Constants.max_compression_depth() == 5
      assert Constants.max_compression_pointers() == 16
    end

    test "compression depth prevents DoS" do
      # Limiting compression depth prevents infinite loops from malicious packets
      assert Constants.max_compression_depth() > 0
      # Reasonable limit
      assert Constants.max_compression_depth() <= 10
    end

    test "compression pointers limit prevents attacks" do
      # Limiting pointer count prevents amplification attacks
      assert Constants.max_compression_pointers() > 0
      # Reasonable limit
      assert Constants.max_compression_pointers() <= 32
    end
  end

  describe "record data limits" do
    test "returns correct record data limits" do
      assert Constants.max_rdlength() == 8192
      assert Constants.max_txt_string_length() == 255
      assert Constants.max_txt_strings() == 16
    end

    test "TXT string length matches RFC 1035" do
      # RFC 1035 Section 3.3.14: character-string max 255 characters
      assert Constants.max_txt_string_length() == 255
    end

    test "rdlength limit prevents memory exhaustion" do
      # Limiting rdlength prevents memory exhaustion attacks
      assert Constants.max_rdlength() > 0
      # Below 16-bit max
      assert Constants.max_rdlength() < 65536
    end

    test "TXT strings limit prevents abuse" do
      # Limiting number of TXT strings prevents oversized records
      assert Constants.max_txt_strings() > 0
    end
  end

  describe "EDNS0 limits" do
    test "returns correct EDNS0 option code limit" do
      assert Constants.max_edns0_option_code() == 65535
    end

    test "returns correct EDNS0 option length limit" do
      assert Constants.max_edns0_option_length() == 65535
    end

    test "option code is 16-bit value" do
      # EDNS0 option codes are 16-bit
      assert Constants.max_edns0_option_code() == 65535
    end

    test "option length is 16-bit value" do
      # EDNS0 option lengths are 16-bit
      assert Constants.max_edns0_option_length() == 65535
    end
  end

  describe "TTL limits" do
    test "returns correct TTL limits" do
      assert Constants.max_ttl() == 2_147_483_647
      assert Constants.min_ttl() == 0
    end

    test "TTL max is signed 32-bit max" do
      # RFC 2181 Section 8: TTL is 32-bit unsigned, but should be treated as signed
      # 2^31 - 1
      assert Constants.max_ttl() == 2_147_483_647
    end

    test "TTL min is zero" do
      assert Constants.min_ttl() == 0
    end

    test "TTL range covers practical values" do
      # Common TTL values should be within range
      # 1min, 5min, 1hr, 1day, 1week
      common_ttls = [60, 300, 3600, 86400, 604_800]

      for ttl <- common_ttls do
        assert ttl >= Constants.min_ttl()
        assert ttl <= Constants.max_ttl()
      end
    end
  end

  describe "port numbers" do
    test "returns correct port numbers" do
      assert Constants.dns_port() == 53
      assert Constants.dns_over_tls_port() == 853
      assert Constants.dns_over_https_port() == 443
    end

    test "DNS port is well-known port" do
      # DNS uses well-known port 53 (RFC 1035)
      assert Constants.dns_port() == 53
    end

    test "DNS over TLS port is RFC 7858" do
      # DoT uses port 853 (RFC 7858)
      assert Constants.dns_over_tls_port() == 853
    end

    test "DNS over HTTPS uses standard HTTPS port" do
      # DoH uses standard HTTPS port 443 (RFC 8484)
      assert Constants.dns_over_https_port() == 443
    end

    test "port numbers are in valid range" do
      dns_port = Constants.dns_port()
      tls_port = Constants.dns_over_tls_port()
      https_port = Constants.dns_over_https_port()

      assert dns_port > 0 and dns_port <= 65535
      assert tls_port > 0 and tls_port <= 65535
      assert https_port > 0 and https_port <= 65535
    end

    test "DNS and DoT use privileged ports" do
      # Ports below 1024 are privileged
      assert Constants.dns_port() < 1024
      assert Constants.dns_over_tls_port() < 1024
      assert Constants.dns_over_https_port() < 1024
    end
  end

  describe "valid_domain_length?/1" do
    test "validates domain length correctly" do
      assert Constants.valid_domain_length?("example.com")
      assert Constants.valid_domain_length?("a.very.long.domain.name.that.is.still.within.limits")
    end

    test "validates maximum length domain" do
      # Maximum length domain (253 characters)
      max_length_domain = String.duplicate("a", 253)
      assert Constants.valid_domain_length?(max_length_domain)
    end

    test "rejects too long domain" do
      too_long_domain = String.duplicate("a", 254)
      refute Constants.valid_domain_length?(too_long_domain)
    end

    test "validates empty domain" do
      assert Constants.valid_domain_length?("")
    end

    test "validates single character domain" do
      assert Constants.valid_domain_length?("a")
    end

    test "validates boundary values" do
      # At exactly 253 characters
      assert Constants.valid_domain_length?(String.duplicate("a", 253))
      # One over the limit
      refute Constants.valid_domain_length?(String.duplicate("a", 254))
    end

    test "handles unicode strings" do
      # Unicode characters may take more than one byte
      unicode_domain = "例え.jp"
      assert is_boolean(Constants.valid_domain_length?(unicode_domain))
    end
  end

  describe "valid_label_length?/1" do
    test "validates label length correctly" do
      assert Constants.valid_label_length?("example")
      assert Constants.valid_label_length?(String.duplicate("a", 63))
    end

    test "rejects too long label" do
      refute Constants.valid_label_length?(String.duplicate("a", 64))
    end

    test "validates empty label" do
      assert Constants.valid_label_length?("")
    end

    test "validates single character label" do
      assert Constants.valid_label_length?("a")
    end

    test "validates boundary values" do
      # At exactly 63 characters
      assert Constants.valid_label_length?(String.duplicate("a", 63))
      # One over the limit
      refute Constants.valid_label_length?(String.duplicate("a", 64))
    end

    test "validates common labels" do
      common_labels = ["www", "mail", "ftp", "ns1", "mx", "api", "localhost"]

      for label <- common_labels do
        assert Constants.valid_label_length?(label)
      end
    end
  end

  describe "valid_compression_depth?/1" do
    test "validates compression depth correctly" do
      assert Constants.valid_compression_depth?(0)
      assert Constants.valid_compression_depth?(5)
      refute Constants.valid_compression_depth?(6)
      refute Constants.valid_compression_depth?(10)
    end

    test "validates boundary values" do
      # At exactly max depth
      assert Constants.valid_compression_depth?(Constants.max_compression_depth())
      # One over the limit
      refute Constants.valid_compression_depth?(Constants.max_compression_depth() + 1)
    end

    test "validates all values up to max" do
      max_depth = Constants.max_compression_depth()

      for depth <- 0..max_depth do
        assert Constants.valid_compression_depth?(depth)
      end
    end

    test "rejects values beyond max" do
      max_depth = Constants.max_compression_depth()

      for depth <- (max_depth + 1)..(max_depth + 5) do
        refute Constants.valid_compression_depth?(depth)
      end
    end
  end

  describe "valid_ttl?/1" do
    test "validates TTL range correctly" do
      assert Constants.valid_ttl?(0)
      assert Constants.valid_ttl?(1)
      assert Constants.valid_ttl?(3600)
      assert Constants.valid_ttl?(86400)
      assert Constants.valid_ttl?(Constants.max_ttl())

      refute Constants.valid_ttl?(-1)
      refute Constants.valid_ttl?(Constants.max_ttl() + 1)
    end

    test "validates common TTL values" do
      common_ttls = [
        # zero TTL
        0,
        # 1 minute
        60,
        # 5 minutes
        300,
        # 1 hour
        3600,
        # 2 hours
        7200,
        # 1 day
        86400,
        # 1 week
        604_800,
        # 30 days
        2_592_000
      ]

      for ttl <- common_ttls do
        assert Constants.valid_ttl?(ttl)
      end
    end

    test "validates boundary values" do
      # Minimum TTL
      assert Constants.valid_ttl?(Constants.min_ttl())
      # Maximum TTL
      assert Constants.valid_ttl?(Constants.max_ttl())
      # Beyond maximum
      refute Constants.valid_ttl?(Constants.max_ttl() + 1)
    end

    test "rejects negative TTL" do
      refute Constants.valid_ttl?(-1)
      refute Constants.valid_ttl?(-100)
      refute Constants.valid_ttl?(-1_000_000)
    end
  end

  describe "valid_rdlength?/1" do
    test "validates rdlength correctly" do
      assert Constants.valid_rdlength?(0)
      assert Constants.valid_rdlength?(1)
      assert Constants.valid_rdlength?(1000)
      assert Constants.valid_rdlength?(Constants.max_rdlength())
    end

    test "rejects oversized rdlength" do
      refute Constants.valid_rdlength?(Constants.max_rdlength() + 1)
    end

    test "validates common record sizes" do
      common_sizes = [
        # A record (IPv4)
        4,
        # AAAA record (IPv6)
        16,
        # Small TXT record
        64,
        # Max single TXT string
        255,
        # Large record
        1000,
        # Very large record (still within limit)
        4096
      ]

      for size <- common_sizes do
        assert Constants.valid_rdlength?(size)
      end
    end

    test "validates boundary values" do
      assert Constants.valid_rdlength?(0)
      assert Constants.valid_rdlength?(Constants.max_rdlength())
      refute Constants.valid_rdlength?(Constants.max_rdlength() + 1)
    end
  end

  describe "constants consistency" do
    test "constants are reasonable values" do
      # Basic sanity checks
      assert Constants.max_domain_length() > Constants.max_label_length()
      assert Constants.max_dns_message_size() > Constants.max_udp_message_size()
      assert Constants.max_ttl() > Constants.min_ttl()
      assert Constants.max_rdlength() > 0
      assert Constants.max_compression_depth() > 0
    end

    test "EDNS0 allows larger than standard UDP" do
      assert Constants.max_edns0_message_size() >= Constants.max_udp_message_size()
    end

    test "all limits are positive" do
      assert Constants.max_domain_length() > 0
      assert Constants.max_label_length() > 0
      assert Constants.max_labels_per_name() > 0
      assert Constants.max_dns_message_size() > 0
      assert Constants.max_udp_message_size() > 0
      assert Constants.max_compression_depth() > 0
      assert Constants.max_compression_pointers() > 0
      assert Constants.max_rdlength() > 0
      assert Constants.max_txt_string_length() > 0
      assert Constants.max_txt_strings() > 0
    end

    test "port numbers are distinct" do
      dns_port = Constants.dns_port()
      tls_port = Constants.dns_over_tls_port()
      https_port = Constants.dns_over_https_port()

      assert dns_port != tls_port
      assert dns_port != https_port
      # DoT and DoH use different ports
      assert tls_port != https_port
    end
  end

  describe "edge cases" do
    test "handles boundary conditions for domain" do
      assert Constants.valid_domain_length?(String.duplicate("a", 253))
      refute Constants.valid_domain_length?(String.duplicate("a", 254))
    end

    test "handles boundary conditions for label" do
      assert Constants.valid_label_length?(String.duplicate("a", 63))
      refute Constants.valid_label_length?(String.duplicate("a", 64))
    end

    test "handles boundary conditions for rdlength" do
      assert Constants.valid_rdlength?(Constants.max_rdlength())
      refute Constants.valid_rdlength?(Constants.max_rdlength() + 1)
    end

    test "handles empty strings" do
      assert Constants.valid_domain_length?("")
      assert Constants.valid_label_length?("")
    end

    test "handles zero values" do
      assert Constants.valid_rdlength?(0)
      assert Constants.valid_ttl?(0)
      assert Constants.valid_compression_depth?(0)
    end
  end

  describe "real-world domain validation" do
    test "validates common domain names" do
      common_domains = [
        "google.com",
        "www.example.org",
        "mail.server.example.com",
        "api.v1.service.cloud.example.net",
        "a.b.c.d.e.f.g.h.i.j.example.com"
      ]

      for domain <- common_domains do
        assert Constants.valid_domain_length?(domain)
        # Also check all labels
        labels = String.split(domain, ".")

        for label <- labels do
          assert Constants.valid_label_length?(label)
        end
      end
    end

    test "validates internationalized domain names" do
      # IDN examples (ASCII-compatible encoding)
      idn_domains = [
        # example.com in Greek
        "xn--nxasmq5b.com",
        # Russian domain
        "xn--e1afmkfd.xn--p1ai"
      ]

      for domain <- idn_domains do
        assert Constants.valid_domain_length?(domain)
      end
    end

    test "validates edge case domains" do
      # Single label
      assert Constants.valid_domain_length?("localhost")
      # Root zone
      assert Constants.valid_domain_length?("")
      # Maximum depth (many short labels)
      deep_domain = Enum.map_join(1..50, ".", fn _ -> "a" end)
      assert Constants.valid_domain_length?(deep_domain)
    end
  end

  describe "security limits" do
    test "compression depth prevents loop attacks" do
      # Malicious packets can create compression loops
      # Limited depth prevents infinite loops
      max_depth = Constants.max_compression_depth()
      # Reasonable limit
      assert max_depth <= 10
      # Must allow some compression
      assert max_depth >= 1
    end

    test "rdlength prevents memory exhaustion" do
      # Malicious packets can claim huge rdlength
      max_rdlength = Constants.max_rdlength()
      # Less than max 16-bit value
      assert max_rdlength < 65536
    end

    test "UDP size prevents amplification attacks" do
      # Standard UDP size limits response size
      udp_size = Constants.max_udp_message_size()
      # RFC 1035 limit
      assert udp_size == 512
    end
  end

  describe "constants return types" do
    test "all constants return non-negative integers" do
      assert is_integer(Constants.max_domain_length()) and Constants.max_domain_length() >= 0
      assert is_integer(Constants.max_label_length()) and Constants.max_label_length() >= 0
      assert is_integer(Constants.max_labels_per_name()) and Constants.max_labels_per_name() >= 0

      assert is_integer(Constants.max_dns_message_size()) and
               Constants.max_dns_message_size() >= 0

      assert is_integer(Constants.max_udp_message_size()) and
               Constants.max_udp_message_size() >= 0

      assert is_integer(Constants.max_edns0_message_size()) and
               Constants.max_edns0_message_size() >= 0

      assert is_integer(Constants.max_compression_depth()) and
               Constants.max_compression_depth() >= 0

      assert is_integer(Constants.max_compression_pointers()) and
               Constants.max_compression_pointers() >= 0

      assert is_integer(Constants.max_rdlength()) and Constants.max_rdlength() >= 0

      assert is_integer(Constants.max_txt_string_length()) and
               Constants.max_txt_string_length() >= 0

      assert is_integer(Constants.max_txt_strings()) and Constants.max_txt_strings() >= 0

      assert is_integer(Constants.max_edns0_option_code()) and
               Constants.max_edns0_option_code() >= 0

      assert is_integer(Constants.max_edns0_option_length()) and
               Constants.max_edns0_option_length() >= 0

      assert is_integer(Constants.max_ttl()) and Constants.max_ttl() >= 0
      assert is_integer(Constants.min_ttl()) and Constants.min_ttl() >= 0
      assert is_integer(Constants.dns_port()) and Constants.dns_port() >= 0
      assert is_integer(Constants.dns_over_tls_port()) and Constants.dns_over_tls_port() >= 0
      assert is_integer(Constants.dns_over_https_port()) and Constants.dns_over_https_port() >= 0
    end

    test "validation functions return booleans" do
      assert is_boolean(Constants.valid_domain_length?("test"))
      assert is_boolean(Constants.valid_label_length?("test"))
      assert is_boolean(Constants.valid_ttl?(3600))
      assert is_boolean(Constants.valid_rdlength?(100))
      assert is_boolean(Constants.valid_compression_depth?(3))
    end
  end

  describe "RFC compliance" do
    test "RFC 1035 domain limits" do
      # Section 2.3.4: 63 octets per label, 255 total with length octets
      assert Constants.max_label_length() == 63
      # 255 - 2 (root label byte and trailing dot)
      assert Constants.max_domain_length() == 253
    end

    test "RFC 1035 message size" do
      # Section 4.2.1: UDP message max 512 bytes
      assert Constants.max_udp_message_size() == 512
    end

    test "RFC 2181 TTL limits" do
      # Section 8: TTL is 31-bit positive integer
      # 2^31 - 1
      assert Constants.max_ttl() == 2_147_483_647
      assert Constants.min_ttl() == 0
    end

    test "RFC 1035 TXT string limits" do
      # Section 3.3.14: character-string max 255 characters
      assert Constants.max_txt_string_length() == 255
    end
  end
end
