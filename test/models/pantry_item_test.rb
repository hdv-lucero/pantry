require "test_helper"
require "turbo/broadcastable/test_helper"

class PantryItemTest < ActiveSupport::TestCase
  # Refresh broadcasts go out through a job, so they have to be performed before
  # the cable assertion can see them. turbo-rails only auto-includes its helper
  # once Action Cable has been loaded, which a model test never does on its own.
  include ActiveJob::TestHelper
  include Turbo::Broadcastable::TestHelper

  test "downcases, squishes, and singularizes name" do
    assert_equal "bok choi", PantryItem.new(name: "  Bok Choi ").name
    assert_equal "egg", PantryItem.new(name: "Eggs").name
    assert_equal "green bean", PantryItem.new(name: "Green   Beans").name
  end

  test "keeps food words the default inflector mangles" do
    assert_equal "asparagus", PantryItem.new(name: "Asparagus").name
    assert_equal "olive", PantryItem.new(name: "Olives").name
    assert_equal "pasta", PantryItem.new(name: "Pasta").name
  end

  test "downcases unit without singularizing it" do
    assert_equal "pcs", PantryItem.new(unit: " PCS ").unit
    assert_equal "cans", PantryItem.new(unit: "Cans").unit
  end

  test "blank unit normalizes to nil" do
    assert_nil PantryItem.new(unit: "   ").unit
  end

  test "normalization applies to finder conditions" do
    PantryItem.create!(name: "Lemons", location: :fridge)

    assert_equal "lemon", PantryItem.find_by(name: "Lemons").name
  end

  test "defaults to one item in the pantry" do
    item = PantryItem.create!(name: "salt")

    assert_equal 1, item.quantity
    assert_predicate item, :pantry?
    assert_nil item.category
  end

  test "requires a name and a non-negative quantity" do
    assert_predicate PantryItem.new(name: " "), :invalid?
    assert_predicate PantryItem.new(name: "milk", quantity: -1), :invalid?
    assert_predicate PantryItem.new(name: "milk", quantity: 0), :valid?
  end

  test "expiring_soon covers the next three days and anything already past" do
    soon = PantryItem.create!(name: "kale", expires_on: 3.days.from_now.to_date)
    later = PantryItem.create!(name: "leeks", expires_on: 4.days.from_now.to_date)

    assert_includes PantryItem.expiring_soon, soon
    assert_includes PantryItem.expiring_soon, pantry_items(:milk)
    assert_includes PantryItem.expiring_soon, pantry_items(:yogurt)
    assert_not_includes PantryItem.expiring_soon, later
    assert_not_includes PantryItem.expiring_soon, pantry_items(:egg)
  end

  test "expiring_soon skips items with no expiry date" do
    assert_not_includes PantryItem.expiring_soon, pantry_items(:rice)
  end

  test "expiring_soon is ordered by expiry date" do
    PantryItem.delete_all
    PantryItem.create!(name: "kale", expires_on: 3.days.from_now.to_date)
    PantryItem.create!(name: "leeks", expires_on: 1.day.from_now.to_date)
    PantryItem.create!(name: "cream", expires_on: 1.day.ago.to_date)

    assert_equal %w[cream leek kale], PantryItem.expiring_soon.pluck(:name)
  end

  test "expiring_soon? matches the scope" do
    assert_predicate pantry_items(:milk), :expiring_soon?
    assert_not_predicate pantry_items(:egg), :expiring_soon?
    assert_not_predicate pantry_items(:rice), :expiring_soon?
  end

  test "grouped_by_location returns every location in enum order" do
    grouped = PantryItem.grouped_by_location

    assert_equal %w[pantry fridge freezer], grouped.keys
    assert_includes grouped["fridge"], pantry_items(:milk)
    assert_includes grouped["freezer"], pantry_items(:ground_beef)
    assert_equal [ "olive oil", "rice" ], grouped["pantry"].map(&:name)
  end

  test "grouped_by_location keeps empty locations" do
    PantryItem.delete_all

    assert_equal({ "pantry" => [], "fridge" => [], "freezer" => [] }, PantryItem.grouped_by_location)
  end

  test "grouped_by_location composes with other scopes" do
    grouped = PantryItem.expiring_soon.grouped_by_location

    assert_equal [ pantry_items(:milk), pantry_items(:yogurt) ].sort_by(&:name), grouped["fridge"].sort_by(&:name)
    assert_empty grouped["pantry"]
  end

  test "units_in_use lists each unit once, sorted, skipping items with none" do
    PantryItem.delete_all
    PantryItem.create!(name: "milk", unit: "gallon")
    PantryItem.create!(name: "cream", unit: "gallon")
    PantryItem.create!(name: "flour", unit: "kg")
    PantryItem.create!(name: "garlic")

    assert_equal %w[gallon kg], PantryItem.units_in_use
  end

  test "in_stock excludes anything at zero" do
    assert_includes PantryItem.in_stock, pantry_items(:milk)

    pantry_items(:milk).update!(quantity: 0)

    assert_not_includes PantryItem.in_stock, pantry_items(:milk)
    assert_not_predicate pantry_items(:milk), :in_stock?
  end

  test "in_stock_names lists each in-stock name once" do
    PantryItem.create!(name: "Rice", location: :fridge)
    pantry_items(:olive_oil).update!(quantity: 0)

    names = PantryItem.in_stock_names

    assert_equal 1, names.count("rice")
    assert_not_includes names, "olive oil"
  end

  # §5 — inventory changes are what archive a run. The three active fixture runs
  # use two, three and four pantry items respectively, so zeroing one item puts
  # each of them on a different side of the "more than a third out of stock" line.
  test "zeroing a quantity archives the runs it takes below the threshold" do
    pantry_items(:milk).update!(quantity: 0)

    assert_predicate suggestion_runs(:breakfast).reload, :archived?    # 1 of 2 left
    assert_not_predicate suggestion_runs(:dessert).reload, :archived?  # 2 of 3 left
    assert_not_predicate suggestion_runs(:beef_night).reload, :archived?
  end

  test "deleting an item archives the runs it takes below the threshold" do
    pantry_items(:milk).destroy!

    assert_predicate suggestion_runs(:breakfast).reload, :archived?
    assert_not_predicate suggestion_runs(:dessert).reload, :archived?
  end

  test "deleting an item another row still stocks changes nothing" do
    PantryItem.create!(name: "milk", location: :freezer, quantity: 2)

    pantry_items(:milk).destroy!

    assert_not_predicate suggestion_runs(:breakfast).reload, :archived?
  end

  test "adding stock or raising a quantity never archives" do
    pantry_items(:milk).update!(quantity: 0)
    suggestion_runs(:breakfast).update!(archived_at: nil)

    pantry_items(:milk).update!(quantity: 3)
    PantryItem.create!(name: "bok choi", location: :fridge)

    assert_not_predicate suggestion_runs(:breakfast).reload, :archived?
  end

  test "an update that leaves the quantity alone does not run the check" do
    pantry_items(:milk).update!(quantity: 0)
    suggestion_runs(:breakfast).update!(archived_at: nil)

    pantry_items(:milk).update!(unit: "litre")

    assert_not_predicate suggestion_runs(:breakfast).reload, :archived?
  end

  # §4.1 morphing — every write signals a page refresh on the one inventory
  # stream, which is what keeps a second tab in sync.
  test "creating, updating and destroying each broadcast a refresh to the inventory stream" do
    item = nil

    assert_turbo_stream_broadcasts PantryItem::INVENTORY_STREAM, count: 3 do
      perform_enqueued_jobs do
        item = PantryItem.create!(name: "kale", location: :fridge)
        item.update!(quantity: 2)
        item.destroy!
      end
    end
  end

  test "the broadcast is a page refresh, not a rendered partial" do
    broadcasts = capture_turbo_stream_broadcasts PantryItem::INVENTORY_STREAM do
      perform_enqueued_jobs { PantryItem.create!(name: "kale", location: :fridge) }
    end

    assert_equal "refresh", broadcasts.sole["action"]
  end
end
