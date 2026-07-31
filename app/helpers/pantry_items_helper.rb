module PantryItemsHelper
  # Stable Turbo Stream targets. The group frame wraps the whole location; the
  # list inside it is what creates append to, so the quick-add form above it
  # stays put.
  def location_frame_id(location)
    "location_#{location}"
  end

  def location_items_id(location)
    "#{location}_items"
  end

  def quick_add_id(location)
    "quick_add_#{location}"
  end

  def quick_add_field_id(location)
    "quick_add_field_#{location}"
  end

  # Quantities are decimal(8,2), so a plain 3 arrives as 3.0. Show what the user
  # typed, not what the column stores. Takes the number rather than the item because
  # the cooking modal (§4.3) formats a proposed deduction, which is a quantity
  # without a row of its own.
  def formatted_quantity(quantity)
    number_with_precision(quantity, precision: 2, strip_insignificant_zeros: true)
  end

  def expiry_label(pantry_item)
    case (pantry_item.expires_on - Date.current).to_i
    when ..-2 then "expired"
    when -1   then "expired yesterday"
    when 0    then "today"
    when 1    then "tomorrow"
    else           "in #{(pantry_item.expires_on - Date.current).to_i} days"
    end
  end
end
