defmodule DNS.Message.Record.Data.SVCB do
  @moduledoc """
  DNS SVCB Record (Type 64)

  The SVCB (Service Binding) record provides a way to publish information about
  alternative endpoints and parameters for a service, primarily for HTTPS.

  RFC 9460 defines the SVCB record format:
  - SvcPriority: 2 octets
  - TargetName: domain name
  - SvcParams: variable length
  """
  alias DNS.Message.Domain
  alias DNS.ResourceRecordType, as: RRType

  @type t :: %__MODULE__{
          type: RRType.t(),
          rdlength: 0..65535,
          raw: bitstring(),
          data: {
            svc_priority :: 0..65535,
            target_name :: Domain.t(),
            svc_params :: binary()
          }
        }

  defstruct raw: nil, type: RRType.new(64), rdlength: nil, data: nil

  @spec new({integer(), Domain.t(), binary()}) :: t()
  def new({svc_priority, target_name, svc_params}) do
    target_name_binary = DNS.to_iodata(target_name)

    raw = <<
      svc_priority::16,
      target_name_binary::binary,
      svc_params::binary
    >>

    %__MODULE__{
      raw: raw,
      data: {svc_priority, target_name, svc_params},
      rdlength: byte_size(raw)
    }
  end

  @spec from_iodata(bitstring(), bitstring() | nil) :: t()
  def from_iodata(raw, message \\ nil) do
    <<
      svc_priority::16,
      rest::binary
    >> = raw

    target_name = Domain.from_iodata(rest, message)
    target_name_size = target_name.size
    svc_params = binary_part(rest, target_name_size, byte_size(rest) - target_name_size)

    %__MODULE__{
      raw: raw,
      data: {svc_priority, target_name, svc_params},
      rdlength: byte_size(raw)
    }
  end

  defimpl DNS.Parameter, for: DNS.Message.Record.Data.SVCB do
    @impl true
    def to_iodata(%DNS.Message.Record.Data.SVCB{data: data}) do
      {svc_priority, target_name, svc_params} = data

      target_name_binary = DNS.to_iodata(target_name)
      size = 2 + byte_size(target_name_binary) + byte_size(svc_params)

      <<
        size::16,
        svc_priority::16,
        target_name_binary::binary,
        svc_params::binary
      >>
    end
  end

  defimpl String.Chars, for: DNS.Message.Record.Data.SVCB do
    def to_string(%DNS.Message.Record.Data.SVCB{data: data}) do
      {svc_priority, target_name, svc_params} = data

      if byte_size(svc_params) == 0 do
        "#{svc_priority} #{target_name} "
      else
        "#{svc_priority} #{target_name} #{parse_svc_params(svc_params)}"
      end
    end

    defp parse_svc_params(<<>>), do: ""

    defp parse_svc_params(svc_params) when is_binary(svc_params) do
      case parse_svc_params_binary(svc_params, []) do
        [] -> ""
        params -> Enum.join(params, " ")
      end
    end

    defp parse_svc_params_binary(<<>>, acc), do: Enum.reverse(acc)

    defp parse_svc_params_binary(
           <<key::16, value_length::16, value::binary-size(value_length), rest::binary>>,
           acc
         ) do
      param_name = svc_param_key_to_string(key)
      param_value = format_svc_param_value(key, value)
      parse_svc_params_binary(rest, ["#{param_name}=#{param_value}" | acc])
    end

    defp parse_svc_params_binary(<<key::16>>, acc) do
      param_name = svc_param_key_to_string(key)
      parse_svc_params_binary(<<>>, [param_name | acc])
    end

    defp parse_svc_params_binary(_, acc), do: Enum.reverse(acc)

    defp svc_param_key_to_string(key) do
      case key do
        1 -> "alpn"
        2 -> "no-default-alpn"
        3 -> "port"
        4 -> "ipv4hint"
        5 -> "ech"
        6 -> "ipv6hint"
        7 -> "odoh"
        _ -> "key#{key}"
      end
    end

    defp format_svc_param_value(key, value) do
      case key do
        1 -> parse_alpn_list(value)
        3 -> inspect(:binary.decode_unsigned(value))
        4 -> parse_ip_list(value, 4)
        6 -> parse_ip_list(value, 16)
        _ -> Base.encode16(value, case: :lower)
      end
    end

    defp parse_alpn_list(value) do
      parse_alpn_list(value, [])
    end

    defp parse_alpn_list(<<>>, acc), do: Enum.join(Enum.reverse(acc), ",")

    defp parse_alpn_list(<<len::8, alpn::binary-size(len), rest::binary>>, acc) do
      parse_alpn_list(rest, [alpn | acc])
    end

    defp parse_alpn_list(_, acc), do: Enum.join(Enum.reverse(acc), ",")

    defp parse_ip_list(ip_list, ip_size) do
      case ip_list do
        <<>> ->
          ""

        <<ip_value::binary-size(ip_size), rest::binary>> ->
          ip_string = format_ip(ip_value, ip_size)

          case rest do
            <<>> -> ip_string
            _ -> ip_string <> "," <> parse_ip_list(rest, ip_size)
          end

        _ ->
          ""
      end
    end

    defp format_ip(ip, 4) do
      <<a, b, c, d>> = ip
      "#{a}.#{b}.#{c}.#{d}"
    end

    defp format_ip(ip, 16) do
      <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = ip
      "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
    end
  end
end
