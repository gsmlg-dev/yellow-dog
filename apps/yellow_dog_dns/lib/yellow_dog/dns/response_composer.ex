defmodule YellowDog.Dns.ResponseComposer do
  @moduledoc """
  Composes DNS responses before the view returns them to the client.

  The composer keeps cross-cutting response adjustments out of individual zone
  processes. Today it completes CNAME answers with recursive target records when
  recursion is available for the view and requested by the client.
  """

  alias DNS.Message
  alias DNS.Message.Question

  @type cname_resolver ::
          (Message.t() -> {:ok, Message.t()} | {:error, atom()} | :error)

  @doc """
  Composes a DNS response for a query.

  Options:

  - `:recursion_enabled` - whether this view may recurse
  - `:resolve_cname_target` - one-arity function that resolves the generated
    target query for an unresolved CNAME answer
  """
  @spec compose(Message.t(), Message.t(), keyword()) :: Message.t()
  def compose(%Message{} = query, %Message{} = response, opts \\ []) do
    with true <- Keyword.get(opts, :recursion_enabled, false),
         true <- recursion_desired?(query),
         {:ok, question} <- first_question(query),
         false <- question_type?(question, "CNAME"),
         {:ok, target_name} <- unresolved_cname_target(response, question),
         {:ok, resolver} <- cname_resolver(opts),
         target_query <- cname_target_query(query, question, target_name),
         {:ok, recursive_response} <- resolver.(target_query) do
      merge_cname_response(response, recursive_response)
    else
      _ -> response
    end
  end

  defp first_question(%Message{qdlist: [question | _]}), do: {:ok, question}
  defp first_question(_query), do: :error

  defp recursion_desired?(%Message{header: %{rd: rd}}), do: rd in [1, true]
  defp recursion_desired?(_query), do: false

  defp question_type?(question, type), do: question_type(question) == type

  defp question_type(%Question{type: type}), do: to_string(type)
  defp question_type(%{type: type}), do: type |> to_string() |> String.upcase()

  defp unresolved_cname_target(%Message{anlist: answers}, question) do
    qtype = question_type(question)

    has_requested_type? =
      Enum.any?(answers, fn answer ->
        record_type(answer) == qtype
      end)

    if has_requested_type? do
      :error
    else
      answers
      |> Enum.filter(&(record_type(&1) == "CNAME"))
      |> List.last()
      |> cname_target()
      |> case do
        nil -> :error
        target -> {:ok, target}
      end
    end
  end

  defp record_type(%DNS.Message.Record{type: type}), do: to_string(type)
  defp record_type(%{type: type}), do: type |> to_string() |> String.upcase()

  defp cname_target(nil), do: nil

  defp cname_target(%DNS.Message.Record{data: data}) do
    data
    |> to_string()
    |> normalize_name()
  end

  defp cname_target(%{rdata: target}) when is_binary(target), do: normalize_name(target)
  defp cname_target(%{"rdata" => target}) when is_binary(target), do: normalize_name(target)
  defp cname_target(_record), do: nil

  defp cname_resolver(opts) do
    case Keyword.get(opts, :resolve_cname_target) do
      resolver when is_function(resolver, 1) -> {:ok, resolver}
      _other -> :error
    end
  end

  defp cname_target_query(%Message{} = query, %Question{} = question, target_name) do
    %{query | qdlist: [%{question | name: DNS.Message.Domain.new(target_name)}]}
  end

  defp cname_target_query(%Message{} = query, %{name: _name} = question, target_name) do
    %{query | qdlist: [%{question | name: target_name}]}
  end

  defp merge_cname_response(response, recursive_response) do
    answers = response.anlist ++ recursive_response.anlist

    %{
      response
      | header: %{
          response.header
          | ancount: length(answers),
            nscount: 0,
            arcount: length(recursive_response.arlist)
        },
        anlist: answers,
        nslist: [],
        arlist: recursive_response.arlist
    }
  end

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.trim_trailing(".")
  end
end
