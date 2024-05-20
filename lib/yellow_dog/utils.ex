defmodule YellowDog.LocError do
  defexception message: "Wrong values for a location"
end

defmodule YellowDog.Utils do
  @type address :: {integer}

  @spec a2s(address | atom | charlist) :: binary
  def a2s(ip_address) do
    if ip_address == :any do
      "*"
    else
      to_string(:inet_parse.ntoa(unmap(ip_address)))
    end
  end

  @spec unmap(address) :: address
  def unmap(address) do
    case address do
      # "IPv4-Mapped" addresses, RFC 4291, section 2.5.5.2
      {0, 0, 0, 0, 0, 65535, first, second} ->
        first_high = trunc(first / 256)
        second_high = trunc(second / 256)
        {first_high, first - first_high * 256, second_high, second - second_high * 256}

      other ->
        other
    end
  end

  # Apparently, no existing function does it.
  @spec address_family(address) :: atom
  def address_family(address) do
    case tuple_size(unmap(address)) do
      4 -> :inet4
      8 -> :inet6
      _ -> :not_an_ip_address
    end
  end

  @spec str_to_loglevel(binary) :: atom
  def str_to_loglevel(s) do
    case String.downcase(s) do
      "emergency" -> :emergency
      "alert" -> :alert
      "critical" -> :critical
      value when value in ["error", "err"] -> :error
      value when value in ["warning", "warn"] -> :warn
      # Requires Elixir >= 1.11
      "notice" -> :notice
      "info" -> :info
      "debug" -> :debug
      _ -> nil
    end
  end

  @spec str_to_logfacility(binary) :: atom
  def str_to_logfacility(s) do
    case String.downcase(s) do
      "local0" -> :local0
      "local1" -> :local1
      "local2" -> :local2
      "local3" -> :local3
      "local4" -> :local4
      "local5" -> :local5
      "local6" -> :local6
      "local7" -> :local7
      # The rest do not seemto be accepted by Erlang
      # "daemon" -> :daemon
      # "syslog" -> :syslog
      # "user" -> :user
      _ -> nil
    end
  end

  @spec serial() :: integer
  def serial() do
    now = DateTime.utc_now()
    # Not
    now.year * 1_000_000 + now.month * 10000 + now.day * 100 + now.hour
    # perfect since we will keep the same serial for an entire
    # hour. But we have no choice since we don't want to keep state.
  end

  @doc """
  The DNS library we use do not encode LOC
  <https://github.com/erlang/otp/issues/6098>.  So, we do it
  ourselves.
  Latitude is between -90.0 (south) and +90.0 (north). Longitude is
  between -180.0 (west) and +180.0 (east). Altitude must be in meters
  from sea level.
  """
  @spec loc(float, float, float) :: binary
  def loc(latitude, longitude, altitude) do
    # RFC 1876, section 2. Units are thousandth of seconds of arc and
    # the reference is 2**31, aka 2147483648.
    if latitude < -90.0 or latitude > 90.0 or longitude < -180.0 or longitude > 180.0 do
      raise YellowDog.LocError
    end

    longitude = round(longitude * 60 * 60 * 1000) + 2_147_483_648
    latitude = round(latitude * 60 * 60 * 1000) + 2_147_483_648
    # Altitude is encoded
    altitude = round(altitude * 100 + 10_000_000)
    # in centimeters, and
    # start from *below*
    # the sea level.
    # RFC 1876, section 2. We hardwire the size to zero (a point) and
    # the precisions.
    <<0, 0, 0, 0, latitude::unsigned-integer-size(32), longitude::unsigned-integer-size(32),
      altitude::unsigned-integer-size(32)>>
  end

  defmodule Convert do
    @minute 60
    @hour @minute * 60
    @day @hour * 24
    @week @day * 7
    @month @day * 30.5

    def seconds_to_human(sec) do
      months = floor(sec / @month)

      months_s =
        cond do
          months > 1 -> "#{months} months"
          months == 1 -> "#{months} month"
          months == 0 -> ""
        end

      sec = sec - months * @month
      weeks = floor(sec / @week)

      weeks_s =
        cond do
          weeks > 1 -> "#{weeks} weeks"
          weeks == 1 -> "#{weeks} week"
          weeks == 0 -> ""
        end

      sec = sec - weeks * @week
      days = floor(sec / @day)

      days_s =
        cond do
          days > 1 -> "#{days} days"
          days == 1 -> "#{days} day"
          days == 0 -> ""
        end

      sec = sec - days * @day
      hours = floor(sec / @hour)

      hours_s =
        cond do
          hours > 1 -> "#{hours} hours"
          hours == 1 -> "#{hours} hour"
          hours == 0 -> ""
        end

      sec = sec - hours * @hour
      minutes = floor(sec / @minute)

      minutes_s =
        cond do
          minutes > 1 -> "#{minutes} minutes"
          minutes == 1 -> "#{minutes} minute"
          minutes == 0 -> ""
        end

      seconds = floor(sec - minutes * @minute)

      seconds_s =
        cond do
          seconds > 1 -> "#{seconds} seconds"
          seconds == 1 -> "#{seconds} second"
          seconds == 0 -> ""
        end

      String.trim(
        Regex.replace(
          ~r/\s+/u,
          "#{months_s} #{weeks_s} #{days_s} #{hours_s} #{minutes_s} #{seconds_s}",
          " "
        )
      )
    end
  end
end
