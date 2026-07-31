class SuggestionRun < ApplicationRecord
  # §5 — "more than a third of used items out of stock" archives the run, so a run
  # survives while at least two thirds of what it leans on is still there. The
  # boundary is load-bearing: two of three items left is exactly a third missing,
  # which is not *more* than a third, so that run stays. Rational on both sides of
  # the comparison decides it by the rule rather than by which way a binary
  # fraction happened to round.
  COVERAGE_THRESHOLD = Rational(2, 3)

  # §5 cost control — "a per-day run limit enforced in the controller". Only the
  # constant and the predicate live here; the enforcement point is Task 6's controller,
  # which is where the doc puts it and the only place that can answer a refused
  # request with something a person sees.
  DAILY_LIMIT = 10

  # §4.2 — one stream for the whole suggestions view rather than the per-record
  # default, matching the choice PantryItem made in Task 3 for the same reason: a
  # second tab needs exactly one subscription, and a run created after that tab
  # loaded still reaches it.
  BROADCAST_STREAM = "suggestion_runs"

  has_many :recipe_suggestions, -> { ordered }, dependent: :destroy, inverse_of: :suggestion_run
  has_many :recipes, through: :recipe_suggestions

  enum :status, { queued: 0, running: 1, completed: 2, failed: 3 }

  # §4.2 — every status transition is broadcast, which is the whole of the queued →
  # running → completed/failed lifecycle the card animates through. Synchronous, not
  # `broadcast_replace_later_to`: this already runs inside SuggestRecipesJob, and
  # enqueuing a job from a job to render one partial would put the Solid Queue poll
  # interval between the model finishing and the user seeing it.
  after_update_commit :broadcast_card, if: :saved_change_to_status?

  # §5 — an archived run "disappear[s] from the main view into a browsable history",
  # and §4.3 wants that to happen on its own: the coverage check runs from a pantry
  # write, so nothing is rendering a view at the time and only a broadcast can take
  # the card off the screen. Unlike the refresh broadcasts the inventory uses, a
  # `remove` is not filtered by request id — which is what makes it reach the tab
  # that just confirmed a cook, not only the other one.
  #
  # A separate callback from `broadcast_card` rather than a branch inside it:
  # Rails deduplicates commit callbacks by method name, so the two have to be two.
  after_update_commit :broadcast_removal, if: :saved_change_to_archived_at?

  # §3 — JSON-in-text. The snapshot is what the model was shown, kept so a run
  # stays interpretable after the pantry moves on; nothing here reads it, and the
  # coverage check below deliberately measures against *live* inventory instead.
  serialize :inventory_snapshot, coder: JSON

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  # What the suggestions panel renders, with the two associations every card walks.
  # Three controllers answer with that panel — creating a run, cooking one, and
  # thumbing a recipe all re-render it — so the query they share is written once.
  #
  # `preload` rather than `includes`: this one loads as a join, and a joined run with
  # five cards is five rows. Rendering deduplicates them, but `count` and `pluck` do
  # not, so the scope would answer "12 active runs" to anyone who asked it that way.
  # Separate queries are what was wanted here anyway.
  scope :on_screen, -> { active.recent.preload(recipe_suggestions: :recipe) }

  # §5 cost control. Counted over runs created today rather than over API calls, so a
  # cache hit still spends from the allowance — the limit is there to bound a runaway
  # loop, and a loop that hits the cache every time is still a loop.
  scope :today, -> { where(created_at: Time.current.all_day) }

  def self.daily_limit_reached?
    today.count >= DAILY_LIMIT
  end

  # The job's own view of the same limit. Counts only the runs that came *before* this
  # one today, so it answers "is this run within the allowance?" rather than the class
  # method's "would a new run be?". Belt-and-suspenders in §5's established pattern:
  # the controller refuses to create the run, and this refuses to spend on it.
  def within_daily_limit?
    self.class.today.where(id: ...id).count < DAILY_LIMIT
  end

  # §4.2 step 2 — "The job snapshots the inventory into the run, flips status to
  # `running`". One write, so the card and the snapshot can never disagree.
  def start!(snapshot)
    update!(status: :running, inventory_snapshot: snapshot.as_json)
  end

  # §4.2 step 3. One transaction: either the run has all its cards or it has none and
  # is still `running` for the job's rescue to fail cleanly. `upsert_by_source_url` is
  # what gives a recipe recurring across runs one identity and one verdict (§3).
  def complete!(results)
    transaction do
      results.each do |attributes|
        attributes = attributes.dup
        recipe = Recipe.upsert_by_source_url(
          attributes.delete(:source_url),
          canonical_title: attributes[:title],
          source_name: attributes.delete(:source_name)
        )

        recipe_suggestions.create!(attributes.merge(recipe: recipe))
      end

      update!(status: :completed)
    end
  end

  # §4.2 step 4 — "status goes to `failed` with a human-readable message and a retry
  # button". The message reaches a person, so it is stored as written.
  def fail!(message)
    update!(status: :failed, error_message: message.to_s.truncate(500))
  end

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

  # §4.3 — a thumbs-down "archive[s] the card out of the active view (its siblings in
  # the run stay live)". No column and no scope: the verdict lives on the recipe, so
  # a blocked card is one whose recipe says so, and history is these same rows
  # rendered without the filter. Rejected in Ruby rather than joined in SQL so the
  # `on_screen` preload is used as loaded instead of being thrown away.
  def visible_suggestions
    recipe_suggestions.reject(&:blocked?)
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

  # §4.3 — "includes one of your favorites ★", the cheap join normalizing Recipe
  # bought. Task 6 renders it; it lives here because it is a fact about the run.
  def includes_favorite?
    recipes.favorites.exists?
  end

  private
    def broadcast_card
      broadcast_replace_to BROADCAST_STREAM,
        target: self,
        partial: "suggestion_runs/suggestion_run",
        locals: { suggestion_run: self }
    end

    def broadcast_removal
      broadcast_remove_to BROADCAST_STREAM, target: self
    end
end
