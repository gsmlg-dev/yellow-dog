defmodule YellowDog.Data.Resource.OwnershipTest do
  use ExUnit.Case, async: true

  alias YellowDog.Data.Resource.Ownership
  alias YellowDog.Data.Collection

  describe "collection/0" do
    test "returns a Collection struct" do
      assert %Collection{name: :ownership_links} = Ownership.collection()
    end

    test "key_field is :id" do
      assert Ownership.collection().key_field == :id
    end

    test "indexes include :identity_id and :hardware_id" do
      indexes = Ownership.collection().indexes
      assert :identity_id in indexes
      assert :hardware_id in indexes
    end
  end

  describe "new/1 — valid cases" do
    test "creates ownership with required fields" do
      assert {:ok, link} =
               Ownership.new(%{identity_id: "user-1", hardware_id: "srv-1"})

      assert link.identity_id == "user-1"
      assert link.hardware_id == "srv-1"
    end

    test "auto-generates id from identity_id:hardware_id when not provided" do
      {:ok, link} = Ownership.new(%{identity_id: "user-1", hardware_id: "srv-1"})
      assert link.id == "user-1:srv-1"
    end

    test "uses explicit id when provided" do
      {:ok, link} = Ownership.new(%{id: "custom-id", identity_id: "user-1", hardware_id: "srv-1"})
      assert link.id == "custom-id"
    end

    test "defaults role to 'owner'" do
      {:ok, link} = Ownership.new(%{identity_id: "u-1", hardware_id: "h-1"})
      assert link.role == "owner"
    end

    test "accepts all valid roles" do
      for role <- ~w(owner user manager) do
        assert {:ok, link} =
                 Ownership.new(%{identity_id: "u-#{role}", hardware_id: "h-1", role: role})

        assert link.role == role
      end
    end

    test "accepts string keys" do
      assert {:ok, link} =
               Ownership.new(%{"identity_id" => "user-2", "hardware_id" => "srv-2"})

      assert link.identity_id == "user-2"
      assert link.hardware_id == "srv-2"
    end

    test "sets assigned_at when not provided" do
      {:ok, link} = Ownership.new(%{identity_id: "u-1", hardware_id: "h-1"})
      assert %DateTime{} = link.assigned_at
    end

    test "accepts custom assigned_at" do
      ts = ~U[2025-01-01 00:00:00Z]
      {:ok, link} = Ownership.new(%{identity_id: "u-1", hardware_id: "h-1", assigned_at: ts})
      assert link.assigned_at == ts
    end

    test "sets created_at and updated_at" do
      {:ok, link} = Ownership.new(%{identity_id: "u-1", hardware_id: "h-1"})
      assert %DateTime{} = link.created_at
      assert %DateTime{} = link.updated_at
    end

    test "notes defaults to nil" do
      {:ok, link} = Ownership.new(%{identity_id: "u-1", hardware_id: "h-1"})
      assert link.notes == nil
    end

    test "accepts notes" do
      {:ok, link} =
        Ownership.new(%{identity_id: "u-1", hardware_id: "h-1", notes: "primary owner"})

      assert link.notes == "primary owner"
    end
  end

  describe "new/1 — validation errors" do
    test "returns error when identity_id is nil" do
      assert {:error, "identity_id is required"} = Ownership.new(%{hardware_id: "h-1"})
    end

    test "returns error when identity_id is empty" do
      assert {:error, "identity_id is required"} =
               Ownership.new(%{identity_id: "", hardware_id: "h-1"})
    end

    test "returns error when hardware_id is nil" do
      assert {:error, "hardware_id is required"} = Ownership.new(%{identity_id: "u-1"})
    end

    test "returns error when hardware_id is empty" do
      assert {:error, "hardware_id is required"} =
               Ownership.new(%{identity_id: "u-1", hardware_id: ""})
    end

    test "returns error for invalid role" do
      assert {:error, msg} =
               Ownership.new(%{identity_id: "u-1", hardware_id: "h-1", role: "admin"})

      assert msg =~ "invalid role"
    end
  end

  describe "validate/1" do
    test "returns {:ok, link} for valid struct" do
      link = %Ownership{identity_id: "u-1", hardware_id: "h-1", role: "owner"}
      assert {:ok, ^link} = Ownership.validate(link)
    end

    test "returns error when identity_id is nil" do
      link = %Ownership{identity_id: nil, hardware_id: "h-1", role: "owner"}
      assert {:error, "identity_id is required"} = Ownership.validate(link)
    end

    test "returns error for invalid role" do
      link = %Ownership{identity_id: "u-1", hardware_id: "h-1", role: "overlord"}
      assert {:error, msg} = Ownership.validate(link)
      assert msg =~ "invalid role"
    end
  end
end
