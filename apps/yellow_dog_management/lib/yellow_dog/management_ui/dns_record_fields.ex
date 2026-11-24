defmodule YellowDog.ManagementUI.DnsRecordFields do
  @moduledoc false

  @integer_fields ~w(serial refresh retry expire minimum preference)

  def defaults("SOA"),
    do: %{
      "mname" => "",
      "rname" => "",
      "serial" => 1,
      "refresh" => 3600,
      "retry" => 600,
      "expire" => 86400,
      "minimum" => 300
    }

  def defaults("NS"), do: %{"host" => ""}
  def defaults(type) when type in ~w(A AAAA), do: %{"address" => ""}
  def defaults(type) when type in ~w(CNAME PTR), do: %{"target" => ""}
  def defaults("MX"), do: %{"preference" => 10, "exchange" => ""}
  def defaults("TXT"), do: %{"strings" => "[\"\"]"}
  def defaults(_type), do: %{}

  def keys("SOA"), do: ~w(mname rname serial refresh retry expire minimum)
  def keys("MX"), do: ~w(preference exchange)
  def keys(type), do: Map.keys(defaults(type))

  def integer_field?(field), do: field in @integer_fields

  def input_value("strings", strings) when is_list(strings), do: Jason.encode!(strings)
  def input_value(_field, value) when is_binary(value) or is_integer(value), do: value
  def input_value(_field, _value), do: nil

  def normalize(data) do
    Map.new(data, fn
      {"strings", value} when is_binary(value) ->
        case Jason.decode(value) do
          {:ok, strings} when is_list(strings) -> {"strings", strings}
          _ -> {"strings", value}
        end

      {field, value} when field in @integer_fields and is_binary(value) ->
        case Integer.parse(value) do
          {number, ""} -> {field, number}
          _ -> {field, value}
        end

      entry ->
        entry
    end)
  end
end
