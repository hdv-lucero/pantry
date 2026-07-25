require "application_system_test_case"

class InventoryTest < ApplicationSystemTestCase
  setup do
    @milk = pantry_items(:milk)
    @row = "#pantry_item_#{@milk.id}"

    sign_in_as users(:one)
  end

  test "the inventory is grouped by location with a server-rendered use soon section" do
    assert_selector "turbo-frame#location_pantry h2", text: "Pantry"
    assert_selector "turbo-frame#location_fridge h2", text: "Fridge"
    assert_selector "turbo-frame#location_freezer h2", text: "Freezer"

    within "#fridge_items" do
      assert_text "milk"
      assert_text "in 2 days"       # inside the three-day window, so it gets a badge
      assert_no_text "in 10 days"   # the eggs are dated but not urgent — no badge
    end

    within "#use_soon" do
      assert_text "milk"
      assert_text "greek yogurt"      # already expired — still worth using up
      assert_no_text "olive oil"      # no expiry at all
    end
  end

  # (a) quick add

  test "quick add parses the x notation and appends the row to its group" do
    within "#quick_add_fridge" do
      fill_in "Add to fridge", with: "Bok Choi x3 stalks"
      click_button "Add"
    end

    within "#fridge_items" do
      assert_text "bok choi stalks"
      assert_field "Quantity of bok choi", with: "3"
    end

    assert_field "Add to fridge", with: ""
    assert_equal "bok choi", PantryItem.order(:created_at).last.name
  end

  test "quick add falls back to the whole string as the name" do
    within "#quick_add_pantry" do
      fill_in "Add to pantry", with: "eggs"
      click_button "Add"
    end

    within "#pantry_items" do
      assert_text "egg"
      assert_field "Quantity of egg", with: "1"
    end
  end

  test "the fallback fields override the parsed notation" do
    within "#quick_add_freezer" do
      fill_in "Add to freezer", with: "peas x2"
      find("summary", text: "Details").click
      fill_in "Quantity", with: "500"
      fill_in "Unit", with: "g"
      click_button "Add"
    end

    within "#freezer_items" do
      assert_text "pea g"
      assert_field "Quantity of pea", with: "500"
    end
  end

  test "an empty quick add reports the error without touching the other groups" do
    within "#quick_add_freezer" do
      click_button "Add"
    end

    within "#quick_add_freezer" do
      assert_text "Name can't be blank"
    end

    within "#quick_add_fridge" do
      assert_no_text "Name can't be blank"
    end
  end

  # (b) inline edit

  test "clicking an item swaps its row for a form and saving swaps it back" do
    within(@row) { click_link "milk gallon" }

    within(@row) do
      assert_field "Name", with: "milk"
      fill_in "Name", with: "Oat Milk"
      fill_in "Unit", with: "cartons"
      click_button "Save"
    end

    within(@row) do
      assert_text "oat milk cartons"
      assert_no_selector "form input[type=text]"
    end

    assert_equal "oat milk", @milk.reload.name
  end

  test "cancelling an inline edit restores the row unchanged" do
    within(@row) { click_link "milk gallon" }

    within(@row) do
      fill_in "Name", with: "something else"
      click_link "Cancel"
    end

    within(@row) { assert_text "milk gallon" }
    assert_equal "milk", @milk.reload.name
  end

  test "editing the location moves the row into the other group" do
    within(@row) { click_link "milk gallon" }

    within(@row) do
      select "Freezer", from: "Location"
      click_button "Save"
    end

    within("#freezer_items") { assert_text "milk gallon" }
    within("#fridge_items") { assert_no_text "milk gallon" }
  end

  # (c) quantity stepper

  test "the stepper debounces repeated taps into a single saved quantity" do
    within(@row) do
      click_button "Increase milk"
      click_button "Increase milk"
      click_button "Increase milk"
    end

    assert_stored_quantity @milk, 4

    page.refresh
    within(@row) { assert_field "Quantity of milk", with: "4" }
  end

  test "the stepper will not step below zero" do
    within(@row) do
      click_button "Decrease milk"
      click_button "Decrease milk"
    end

    assert_stored_quantity @milk, 0

    page.refresh
    within(@row) { assert_field "Quantity of milk", with: "0" }
  end

  test "typing a quantity directly saves it too" do
    within(@row) { fill_in "Quantity of milk", with: "2.5" }
    find("h1").click # blur, so the field's change event fires

    assert_stored_quantity @milk, BigDecimal("2.5")
  end

  # Removing

  test "removing an item drops it from its group and from use soon" do
    within(@row) { click_button "Remove milk" }

    assert_no_selector @row
    within("#use_soon") { assert_no_text "milk" }
  end
end
