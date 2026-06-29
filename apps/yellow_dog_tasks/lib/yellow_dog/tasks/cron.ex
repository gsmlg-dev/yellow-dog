defmodule YellowDog.Tasks.Cron do
  @moduledoc false

  @type field :: :any | MapSet.t(integer())
  @type expression :: %{
          minute: field(),
          hour: field(),
          day: field(),
          month: field(),
          weekday: field()
        }

  @weekday_names %{
    "SUN" => 0,
    "MON" => 1,
    "TUE" => 2,
    "WED" => 3,
    "THU" => 4,
    "FRI" => 5,
    "SAT" => 6
  }

  @spec parse(String.t()) :: {:ok, expression()} | {:error, String.t()}
  def parse(cron) when is_binary(cron) do
    case String.split(cron, ~r/\s+/, trim: true) do
      [minute, hour, day, month, weekday] ->
        with {:ok, minute} <- parse_field(minute, 0..59, %{}),
             {:ok, hour} <- parse_field(hour, 0..23, %{}),
             {:ok, day} <- parse_field(day, 1..31, %{}),
             {:ok, month} <- parse_field(month, 1..12, %{}),
             {:ok, weekday} <- parse_field(weekday, 0..6, @weekday_names) do
          {:ok,
           %{
             minute: minute,
             hour: hour,
             day: day,
             month: month,
             weekday: weekday
           }}
        end

      _ ->
        {:error, "must contain five cron fields"}
    end
  end

  def parse(_cron), do: {:error, "must be a cron expression string"}

  @spec due?(String.t(), DateTime.t()) :: boolean()
  def due?(cron, %DateTime{} = now) do
    case parse(cron) do
      {:ok, expression} -> due_expression?(expression, now)
      {:error, _reason} -> false
    end
  end

  @spec minute_id(DateTime.t()) :: String.t()
  def minute_id(%DateTime{} = now) do
    "#{now.year}-#{pad(now.month)}-#{pad(now.day)}T#{pad(now.hour)}:#{pad(now.minute)}Z"
  end

  defp parse_field("*", _range, _aliases), do: {:ok, :any}

  defp parse_field(field, range, aliases) do
    values =
      field
      |> String.split(",", trim: true)
      |> Enum.reduce_while(MapSet.new(), fn part, acc ->
        case parse_part(part, range, aliases) do
          {:ok, part_values} -> {:cont, MapSet.union(acc, MapSet.new(part_values))}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case values do
      {:error, reason} -> {:error, reason}
      set -> {:ok, set}
    end
  end

  defp parse_part(part, range, aliases) do
    with [base, step_text] <- String.split(part, "/", parts: 2),
         {step, ""} when step > 0 <- Integer.parse(step_text),
         {:ok, values} <- parse_part(base, range, aliases) do
      {:ok, Enum.take_every(values, step)}
    else
      [_base] -> parse_range_or_value(part, range, aliases)
      _ -> {:error, "invalid cron step #{inspect(part)}"}
    end
  end

  defp parse_range_or_value("*", range, _aliases), do: {:ok, Enum.to_list(range)}

  defp parse_range_or_value(part, range, aliases) do
    case String.split(part, "-", parts: 2) do
      [left, right] ->
        with {:ok, first} <- parse_value(left, range, aliases),
             {:ok, last} <- parse_value(right, range, aliases),
             true <- first <= last do
          {:ok, Enum.to_list(first..last)}
        else
          false -> {:error, "invalid cron range #{inspect(part)}"}
          {:error, reason} -> {:error, reason}
        end

      [value] ->
        with {:ok, parsed} <- parse_value(value, range, aliases) do
          {:ok, [parsed]}
        end
    end
  end

  defp parse_value(value, range, aliases) do
    normalized = String.upcase(value)

    parsed =
      case Map.fetch(aliases, normalized) do
        {:ok, aliased} ->
          {:ok, aliased}

        :error ->
          case Integer.parse(value) do
            {integer, ""} -> {:ok, integer}
            _ -> {:error, "invalid cron value #{inspect(value)}"}
          end
      end

    with {:ok, integer} <- parsed do
      if integer in range do
        {:ok, integer}
      else
        {:error, "cron value #{integer} outside #{inspect(range)}"}
      end
    end
  end

  defp due_expression?(expression, now) do
    cron_weekday = rem(Date.day_of_week(DateTime.to_date(now)), 7)

    field_match?(expression.minute, now.minute) and
      field_match?(expression.hour, now.hour) and
      field_match?(expression.day, now.day) and
      field_match?(expression.month, now.month) and
      field_match?(expression.weekday, cron_weekday)
  end

  defp field_match?(:any, _value), do: true
  defp field_match?(values, value), do: MapSet.member?(values, value)

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
