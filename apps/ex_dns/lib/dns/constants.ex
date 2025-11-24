defmodule DNS.Constants do
  @moduledoc """
  DNS protocol constants and limits.

  This module centralizes all DNS protocol constants, limits, and magic numbers
  to improve maintainability and prevent hardcoded values throughout the codebase.
  """

  # Domain name limits (RFC 1035)
  @max_domain_length 253
  @max_label_length 63
  @max_labels_per_name 127

  # DNS message limits (RFC 1035)
  @max_dns_message_size 65535
  @max_udp_message_size 512
  @max_edns0_message_size 65535

  # DNS compression limits
  @max_compression_depth 5
  @max_compression_pointers 16

  # Record data limits
  @max_rdlength 8192
  @max_txt_string_length 255
  @max_txt_strings 16

  # EDNS0 limits
  @max_edns0_option_code 65535
  @max_edns0_option_length 65535

  # TTL limits
  @max_ttl 2_147_483_647
  @min_ttl 0

  # Common port numbers
  @dns_port 53
  @dns_over_tls_port 853
  @dns_over_https_port 443

  @doc """
  Maximum domain name length in octets (excluding the trailing root label).
  """
  @spec max_domain_length() :: non_neg_integer()
  def max_domain_length, do: @max_domain_length

  @doc """
  Maximum label length in octets.
  """
  @spec max_label_length() :: non_neg_integer()
  def max_label_length, do: @max_label_length

  @doc """
  Maximum number of labels in a domain name.
  """
  @spec max_labels_per_name() :: non_neg_integer()
  def max_labels_per_name, do: @max_labels_per_name

  @doc """
  Maximum DNS message size in octets.
  """
  @spec max_dns_message_size() :: non_neg_integer()
  def max_dns_message_size, do: @max_dns_message_size

  @doc """
  Maximum DNS message size for UDP transport without EDNS0.
  """
  @spec max_udp_message_size() :: non_neg_integer()
  def max_udp_message_size, do: @max_udp_message_size

  @doc """
  Maximum DNS message size with EDNS0.
  """
  @spec max_edns0_message_size() :: non_neg_integer()
  def max_edns0_message_size, do: @max_edns0_message_size

  @doc """
  Maximum compression recursion depth to prevent DoS attacks.
  """
  @spec max_compression_depth() :: non_neg_integer()
  def max_compression_depth, do: @max_compression_depth

  @doc """
  Maximum number of compression pointers to follow.
  """
  @spec max_compression_pointers() :: non_neg_integer()
  def max_compression_pointers, do: @max_compression_pointers

  @doc """
  Maximum RDLENGTH value to prevent memory exhaustion attacks.
  """
  @spec max_rdlength() :: non_neg_integer()
  def max_rdlength, do: @max_rdlength

  @doc """
  Maximum length of a single TXT string.
  """
  @spec max_txt_string_length() :: non_neg_integer()
  def max_txt_string_length, do: @max_txt_string_length

  @doc """
  Maximum number of TXT strings in a TXT record.
  """
  @spec max_txt_strings() :: non_neg_integer()
  def max_txt_strings, do: @max_txt_strings

  @doc """
  Maximum EDNS0 option code.
  """
  @spec max_edns0_option_code() :: non_neg_integer()
  def max_edns0_option_code, do: @max_edns0_option_code

  @doc """
  Maximum EDNS0 option data length.
  """
  @spec max_edns0_option_length() :: non_neg_integer()
  def max_edns0_option_length, do: @max_edns0_option_length

  @doc """
  Maximum TTL value.
  """
  @spec max_ttl() :: non_neg_integer()
  def max_ttl, do: @max_ttl

  @doc """
  Minimum TTL value.
  """
  @spec min_ttl() :: non_neg_integer()
  def min_ttl, do: @min_ttl

  @doc """
  Standard DNS port number.
  """
  @spec dns_port() :: non_neg_integer()
  def dns_port, do: @dns_port

  @doc """
  DNS over TLS port number.
  """
  @spec dns_over_tls_port() :: non_neg_integer()
  def dns_over_tls_port, do: @dns_over_tls_port

  @doc """
  DNS over HTTPS port number.
  """
  @spec dns_over_https_port() :: non_neg_integer()
  def dns_over_https_port, do: @dns_over_https_port

  @doc """
  Validate that a domain name is within length limits.
  """
  @spec valid_domain_length?(binary()) :: boolean()
  def valid_domain_length?(domain) when is_binary(domain) do
    byte_size(domain) <= @max_domain_length
  end

  @doc """
  Validate that a label is within length limits.
  """
  @spec valid_label_length?(binary()) :: boolean()
  def valid_label_length?(label) when is_binary(label) do
    byte_size(label) <= @max_label_length
  end

  @doc """
  Validate that a TTL is within acceptable range.
  """
  @spec valid_ttl?(non_neg_integer()) :: boolean()
  def valid_ttl?(ttl) when is_integer(ttl) do
    ttl >= @min_ttl and ttl <= @max_ttl
  end

  @doc """
  Validate that an RDLENGTH value is within security limits.
  """
  @spec valid_rdlength?(non_neg_integer()) :: boolean()
  def valid_rdlength?(rdlength) when is_integer(rdlength) do
    rdlength <= @max_rdlength
  end

  @doc """
  Validate that compression depth is within security limits.
  """
  @spec valid_compression_depth?(non_neg_integer()) :: boolean()
  def valid_compression_depth?(depth) when is_integer(depth) do
    depth <= @max_compression_depth
  end
end
