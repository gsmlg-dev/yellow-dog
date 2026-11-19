defmodule YellowDog.DnsProvider.HTTPClient do
  @moduledoc false

  defstruct [:base_url, headers: [], timeout: 15_000]

  def new(base_url, headers \\ [], timeout \\ 15_000) do
    %__MODULE__{base_url: base_url, headers: headers, timeout: timeout}
  end

  def request(client, method, path, options \\ []) do
    url = client.base_url <> path
    uri = URI.parse(url)
    query = Keyword.get(options, :query, [])
    uri = if query == [], do: uri, else: %{uri | query: URI.encode_query(query)}

    {headers, body} =
      case Keyword.fetch(options, :json) do
        {:ok, value} ->
          {[{"content-type", "application/json"} | client.headers], Jason.encode!(value)}

        :error ->
          {client.headers, Keyword.get(options, :body)}
      end

    uri
    |> HTTP.fetch(
      method: method,
      headers: headers,
      body: body,
      timeout: client.timeout,
      redirect: Keyword.get(options, :redirect, :error)
    )
    |> HTTP.Promise.await(client.timeout + 1_000)
    |> decode_response()
  end

  defp decode_response(%HTTP.Response{} = response) do
    decode_body(response, HTTP.Response.text(response))
  rescue
    error in HTTP.ResponseError -> {:error, error.reason}
  end

  defp decode_response({:error, reason}), do: {:error, reason}

  defp decode_body(response, body) do
    {media_type, _} = HTTP.Response.content_type(response)

    if body != "" and
         (media_type == "application/json" or String.ends_with?(media_type, "+json")) do
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, %{status: response.status, body: decoded}}
        {:error, reason} -> {:error, {:invalid_json, reason}}
      end
    else
      {:ok, %{status: response.status, body: body}}
    end
  end
end
