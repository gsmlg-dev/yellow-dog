defmodule YellowDog.Forwarder do
  @moduledoc """
  Forwarder module for dns
  """

  require Logger

  import YellowDog.Utils

  alias YellowDog.DNS.Message
  alias YellowDog.DNS.Message.EDNS0
  alias YellowDog.DNS.Message.RCode
  alias YellowDog.DNS.ResourceRecord.Type, as: RType
  alias YellowDog.DNS.Class, as: QClass

  def config() do
    YellowDog.Config.config("forwarder")
  end

  def config(name) do
    case {config(), name} do
      {nil, "server"} ->
        {{8, 8, 8, 8}, 53}

      {nil, "override-ecs"} ->
        false

      {%{"server" => server}, "server"} when is_binary(server) ->
        [addr | rest] = server |> String.split("#")
        ip = addr |> String.to_charlist() |> :inet.parse_address() |> elem(1)
        port = if length(rest) == 1, do: String.to_integer(List.first(rest)), else: 53
        {ip, port}

      {%{"server" => server_list}, "server"} when is_list(server_list) ->
        server = List.first(server_list)
        [addr | rest] = server |> String.split("#")
        ip = addr |> String.to_charlist() |> :inet.parse_address() |> elem(1)
        port = if length(rest) == 1, do: String.to_integer(List.first(rest)), else: 53
        {ip, port}

      {%{"override-ecs" => override}, "override-ecs"} ->
        override

      {%{"ecs-addr" => ecs_addr, "ecs-prefix" => ecs_prefix}, "ecs"} ->
        {ecs_addr |> String.to_charlist() |> :inet.parse_address() |> elem(1), ecs_prefix, 0}
    end
  end

  def resolve(%Message{} = message, _protocol, _client, _port) do
    Logger.debug(Message.to_print(message))

    edns0 =
      if config("override-ecs") do
        message |> Message.edns0_or_new() |> EDNS0.add_option(8, config("ecs"))
      else
        message |> Message.edns0()
      end

    message =
      message |> Message.set_edns0(edns0)

    ns_server = config("server")

    resp_message =
      message
      |> forward_to(ns_server)

    Logger.debug(resp_message |> Message.from_buffer() |> Message.to_print())

    {:ok, resp_message}
  end

  def forward_to_google_dns(message) do
    forward_to(message, {{8, 8, 8, 8}, 53})
  end

  def forward_to(message, {addr, port}) do
    Logger.debug("forwarder to #{a2s(addr)}##{port}")

    with {:ok, socket} <- :gen_tcp.connect(addr, port, active: false),
         buffer <- YellowDog.DNS.Message.to_buffer(message),
         :ok <- :gen_tcp.send(socket, <<byte_size(buffer)::16, buffer::binary>>),
         {:ok, [a, b]} <- :gen_tcp.recv(socket, 2),
         length <- Bitwise.<<<(a, 8) |> Bitwise.bor(b),
         {:ok, data} <- :gen_tcp.recv(socket, length),
         resp_msg <- for(byte <- data, into: <<>>, do: <<byte::8>>) do
      Logger.debug(
        "forwarder #{a2s(addr)}##{port} awnser #{inspect(resp_msg, limit: :infinity)} "
      )

      resp_msg
    else
      e ->
        Logger.error("serv_fail at forward to #{a2s(addr)}##{port} #{inspect(e)}")

        message
        |> YellowDog.DNS.Message.update_header_attr(:qr, 1)
        |> YellowDog.DNS.Message.update_header_attr(:rcode, RCode.serv_fail())
        |> YellowDog.DNS.Message.to_buffer()
    end
  end
end
