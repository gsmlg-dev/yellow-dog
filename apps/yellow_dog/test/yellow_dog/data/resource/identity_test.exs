defmodule YellowDog.Data.Resource.IdentityTest do
  use ExUnit.Case, async: true

  alias YellowDog.Data.Resource.Identity
  alias YellowDog.Data.Collection

  describe "collection/0" do
    test "returns a Collection struct" do
      assert %Collection{name: :identities} = Identity.collection()
    end

    test "key_field is :id" do
      assert Identity.collection().key_field == :id
    end

    test "indexes include :email, :type, :department, :status" do
      indexes = Identity.collection().indexes
      assert :email in indexes
      assert :type in indexes
      assert :department in indexes
      assert :status in indexes
    end
  end

  describe "new/1 — valid cases" do
    test "creates identity with required fields" do
      assert {:ok, id} = Identity.new(%{id: "user-1", name: "Alice"})
      assert id.id == "user-1"
      assert id.name == "Alice"
    end

    test "defaults type to 'person'" do
      {:ok, id} = Identity.new(%{id: "user-1", name: "Alice"})
      assert id.type == "person"
    end

    test "defaults status to 'active'" do
      {:ok, id} = Identity.new(%{id: "user-1", name: "Alice"})
      assert id.status == "active"
    end

    test "accepts valid email" do
      assert {:ok, id} = Identity.new(%{id: "u-1", name: "Bob", email: "bob@example.com"})
      assert id.email == "bob@example.com"
    end

    test "accepts string keys" do
      assert {:ok, id} = Identity.new(%{"id" => "u-2", "name" => "Carol"})
      assert id.id == "u-2"
      assert id.name == "Carol"
    end

    test "accepts all valid types" do
      for type <- ~w(person group service_account) do
        assert {:ok, id} = Identity.new(%{id: "u-#{type}", name: "N", type: type})
        assert id.type == type
      end
    end

    test "accepts all valid statuses" do
      for status <- ~w(active inactive) do
        assert {:ok, id} = Identity.new(%{id: "u-#{status}", name: "N", status: status})
        assert id.status == status
      end
    end

    test "sets created_at and updated_at timestamps" do
      {:ok, id} = Identity.new(%{id: "u-ts", name: "N"})
      assert %DateTime{} = id.created_at
      assert %DateTime{} = id.updated_at
    end

    test "defaults tags to empty list" do
      {:ok, id} = Identity.new(%{id: "u-tags", name: "N"})
      assert id.tags == []
    end

    test "defaults properties to empty map" do
      {:ok, id} = Identity.new(%{id: "u-props", name: "N"})
      assert id.properties == %{}
    end
  end

  describe "new/1 — validation errors" do
    test "returns error when id is nil" do
      assert {:error, "id is required"} = Identity.new(%{name: "Alice"})
    end

    test "returns error when id is empty" do
      assert {:error, "id is required"} = Identity.new(%{id: "", name: "Alice"})
    end

    test "returns error when name is nil" do
      assert {:error, "name is required"} = Identity.new(%{id: "u-1"})
    end

    test "returns error when name is empty" do
      assert {:error, "name is required"} = Identity.new(%{id: "u-1", name: ""})
    end

    test "returns error for invalid email format" do
      assert {:error, "invalid email format"} =
               Identity.new(%{id: "u-1", name: "N", email: "not-an-email"})
    end

    test "returns error for email without domain" do
      assert {:error, "invalid email format"} =
               Identity.new(%{id: "u-1", name: "N", email: "user@"})
    end

    test "returns error for invalid type" do
      assert {:error, msg} = Identity.new(%{id: "u-1", name: "N", type: "robot"})
      assert msg =~ "invalid type"
    end

    test "returns error for invalid status" do
      assert {:error, msg} = Identity.new(%{id: "u-1", name: "N", status: "suspended"})
      assert msg =~ "invalid status"
    end
  end

  describe "update/2" do
    test "updates name" do
      {:ok, id} = Identity.new(%{id: "u-upd", name: "OldName"})
      assert {:ok, updated} = Identity.update(id, %{name: "NewName"})
      assert updated.name == "NewName"
    end

    test "updates email" do
      {:ok, id} = Identity.new(%{id: "u-upd2", name: "N"})
      assert {:ok, updated} = Identity.update(id, %{email: "new@example.com"})
      assert updated.email == "new@example.com"
    end

    test "accepts string keys in update attrs" do
      {:ok, id} = Identity.new(%{id: "u-upd3", name: "N"})
      assert {:ok, updated} = Identity.update(id, %{"name" => "StringKey"})
      assert updated.name == "StringKey"
    end

    test "preserves id on update" do
      {:ok, id} = Identity.new(%{id: "u-upd4", name: "N"})
      {:ok, updated} = Identity.update(id, %{name: "X"})
      assert updated.id == "u-upd4"
    end

    test "returns error when update produces invalid email" do
      {:ok, id} = Identity.new(%{id: "u-upd5", name: "N"})
      assert {:error, "invalid email format"} = Identity.update(id, %{email: "bad"})
    end

    test "returns error when update produces invalid type" do
      {:ok, id} = Identity.new(%{id: "u-upd6", name: "N"})
      assert {:error, _} = Identity.update(id, %{type: "bot"})
    end
  end
end
