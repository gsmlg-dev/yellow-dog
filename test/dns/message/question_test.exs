defmodule YellowDog.DNS.Message.QuestionTest do
  use ExUnit.Case
  doctest YellowDog

  alias YellowDog.DNS.Message.Question
  alias YellowDog.DNS.Class
  alias YellowDog.DNS.ResourceRecord.Type, as: RType

  test "Test DNS message header creation" do
    question = Question.new("a.root-servers.net", RType.a(), Class.internet())

    assert %Question{name: "a.root-servers.net.", type: 1, class: 1} = question
  end

  test "Test DNS message header to_buffer/from_buffer" do
    question = Question.new("a.root-servers.net", RType.a(), Class.internet())
    buffer = <<1, "a", 12, "root-servers", 3, "net", 0, RType.a()::16, Class.internet()::16>>
    buffer_size = byte_size(buffer)

    assert ^buffer =
             Question.to_buffer(question)

    assert {^buffer_size, ^question} = Question.from_buffer(buffer)
  end
end
