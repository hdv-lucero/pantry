require "test_helper"

class PantryItemsControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @user = users(:one)
    @milk = pantry_items(:milk)
    sign_in_as @user
  end

  test "requires authentication" do
    sign_out

    get root_path

    assert_redirected_to new_session_path
  end

  test "index groups every location and renders the use soon section" do
    get root_path

    assert_response :success
    assert_select "turbo-frame#location_pantry"
    assert_select "turbo-frame#location_fridge"
    assert_select "turbo-frame#location_freezer"
    assert_select "section#use_soon", /milk/
    assert_select "turbo-frame##{dom_id(@milk)}"
  end

  test "index offers the units already in use as a datalist" do
    get root_path

    assert_select "datalist#unit_suggestions option[value=?]", "gallon"
  end

  # §4.2's panel shares this screen with the inventory so §4.3's cascade is visible
  # in one place. Archived runs are not on it — they are in the history (§5).
  test "index carries the suggestions panel with the active runs and the modal frame" do
    get root_path

    assert_select "section#suggestions"
    assert_select "div#suggestion_runs_list div##{dom_id(suggestion_runs(:beef_night))}"
    assert_select "div##{dom_id(suggestion_runs(:history))}", false
    assert_select "turbo-frame#modal", count: 1
  end

  # (a) quick add

  test "quick add parses the x notation and streams the row into its group" do
    assert_difference -> { PantryItem.count }, 1 do
      post pantry_items_path, params: { pantry_item: { quick_add: "Bok Choi x3 stalks", location: "fridge" } },
           as: :turbo_stream
    end

    item = PantryItem.order(:created_at).last
    assert_equal [ "bok choi", 3, "stalks", "fridge" ], [ item.name, item.quantity, item.unit, item.location ]

    assert_response :success
    assert_equal Mime[:turbo_stream], response.media_type
    assert_select "turbo-stream[action=append][target=fridge_items]"
    assert_select "turbo-stream[action=replace][target=quick_add_fridge]"
    assert_select "turbo-stream[action=replace][target=use_soon]"
  end

  test "quick add falls back to the whole string as the name" do
    post pantry_items_path, params: { pantry_item: { quick_add: "eggs", location: "pantry" } }, as: :turbo_stream

    item = PantryItem.order(:created_at).last
    assert_equal [ "egg", 1, "pantry" ], [ item.name, item.quantity, item.location ]
  end

  test "explicit fallback fields win over the parsed notation" do
    post pantry_items_path,
         params: { pantry_item: { quick_add: "milk x2", location: "fridge", quantity: "5", unit: "litres", category: "dairy" } },
         as: :turbo_stream

    item = PantryItem.order(:created_at).last
    assert_equal [ "milk", 5, "litres", "dairy" ], [ item.name, item.quantity, item.unit, item.category ]
  end

  test "blank fallback fields leave the parsed values alone" do
    post pantry_items_path,
         params: { pantry_item: { quick_add: "milk x2", location: "fridge", quantity: "", unit: "", category: "", expires_on: "" } },
         as: :turbo_stream

    item = PantryItem.order(:created_at).last
    assert_equal 2, item.quantity
    assert_nil item.unit
    assert_nil item.category
  end

  test "quick add rejects an empty input and re-renders only that group's form" do
    assert_no_difference -> { PantryItem.count } do
      post pantry_items_path, params: { pantry_item: { quick_add: "", location: "freezer" } }, as: :turbo_stream
    end

    assert_response :unprocessable_content
    assert_select "turbo-stream[action=replace][target=quick_add_freezer]", 1
    assert_select "turbo-stream", 1
  end

  # (b) inline edit

  test "edit renders the form inside the row's frame" do
    get edit_pantry_item_path(@milk)

    assert_response :success
    assert_select "turbo-frame##{dom_id(@milk)} form"
  end

  test "update streams the row back in place" do
    patch pantry_item_path(@milk), params: { pantry_item: { name: "Oat Milk", unit: "cartons" } }, as: :turbo_stream

    assert_response :success
    assert_equal "oat milk", @milk.reload.name
    assert_select "turbo-stream[action=replace][target=?]", dom_id(@milk)
  end

  test "update moves the row between groups when the location changes" do
    patch pantry_item_path(@milk), params: { pantry_item: { location: "freezer" } }, as: :turbo_stream

    assert_equal "freezer", @milk.reload.location
    assert_select "turbo-stream[action=remove][target=?]", dom_id(@milk)
    assert_select "turbo-stream[action=append][target=freezer_items]"
  end

  test "an invalid update re-renders the edit form in the frame" do
    patch pantry_item_path(@milk), params: { pantry_item: { name: "" } }, as: :turbo_stream

    assert_response :unprocessable_content
    assert_equal "milk", @milk.reload.name
    assert_select "turbo-frame##{dom_id(@milk)} form"
  end

  # (c) quantity stepper — the same update action, reached with only a quantity

  test "the stepper patches quantity alone" do
    patch pantry_item_path(@milk), params: { pantry_item: { quantity: "4" } }, as: :turbo_stream

    assert_response :success
    assert_equal 4, @milk.reload.quantity
    assert_select "turbo-stream[action=replace][target=?]", dom_id(@milk)
  end

  test "the stepper cannot patch a negative quantity" do
    patch pantry_item_path(@milk), params: { pantry_item: { quantity: "-1" } }, as: :turbo_stream

    assert_response :unprocessable_content
    assert_equal 1, @milk.reload.quantity
  end

  # destroy

  test "destroy removes the row and refreshes the use soon section" do
    assert_difference -> { PantryItem.count }, -1 do
      delete pantry_item_path(@milk), as: :turbo_stream
    end

    assert_select "turbo-stream[action=remove][target=?]", dom_id(@milk)
    assert_select "turbo-stream[action=replace][target=use_soon]"
  end

  # Non-Turbo fallbacks, so the screen still works with JavaScript off.

  test "create redirects to the inventory for a plain HTML request" do
    post pantry_items_path, params: { pantry_item: { quick_add: "lentils x2 cups", location: "pantry" } }

    assert_redirected_to pantry_items_path
  end

  test "destroy redirects to the inventory for a plain HTML request" do
    delete pantry_item_path(@milk)

    assert_redirected_to pantry_items_path
  end
end
