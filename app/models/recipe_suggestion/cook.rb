# §4.3 — the "I made this" flow, behind the modal. Builds the deduction lines the
# dialog renders and applies the confirmed ones "in one transaction, which cascades
# naturally through mechanisms already designed": the pantry writes broadcast their
# own refreshes (PantryItem), and the zeroed rows trip the coverage check that
# archives stale runs (§5). Nothing here knows about any of that, which is the point.
#
# A plain object rather than an ActiveRecord model, the same shape PantryItem::QuickAdd
# took: this is input to a transaction, not a row. Nothing about a cooking is worth
# storing beyond the `cooked_at` it stamps and the quantities it moves.
class RecipeSuggestion::Cook
  # One row of the modal: a pantry item, how much of it to take, and whether the user
  # left it checked. `remaining` clamps at zero because the deduction is a statement
  # about what was cooked, not an accounting entry — a user who says they used more
  # than they had has an empty jar, not a negative one.
  Line = Struct.new(:pantry_item, :amount, :apply) do
    def apply?
      apply
    end

    def remaining
      [ pantry_item.quantity - amount, 0 ].max
    end
  end

  attr_reader :suggestion, :lines

  # `deductions` is the submitted `{ "<pantry_item_id>" => { apply:, amount: } }`.
  # Lines are built from the pantry rather than from the parameters, so an id that
  # isn't one of this suggestion's in-stock items simply has nothing to attach to.
  def initialize(suggestion, deductions = {})
    @suggestion = suggestion
    @deductions = (deductions || {}).to_h.with_indifferent_access
    @lines = build_lines
  end

  # Names the suggestion says it uses that no longer have an in-stock row. The modal
  # says so out loud — a cook who sees three ingredients listed for a four-ingredient
  # recipe should not have to work out which one the app quietly dropped.
  def unavailable_names
    suggestion.uses_items - lines.map { |line| line.pantry_item.name }
  end

  def applied
    lines.select(&:apply?)
  end

  def deducted_items
    applied.map(&:pantry_item)
  end

  # §4.3 — "Confirmation applies the deductions in one transaction". `cooked_at` is
  # part of it: either the pantry moved and the suggestion records why, or neither
  # happened. The commit callbacks the cascade rides on all fire after this returns,
  # so they see the finished pantry rather than a half-applied one.
  def apply!
    RecipeSuggestion.transaction do
      applied.each { |line| line.pantry_item.update!(quantity: line.remaining) }
      suggestion.update!(cooked_at: Time.current)
    end

    self
  end

  private
    def build_lines
      PantryItem.in_stock.where(name: suggestion.uses_items).ordered.map { |item| line_for(item) }
    end

    # The pre-fill is the whole quantity on hand, and it is a proposal, not a guess:
    # `uses_items` carries names only (§5's echo rule is about identity, not amounts),
    # so the app has no idea whether a recipe wanted one stalk of bok choi or three.
    # Proposing "you used it up" is the one starting point that needs no invention,
    # and it is what makes the checkbox mean something — unchecking says "that one
    # was a pinch, leave it alone". The alternative, defaulting to 1, would be a
    # guess dressed as modesty and wrong for everything sold by weight.
    def line_for(item)
      submitted = @deductions[item.id.to_s]
      return Line.new(item, item.quantity, true) if submitted.blank?

      Line.new(item, clamp(submitted[:amount], item), boolean(submitted[:apply]))
    end

    # Totals rather than validates: every submittable string has a sensible reading
    # here — junk and blanks deduct nothing, more than you own empties the row — so
    # there is no error state for the modal to render and no way to bounce a cook
    # the user already did.
    def clamp(amount, item)
      amount.to_s.to_d.clamp(0, item.quantity)
    end

    def boolean(value)
      ActiveModel::Type::Boolean.new.cast(value).present?
    end
end
