class SuggestionRun < ApplicationRecord
  # §5 — "more than a third of used items out of stock" archives the run, so a run
  # survives while at least two thirds of what it leans on is still there. The
  # boundary is load-bearing: two of three items left is exactly a third missing,
  # which is not *more* than a third, so that run stays. Rational on both sides of
  # the comparison decides it by the rule rather than by which way a binary
  # fraction happened to round.
  COVERAGE_THRESHOLD = Rational(2, 3)

  has_many :recipe_suggestions, -> { ordered }, dependent: :destroy, inverse_of: :suggestion_run
  has_many :recipes, through: :recipe_suggestions

  enum :status, { queued: 0, running: 1, completed: 2, failed: 3 }

  # §3 — JSON-in-text. The snapshot is what the model was shown, kept so a run
  # stays interpretable after the pantry moves on; nothing here reads it, and the
  # coverage check below deliberately measures against *live* inventory instead.
  serialize :inventory_snapshot, coder: JSON

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  # §5 — the lightweight check inventory changes trigger (see PantryItem). A plain
  # scan of the active runs: single user, few active runs, and no denormalized
  # score to keep honest. Returns the runs it archived.
  def self.archive_stale!(in_stock_names = PantryItem.in_stock_names)
    active.includes(:recipe_suggestions)
          .select { |run| run.stale?(in_stock_names) }
          .each(&:archive!)
  end

  # The fraction of the items this run's suggestions rely on that are still in
  # stock (§5). One score per run, over the distinct names its suggestions use:
  # an item three cards call for is one item that can go missing, not three.
  #
  # Names are compared exactly. `uses_items` values are echoed verbatim from the
  # snapshot under the exact-name echo rule (§5), and the snapshot is built from
  # already-normalized PantryItem names, so both sides speak the same strings.
  def coverage(in_stock_names = PantryItem.in_stock_names)
    used = used_item_names
    return Rational(1) if used.empty?

    Rational((used & in_stock_names).size, used.size)
  end

  def used_item_names
    recipe_suggestions.flat_map(&:uses_items).uniq
  end

  def stale?(in_stock_names = PantryItem.in_stock_names)
    coverage(in_stock_names) < COVERAGE_THRESHOLD
  end

  # §5 — runs are archived, never deleted, and the first archiving wins: the
  # timestamp records when the pantry drifted away from this run, so a later check
  # must not push it forward.
  def archive!
    update!(archived_at: Time.current) unless archived?
  end

  def archived?
    archived_at.present?
  end
end
