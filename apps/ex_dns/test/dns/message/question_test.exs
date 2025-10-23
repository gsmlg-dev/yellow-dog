defmodule DNS.Message.QuestionTest do
  use ExUnit.Case

  test "DNS Message Question new" do
    q = DNS.Message.Question.new("www.example.com", 1, 1)
    assert %DNS.Message.Question{} = q
  end

  test "DNS Message Question to_iodata/1" do
    q = DNS.Message.Question.new("www.example.com", 1, 1)
    assert %DNS.Message.Question{} = q
    iodata = DNS.to_iodata(q)

    assert iodata ==
             <<3, 119, 119, 119, 7, 101, 120, 97, 109, 112, 108, 101, 3, 99, 111, 109, 0, 0, 1, 0,
               1>>

    assert q == DNS.Message.Question.from_iodata(iodata)
  end

  test "DNS Message Question to_string/1" do
    q = DNS.Message.Question.new("www.example.com", :a, :in)
    assert "#{q}" =~ "www.example.com. A IN"
  end
end
