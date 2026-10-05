defmodule YellowDog.Worker.TransitionJournal do
  @moduledoc false

  @fields ~w(version attempt sequence worker_id kind base_active base_previous base_hash candidate_hash phase outcome actions)
  @action_fields ~w(direction service operation status detail)
  @hash ~r/\A[0-9a-f]{64}\z/
  @attempt ~r/\A[0-9a-f]{32}\z/
  @max_bytes 262_144

  def max_bytes, do: @max_bytes

  def encode(record) do
    with :ok <- validate(record) do
      body = body(record)
      bytes = "checksum = \"#{digest(body)}\"\n" <> body
      if byte_size(bytes) <= @max_bytes, do: {:ok, bytes}, else: {:error, :journal_too_large}
    end
  end

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, decoded} <- Toml.decode(bytes),
         {checksum, record} <- Map.pop(decoded, "checksum"),
         :ok <- validate(record),
         true <- checksum == digest(body(record)) do
      {:ok, record}
    else
      _ -> {:error, :invalid_transition_journal}
    end
  rescue
    _ -> {:error, :invalid_transition_journal}
  end

  def decode(_), do: {:error, :invalid_transition_journal}

  defp validate(record) do
    valid =
      is_map(record) and Enum.sort(Map.keys(record)) == Enum.sort(@fields) and
        record["version"] == 1 and text?(record["attempt"], 32) and
        Regex.match?(@attempt, record["attempt"]) and
        is_integer(record["sequence"]) and record["sequence"] in 1..4096 and
        text?(record["worker_id"], 256) and record["worker_id"] != "" and
        record["kind"] in ~w(install repair) and
        Enum.all?(~w(base_active base_previous base_hash candidate_hash), &hash?(record[&1])) and
        record["candidate_hash"] != "none" and
        record["phase"] in ~w(applying recovering committing pointer_committed complete) and
        record["outcome"] in ~w(pending committed rejected repaired) and
        is_list(record["actions"]) and length(record["actions"]) <= 512 and
        Enum.all?(record["actions"], &action?/1) and
        if(record["phase"] == "complete",
          do: record["outcome"] != "pending",
          else: record["outcome"] == "pending"
        )

    if valid, do: :ok, else: {:error, :invalid_transition_journal}
  end

  defp action?(action) do
    is_map(action) and Enum.sort(Map.keys(action)) == Enum.sort(@action_fields) and
      action["direction"] in ~w(forward recovery) and text?(action["service"], 256) and
      action["service"] != "" and action["operation"] in ~w(apply quiesce remove) and
      action["status"] in ~w(dispatched accepted failed uncertain) and
      text?(action["detail"], 256)
  end

  defp hash?("none"), do: true
  defp hash?(value), do: is_binary(value) and Regex.match?(@hash, value)

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) <= max and String.valid?(value)

  defp body(record) do
    scalars =
      for field <- @fields -- ["actions"] do
        value = record[field]
        "#{field} = #{if is_integer(value), do: to_string(value), else: quote_text(value)}\n"
      end

    actions =
      if record["actions"] == [] do
        ["actions = []\n"]
      else
        for action <- record["actions"] do
          ["\n[[actions]]\n" | Enum.map(@action_fields, &"#{&1} = #{quote_text(action[&1])}\n")]
        end
      end

    IO.iodata_to_binary([scalars, actions])
  end

  defp quote_text(value) do
    escaped =
      for <<codepoint::utf8 <- value>>, into: "" do
        case codepoint do
          34 ->
            "\\\""

          92 ->
            "\\\\"

          control when control < 32 or control == 127 ->
            "\\u" <> (Integer.to_string(control, 16) |> String.pad_leading(4, "0"))

          other ->
            <<other::utf8>>
        end
      end

    "\"" <> escaped <> "\""
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
