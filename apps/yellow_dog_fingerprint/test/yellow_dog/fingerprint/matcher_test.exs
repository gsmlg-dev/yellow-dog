defmodule YellowDog.Fingerprint.MatcherTest do
  use ExUnit.Case, async: true

  alias YellowDog.Fingerprint.Matcher

  describe "jaccard_similarity/2" do
    test "identical lists have similarity 1.0" do
      assert Matcher.jaccard_similarity([1, 3, 6, 15], [1, 3, 6, 15]) == 1.0
    end

    test "disjoint lists have similarity 0.0" do
      assert Matcher.jaccard_similarity([1, 2, 3], [4, 5, 6]) == 0.0
    end

    test "partially overlapping lists" do
      # intersection = {1, 3}, union = {1, 2, 3, 4} => 2/4 = 0.5
      assert Matcher.jaccard_similarity([1, 2, 3], [1, 3, 4]) == 0.5
    end

    test "both empty lists return 0.0" do
      assert Matcher.jaccard_similarity([], []) == 0.0
    end

    test "one empty list returns 0.0" do
      assert Matcher.jaccard_similarity([1, 2, 3], []) == 0.0
    end

    test "high similarity threshold (0.8+)" do
      # 8/10 overlap = 0.8
      list_a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      list_b = [1, 2, 3, 4, 5, 6, 7, 8, 11, 12]
      sim = Matcher.jaccard_similarity(list_a, list_b)
      # intersection = 8, union = 12 => 8/12 ≈ 0.667
      assert_in_delta sim, 0.667, 0.01
    end
  end
end
