defmodule YellowDog.Worker.Dns.Tls do
  @moduledoc false

  def validate(%{certs: chain, key: key}) do
    case SSL.QUIC.new(:server, cert: chain, key: key, alpn: ["doq"], transport_parameters: <<>>) do
      {:ok, _, _} -> :ok
      _ -> {:error, :invalid_dns_certificate}
    end
  end

  def otp_options(%{certs: chain, key: key}), do: [certs_keys: [%{cert: chain, key: key}]]
end
