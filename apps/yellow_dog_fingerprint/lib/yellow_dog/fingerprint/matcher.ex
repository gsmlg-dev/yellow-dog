defmodule YellowDog.Fingerprint.Matcher do
  @moduledoc """
  Fingerprint matching pipeline.

  Attempts to identify a device profile from a fingerprint using this priority:
  1. User overrides (always win)
  2. Exact hash match (local database)
  3. Fuzzy match (Jaccard similarity >= 0.8 on parameter list)
  4. Vendor class regex patterns
  5. Fingerbank API fallback (if enabled)
  6. No match → unknown
  """

  alias YellowDog.Fingerprint.{Database, FingerbankClient}
  alias YellowDog.Fingerprint.Types.{DeviceProfile, Fingerprint}

  @vendor_class_patterns [
    {~r/^MSFT 5\.0$/, "windows-generic", 40},
    {~r/^android-dhcp-/, "android-generic", 40},
    {~r/^udhcp/, "embedded-linux", 35},
    {~r/^dhcpcd-/, "linux-generic", 35},
    {~r/^APPLE/, "apple-generic", 40}
  ]

  @doc """
  Matches a fingerprint hash against the database.

  Returns `{:ok, profile}` with a DeviceProfile, or `:unknown`.
  """
  @spec match_by_hash(binary()) :: {:ok, DeviceProfile.t()} | :unknown
  def match_by_hash(fingerprint_id) do
    with :not_found <- check_override(fingerprint_id),
         :not_found <- check_exact(fingerprint_id) do
      :unknown
    end
  end

  @doc """
  Full match pipeline for a fingerprint struct.

  Tries exact → fuzzy → vendor class → Fingerbank in order.
  Returns `{:ok, profile_id, confidence, source}` or `:unknown`.
  """
  @spec match(Fingerprint.t()) :: {:ok, String.t(), non_neg_integer(), atom()} | :unknown
  def match(%Fingerprint{} = fp) do
    with :not_found <- check_override(fp.id),
         :not_found <- check_exact_full(fp),
         :not_found <- check_fuzzy(fp),
         :not_found <- check_vendor_class(fp),
         :not_found <- check_fingerbank(fp) do
      :unknown
    end
  end

  @doc """
  Computes Jaccard similarity between two parameter lists.

  Returns a float between 0.0 and 1.0.
  """
  @spec jaccard_similarity([non_neg_integer()], [non_neg_integer()]) :: float()
  def jaccard_similarity([], []), do: 0.0

  def jaccard_similarity(list_a, list_b) do
    set_a = MapSet.new(list_a)
    set_b = MapSet.new(list_b)
    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 0.0, else: intersection / union
  end

  # --- Private Match Steps ---

  defp check_override(fingerprint_id) do
    case Database.lookup_override(fingerprint_id) do
      {:ok, %{profile_id: profile_id}} ->
        case Database.get_profile(profile_id) do
          {:ok, profile} -> {:ok, %{profile | confidence: 100, source: :user_override}}
          :not_found -> :not_found
        end

      :not_found ->
        :not_found
    end
  end

  defp check_exact(fingerprint_id) do
    result =
      case Database.lookup_v4(fingerprint_id) do
        {:ok, mapping} -> mapping
        :not_found -> nil
      end

    result =
      result ||
        case Database.lookup_v6(fingerprint_id) do
          {:ok, mapping} -> mapping
          :not_found -> nil
        end

    case result do
      %{profile_id: pid, confidence: conf} when not is_nil(pid) ->
        case Database.get_profile(pid) do
          {:ok, profile} -> {:ok, %{profile | confidence: conf}}
          :not_found -> :not_found
        end

      _ ->
        :not_found
    end
  end

  defp check_exact_full(%Fingerprint{} = fp) do
    lookup_fn = if fp.protocol == :dhcpv4, do: &Database.lookup_v4/1, else: &Database.lookup_v6/1

    case lookup_fn.(fp.id) do
      {:ok, %{profile_id: pid, confidence: conf}} when not is_nil(pid) ->
        case Database.get_profile(pid) do
          {:ok, profile} -> {:ok, pid, conf, profile.source}
          :not_found -> :not_found
        end

      _ ->
        :not_found
    end
  end

  defp check_fuzzy(%Fingerprint{} = fp) do
    threshold = Application.get_env(:yellow_dog_fingerprint, :fuzzy_threshold, 0.8)

    entries =
      if fp.protocol == :dhcpv4, do: Database.all_v4_entries(), else: Database.all_v6_entries()

    entries
    |> Enum.filter(&(&1.profile_id != nil))
    |> Enum.map(fn entry ->
      sim = jaccard_similarity(fp.parameter_list, entry.parameter_list)
      {entry, sim}
    end)
    |> Enum.filter(fn {_entry, sim} -> sim >= threshold end)
    |> Enum.sort_by(fn {_entry, sim} -> sim end, :desc)
    |> case do
      [{entry, sim} | _] ->
        confidence = round(sim * entry.confidence * 0.8)
        {:ok, entry.profile_id, confidence, :local}

      [] ->
        :not_found
    end
  end

  defp check_vendor_class(%Fingerprint{vendor_class: nil}), do: :not_found

  defp check_vendor_class(%Fingerprint{vendor_class: vc}) do
    Enum.find_value(@vendor_class_patterns, :not_found, fn {regex, profile_id, confidence} ->
      if Regex.match?(regex, vc) do
        {:ok, profile_id, confidence, :local}
      end
    end)
  end

  defp check_fingerbank(%Fingerprint{} = fp) do
    if Application.get_env(:yellow_dog_fingerprint, :fingerbank_enabled, false) do
      case FingerbankClient.interrogate(fp) do
        {:ok, profile_id, confidence} -> {:ok, profile_id, confidence, :fingerbank}
        _ -> :not_found
      end
    else
      :not_found
    end
  end
end
