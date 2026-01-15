defmodule DNS.Zone.Validator.ZoneTest do
  use ExUnit.Case, async: true

  alias DNS.Zone.Validator.Zone, as: ZoneValidator
  alias DNS.Zone.Validator.Result

  # Helper to create a minimal valid zone
  defp valid_zone(zone_name \\ "example.com") do
    [
      soa_record(zone_name),
      ns_record(zone_name, "ns1.example.com."),
      ns_record(zone_name, "ns2.example.com.")
    ]
  end

  defp soa_record(name) do
    %{
      name: name,
      type: :soa,
      ttl: 3600,
      rdata: %{
        mname: "ns1.example.com.",
        rname: "admin.example.com.",
        serial: 2_024_010_101,
        refresh: 3600,
        retry: 600,
        expire: 604_800,
        minimum: 86400
      }
    }
  end

  defp ns_record(name, target) do
    %{name: name, type: :ns, ttl: 3600, rdata: target}
  end

  defp a_record(name, ip) do
    %{name: name, type: :a, ttl: 3600, rdata: ip}
  end

  defp cname_record(name, target) do
    %{name: name, type: :cname, ttl: 3600, rdata: target}
  end

  defp mx_record(name, priority, target) do
    %{name: name, type: :mx, ttl: 3600, rdata: {priority, target}}
  end

  # ============================================
  # Full Zone Validation
  # ============================================

  describe "validate/2" do
    test "valid zone passes all checks" do
      records = valid_zone()
      result = ZoneValidator.validate(records, "example.com")

      assert Result.valid?(result)
      assert Result.errors(result) == []
    end

    test "empty zone has missing SOA and NS errors" do
      result = ZoneValidator.validate([], "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert length(errors) == 2
      assert Enum.any?(errors, &(&1.code == :missing_soa))
      assert Enum.any?(errors, &(&1.code == :missing_ns))
    end

    test "zone with only SOA has missing NS error" do
      records = [soa_record("")]
      result = ZoneValidator.validate(records, "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert length(errors) == 1
      assert hd(errors).code == :missing_ns
    end

    test "zone with multiple SOA records is invalid" do
      records = [
        soa_record(""),
        soa_record(""),
        ns_record("", "ns1.example.com.")
      ]

      result = ZoneValidator.validate(records, "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert Enum.any?(errors, &(&1.code == :multiple_soa))
    end
  end

  # ============================================
  # CNAME Exclusivity
  # ============================================

  describe "CNAME exclusivity validation" do
    test "CNAME alone at a name is valid" do
      records =
        valid_zone() ++
          [cname_record("www", "web.example.com.")]

      result = ZoneValidator.validate(records, "example.com")
      assert Result.valid?(result)
    end

    test "CNAME with A record at same name is invalid" do
      records =
        valid_zone() ++
          [
            cname_record("www", "web.example.com."),
            a_record("www", {192, 0, 2, 1})
          ]

      result = ZoneValidator.validate(records, "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert Enum.any?(errors, &(&1.code == :cname_conflict))
    end

    test "CNAME with MX record at same name is invalid" do
      records =
        valid_zone() ++
          [
            cname_record("mail", "mailserver.example.com."),
            mx_record("mail", 10, "mail.example.com.")
          ]

      result = ZoneValidator.validate(records, "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert Enum.any?(errors, &(&1.code == :cname_conflict))
    end

    test "CNAME at zone apex is invalid" do
      records = [
        soa_record(""),
        ns_record("", "ns1.example.com."),
        cname_record("", "other.com.")
      ]

      result = ZoneValidator.validate(records, "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert Enum.any?(errors, &(&1.code == :cname_at_apex))
    end
  end

  # ============================================
  # NS Record Validation
  # ============================================

  describe "NS record validation" do
    test "single NS record generates warning" do
      records = [
        soa_record(""),
        ns_record("", "ns1.example.com.")
      ]

      result = ZoneValidator.validate(records, "example.com")

      assert Result.valid?(result)
      warnings = Result.warnings(result)
      assert Enum.any?(warnings, &(&1.code == :single_ns))
    end

    test "two or more NS records has no warning" do
      records = [
        soa_record(""),
        ns_record("", "ns1.example.com."),
        ns_record("", "ns2.example.com.")
      ]

      result = ZoneValidator.validate(records, "example.com")

      assert Result.valid?(result)
      warnings = Result.warnings(result)
      refute Enum.any?(warnings, &(&1.code == :single_ns))
    end
  end

  # ============================================
  # MX/NS Target Validation
  # ============================================

  describe "MX/NS target validation" do
    test "MX pointing to CNAME is an error" do
      records =
        valid_zone() ++
          [
            cname_record("mailserver", "actual-server.example.com."),
            mx_record("", 10, "mailserver")
          ]

      result = ZoneValidator.validate(records, "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert Enum.any?(errors, &(&1.code == :target_is_cname))
    end

    test "NS pointing to CNAME is an error" do
      # Create a zone where ns1 is actually a CNAME
      records = [
        soa_record(""),
        ns_record("", "ns1"),
        ns_record("", "ns2.example.com."),
        cname_record("ns1", "actual-ns.example.com.")
      ]

      result = ZoneValidator.validate(records, "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert Enum.any?(errors, &(&1.code == :target_is_cname))
    end

    test "MX pointing to external name is valid" do
      records =
        valid_zone() ++
          [mx_record("", 10, "mail.external.com.")]

      result = ZoneValidator.validate(records, "example.com")

      # No error for external targets
      errors = Result.errors(result)
      refute Enum.any?(errors, &(&1.code == :target_is_cname))
    end
  end

  # ============================================
  # TTL Consistency
  # ============================================

  describe "TTL consistency validation" do
    test "inconsistent TTLs in RRSet generate warning" do
      records =
        valid_zone() ++
          [
            %{name: "www", type: :a, ttl: 300, rdata: {192, 0, 2, 1}},
            %{name: "www", type: :a, ttl: 600, rdata: {192, 0, 2, 2}}
          ]

      result = ZoneValidator.validate(records, "example.com")

      assert Result.valid?(result)
      warnings = Result.warnings(result)
      assert Enum.any?(warnings, &(&1.code == :ttl_mismatch))
    end

    test "consistent TTLs in RRSet have no warning" do
      records =
        valid_zone() ++
          [
            %{name: "www", type: :a, ttl: 300, rdata: {192, 0, 2, 1}},
            %{name: "www", type: :a, ttl: 300, rdata: {192, 0, 2, 2}}
          ]

      result = ZoneValidator.validate(records, "example.com")

      warnings = Result.warnings(result)
      refute Enum.any?(warnings, &(&1.code == :ttl_mismatch))
    end
  end

  # ============================================
  # Orphaned Targets
  # ============================================

  describe "orphaned target validation" do
    test "MX target without A record generates warning" do
      records =
        valid_zone() ++
          [mx_record("", 10, "mail.example.com.")]

      result = ZoneValidator.validate(records, "example.com")

      assert Result.valid?(result)
      warnings = Result.warnings(result)
      assert Enum.any?(warnings, &(&1.code == :orphaned_target))
    end

    test "MX target with A record has no warning" do
      records =
        valid_zone() ++
          [
            mx_record("", 10, "mail.example.com."),
            a_record("mail.example.com", {192, 0, 2, 10})
          ]

      result = ZoneValidator.validate(records, "example.com")

      warnings = Result.warnings(result)
      # Check there's no MX orphaned target warning (NS orphaned warnings may still exist)
      mx_orphaned =
        Enum.any?(warnings, fn w ->
          w.code == :orphaned_target and String.contains?(w.message, "MX")
        end)

      refute mx_orphaned
    end
  end

  # ============================================
  # check_would_conflict/3
  # ============================================

  describe "check_would_conflict/3" do
    test "CNAME at apex is rejected" do
      new_record = %{name: "", type: :cname, rdata: "other.com."}

      assert {:error, %{code: :cname_at_apex}} =
               ZoneValidator.check_would_conflict(new_record, [], "example.com")
    end

    test "CNAME at apex with @ notation is rejected" do
      new_record = %{name: "@", type: :cname, rdata: "other.com."}

      assert {:error, %{code: :cname_at_apex}} =
               ZoneValidator.check_would_conflict(new_record, [], "example.com")
    end

    test "CNAME at apex with zone name is rejected" do
      new_record = %{name: "example.com", type: :cname, rdata: "other.com."}

      assert {:error, %{code: :cname_at_apex}} =
               ZoneValidator.check_would_conflict(new_record, [], "example.com")
    end

    test "new CNAME conflicts with existing A record" do
      existing = [a_record("www", {192, 0, 2, 1})]
      new_record = %{name: "www", type: :cname, rdata: "web.example.com."}

      assert {:error, %{code: :cname_conflict}} =
               ZoneValidator.check_would_conflict(new_record, existing, "example.com")
    end

    test "new A record conflicts with existing CNAME" do
      existing = [cname_record("www", "web.example.com.")]
      new_record = %{name: "www", type: :a, rdata: {192, 0, 2, 1}}

      assert {:error, %{code: :blocked_by_cname}} =
               ZoneValidator.check_would_conflict(new_record, existing, "example.com")
    end

    test "A record at new name has no conflict" do
      existing = [a_record("web", {192, 0, 2, 1})]
      new_record = %{name: "www", type: :a, rdata: {192, 0, 2, 2}}

      assert {:ok, :no_conflict} =
               ZoneValidator.check_would_conflict(new_record, existing, "example.com")
    end

    test "additional A record at same name has no conflict" do
      existing = [a_record("www", {192, 0, 2, 1})]
      new_record = %{name: "www", type: :a, rdata: {192, 0, 2, 2}}

      assert {:ok, :no_conflict} =
               ZoneValidator.check_would_conflict(new_record, existing, "example.com")
    end

    test "MX record at apex is allowed" do
      new_record = %{name: "", type: :mx, rdata: {10, "mail.example.com."}}

      assert {:ok, :no_conflict} =
               ZoneValidator.check_would_conflict(new_record, [], "example.com")
    end
  end

  # ============================================
  # check_can_delete/3
  # ============================================

  describe "check_can_delete/3" do
    test "deleting SOA at apex is blocked" do
      record = soa_record("")
      existing = valid_zone()

      assert {:error, %{code: :cannot_delete_soa}} =
               ZoneValidator.check_can_delete(record, existing, "example.com")
    end

    test "deleting last NS at apex is blocked" do
      record = ns_record("", "ns1.example.com.")
      existing = [soa_record(""), ns_record("", "ns1.example.com.")]

      assert {:error, %{code: :cannot_delete_last_ns}} =
               ZoneValidator.check_can_delete(record, existing, "example.com")
    end

    test "deleting NS when more than one exist is allowed" do
      record = ns_record("", "ns1.example.com.")

      existing = [
        soa_record(""),
        ns_record("", "ns1.example.com."),
        ns_record("", "ns2.example.com.")
      ]

      assert {:ok, :can_delete} =
               ZoneValidator.check_can_delete(record, existing, "example.com")
    end

    test "deleting A record is always allowed" do
      record = a_record("www", {192, 0, 2, 1})

      assert {:ok, :can_delete} =
               ZoneValidator.check_can_delete(record, valid_zone(), "example.com")
    end

    test "deleting CNAME is allowed" do
      record = cname_record("www", "web.example.com.")

      assert {:ok, :can_delete} =
               ZoneValidator.check_can_delete(record, valid_zone(), "example.com")
    end
  end

  # ============================================
  # Result Module
  # ============================================

  describe "Result module" do
    test "new result is valid" do
      result = Result.new()
      assert Result.valid?(result)
    end

    test "adding error makes result invalid" do
      result =
        Result.new()
        |> Result.add_error(:test_error, "Test error message")

      refute Result.valid?(result)
    end

    test "adding warning keeps result valid" do
      result =
        Result.new()
        |> Result.add_warning(:test_warning, "Test warning message")

      assert Result.valid?(result)
    end

    test "errors are returned in order" do
      result =
        Result.new()
        |> Result.add_error(:first, "First")
        |> Result.add_error(:second, "Second")

      errors = Result.errors(result)
      assert [%{code: :first}, %{code: :second}] = errors
    end

    test "to_tuple returns :ok for valid result" do
      result = Result.new()
      assert {:ok, ^result} = Result.to_tuple(result)
    end

    test "to_tuple returns :error for invalid result" do
      result = Result.new() |> Result.add_error(:test, "Test")
      assert {:error, ^result} = Result.to_tuple(result)
    end

    test "merge combines results" do
      r1 = Result.new() |> Result.add_error(:e1, "Error 1")
      r2 = Result.new() |> Result.add_warning(:w1, "Warning 1")

      merged = Result.merge(r1, r2)

      refute Result.valid?(merged)
      assert length(Result.errors(merged)) == 1
      assert length(Result.warnings(merged)) == 1
    end
  end

  # ============================================
  # Edge Cases
  # ============================================

  describe "edge cases" do
    test "handles case-insensitive name matching" do
      records =
        valid_zone() ++
          [
            cname_record("WWW", "web.example.com."),
            a_record("www", {192, 0, 2, 1})
          ]

      result = ZoneValidator.validate(records, "example.com")

      refute Result.valid?(result)
      errors = Result.errors(result)
      assert Enum.any?(errors, &(&1.code == :cname_conflict))
    end

    test "handles trailing dots in zone name" do
      records = [
        soa_record("example.com."),
        ns_record("example.com.", "ns1.example.com."),
        ns_record("example.com.", "ns2.example.com.")
      ]

      result = ZoneValidator.validate(records, "example.com.")

      assert Result.valid?(result)
    end

    test "handles empty records list gracefully" do
      result = ZoneValidator.validate([], "example.com")

      refute Result.valid?(result)
      # Should have errors for missing SOA and NS
      assert length(Result.errors(result)) == 2
    end
  end
end
