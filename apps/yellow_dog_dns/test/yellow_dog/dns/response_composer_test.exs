defmodule YellowDog.Dns.ResponseComposerTest do
  use ExUnit.Case, async: true

  alias DNS.Message
  alias DNS.Message.Question
  alias DNS.Message.RCode
  alias DNS.Message.Record
  alias YellowDog.Dns.ResponseComposer

  test "completes CNAME answer with recursive target records when recursion is enabled" do
    query = build_query("alias.example.test", :a)

    cname_response =
      build_response(query, [
        Record.new("alias.example.test", :cname, :in, 300, "target.external.test")
      ])

    composed =
      ResponseComposer.compose(query, cname_response,
        recursion_enabled: true,
        resolve_cname_target: fn target_query ->
          assert [%Question{} = target_question] = target_query.qdlist
          assert normalize_name(target_question.name) == "target.external.test"
          assert to_string(target_question.type) == "A"

          {:ok,
           build_response(target_query, [
             Record.new("target.external.test", :a, :in, 120, {203, 0, 113, 7})
           ])}
        end
      )

    assert [cname, address] = composed.anlist
    assert normalize_name(cname.name) == "alias.example.test"
    assert to_string(cname.type) == "CNAME"
    assert normalize_name(address.name) == "target.external.test"
    assert to_string(address.type) == "A"
    assert composed.header.ancount == 2
  end

  defp build_query(name, type) do
    query = Message.new()
    question = Question.new(name, type, :in)
    header = %{query.header | id: 10_001, qdcount: 1, rd: 1}

    %{query | header: header, qdlist: [question]}
  end

  defp build_response(query, answers) do
    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: 1,
          rcode: RCode.no_error(),
          ancount: length(answers),
          nscount: 0,
          arcount: 0
      },
      qdlist: query.qdlist,
      anlist: answers,
      nslist: [],
      arlist: []
    }
  end

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.trim_trailing(".")
  end
end
