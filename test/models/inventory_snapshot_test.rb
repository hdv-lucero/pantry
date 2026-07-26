require "test_helper"

class InventorySnapshotTest < ActiveSupport::TestCase
  test "current covers every in-stock item" do
    assert_equal PantryItem.in_stock_names.sort, InventorySnapshot.current.names.to_a.sort
  end

  test "entries carry the four fields §5 names" do
    entry = entry_for("milk")

    assert_equal %w[ name quantity unit expires_on ], entry.keys
    assert_equal 1.0, entry["quantity"]
    assert_equal "gallon", entry["unit"]
    assert_equal pantry_items(:milk).expires_on.to_s, entry["expires_on"]
  end

  test "a zeroed item leaves the snapshot entirely" do
    pantry_items(:rice).update!(quantity: 0)

    snapshot = InventorySnapshot.current

    assert_not snapshot.include?("rice")
    # It must not be offerable as a substitution either — §5 constrains those to
    # items "currently in the inventory".
    assert_not_includes snapshot.entries.map { |e| e["name"] }, "rice"
  end

  test "two rows of the same thing in the same unit become one entry" do
    PantryItem.create!(name: "rice", quantity: 3, unit: "kg", location: :fridge)

    entry = entry_for("rice")

    assert_equal 5.0, entry["quantity"], "2kg in the pantry plus 3kg in the fridge is 5kg of rice"
    assert_equal 1, InventorySnapshot.current.entries.count { |e| e["name"] == "rice" }
  end

  test "the same thing in different units stays two entries rather than being added up" do
    PantryItem.create!(name: "rice", quantity: 500, unit: "g", location: :fridge)

    entries = InventorySnapshot.current.entries.select { |e| e["name"] == "rice" }

    assert_equal 2, entries.size
    assert_equal [ 500.0, 2.0 ], entries.map { |e| e["quantity"] }
    # One name either way, so the exact-name echo rule is unaffected.
    assert_equal 1, InventorySnapshot.current.names.count { |name| name == "rice" }
  end

  test "a grouped entry takes the soonest expiry" do
    PantryItem.create!(name: "rice", quantity: 1, unit: "kg", location: :fridge, expires_on: 5.days.from_now)
    PantryItem.create!(name: "rice", quantity: 1, unit: "kg", location: :freezer, expires_on: 2.days.from_now)

    assert_equal 2.days.from_now.to_date.to_s, entry_for("rice")["expires_on"]
  end

  test "entries are sorted so two builds of one pantry are byte-identical" do
    assert_equal InventorySnapshot.current.entries, InventorySnapshot.current.entries
    assert_equal InventorySnapshot.current.entries.sort_by { |e| e["name"] }, InventorySnapshot.current.entries
  end

  # ── the fingerprint §5 caches on ────────────────────────────────────────────

  test "the same pantry fingerprints the same" do
    assert_equal InventorySnapshot.current.fingerprint, InventorySnapshot.current.fingerprint
  end

  test "touching a record without changing it leaves the fingerprint alone" do
    before = InventorySnapshot.current.fingerprint
    pantry_items(:rice).touch

    assert_equal before, InventorySnapshot.current.fingerprint
  end

  test "every field the model sees moves the fingerprint" do
    # Each change is applied on top of the last rather than unwound; all that matters
    # is that every one of them moves the digest off the value before it.
    {
      "quantity" => -> { pantry_items(:rice).update!(quantity: 99) },
      "unit" => -> { pantry_items(:rice).update!(unit: "bags") },
      "expires_on" => -> { pantry_items(:rice).update!(expires_on: 3.days.from_now) },
      "name" => -> { pantry_items(:rice).update!(name: "brown rice") },
      "an added item" => -> { PantryItem.create!(name: "lentils", quantity: 1, location: :pantry) },
      "a removed item" => -> { pantry_items(:rice).destroy! }
    }.each do |field, change|
      assert_changes -> { InventorySnapshot.current.fingerprint }, "#{field} should move the fingerprint" do
        change.call
      end
    end
  end

  # ── round-tripping through the run's JSON column ────────────────────────────

  test "a snapshot read back off a run matches the one that was stored" do
    original = InventorySnapshot.current
    run = SuggestionRun.create!(inventory_snapshot: original.as_json)

    restored = InventorySnapshot.for(run.reload)

    assert_equal original.entries, restored.entries
    assert_equal original.names, restored.names
    assert_equal original.fingerprint, restored.fingerprint
  end

  test "a run with no snapshot yields an empty one rather than raising" do
    assert_predicate InventorySnapshot.for(SuggestionRun.create!), :empty?
  end

  test "unexpected keys in a stored snapshot are dropped on read" do
    run = SuggestionRun.create!(inventory_snapshot: [ { "name" => "rice", "quantity" => 2, "colour" => "white" } ])

    assert_equal %w[ name quantity ], InventorySnapshot.for(run.reload).entries.sole.keys
  end

  private
    def entry_for(name)
      InventorySnapshot.current.entries.find { |entry| entry["name"] == name } || flunk("no entry for #{name}")
    end
end
