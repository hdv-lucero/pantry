require "test_helper"

class PantryItem::QuickAddTest < ActiveSupport::TestCase
  # The three cases the task calls out by name.

  test "parses name, quantity and unit out of the x notation" do
    parsed = PantryItem::QuickAdd.new("Bok Choi x3 stalks")

    assert_equal "Bok Choi", parsed.name
    assert_equal 3, parsed.quantity
    assert_equal "stalks", parsed.unit
  end

  test "parses name and quantity when no unit is given" do
    parsed = PantryItem::QuickAdd.new("milk x2")

    assert_equal "milk", parsed.name
    assert_equal 2, parsed.quantity
    assert_nil parsed.unit
  end

  test "treats a bare string as the whole name and defaults the quantity to one" do
    parsed = PantryItem::QuickAdd.new("eggs")

    assert_equal "eggs", parsed.name
    assert_equal 1, parsed.quantity
    assert_nil parsed.unit
  end

  # The parser reports what the text said; PantryItem is what normalizes it (§3).
  # These assert the pair, since that is what actually reaches the database.

  test "the parsed attributes build the item the user meant" do
    item = PantryItem.new(PantryItem::QuickAdd.new("Bok Choi x3 stalks").to_h.merge(location: :fridge))

    assert_equal "bok choi", item.name
    assert_equal 3, item.quantity
    assert_equal "stalks", item.unit
    assert_predicate item, :valid?
  end

  test "a bare plural name is singularized by the model" do
    item = PantryItem.new(PantryItem::QuickAdd.new("eggs").to_h)

    assert_equal "egg", item.name
    assert_equal 1, item.quantity
  end

  # Parsing details.

  test "keeps names that merely contain an x" do
    parsed = PantryItem::QuickAdd.new("box of wine")

    assert_equal "box of wine", parsed.name
    assert_equal 1, parsed.quantity
  end

  test "tolerates spacing and case around the x" do
    parsed = PantryItem::QuickAdd.new("  Greek   Yogurt   X 4   cups ")

    assert_equal "Greek Yogurt", parsed.name
    assert_equal 4, parsed.quantity
    assert_equal "cups", parsed.unit
  end

  test "parses fractional quantities" do
    parsed = PantryItem::QuickAdd.new("ground beef x1.5 lb")

    assert_equal BigDecimal("1.5"), parsed.quantity
    assert_equal "lb", parsed.unit
  end

  test "keeps multi-word units intact" do
    parsed = PantryItem::QuickAdd.new("tomatoes x2 large cans")

    assert_equal "tomatoes", parsed.name
    assert_equal "large cans", parsed.unit
  end

  test "reports a blank input as having no name" do
    parsed = PantryItem::QuickAdd.new("   ")

    assert_nil parsed.name
    assert_equal({ quantity: 1 }, parsed.to_h)
    assert_not_predicate PantryItem.new(parsed.to_h), :valid?
  end

  test "reports a nil input as having no name" do
    assert_nil PantryItem::QuickAdd.new(nil).name
  end

  test "omits keys the text said nothing about so form fields can be merged over it" do
    assert_equal({ name: "milk", quantity: 2 }, PantryItem::QuickAdd.new("milk x2").to_h)
  end
end
