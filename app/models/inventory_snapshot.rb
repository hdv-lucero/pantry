# §3 — "`inventory_snapshot` on the run exists so a suggestion remains interpretable
# after the pantry changes; it also makes runs replayable when tuning the prompt."
#
# A plain value object over the JSON that lands in `suggestion_runs.inventory_snapshot`.
# It is the single definition of three things that have to agree exactly or the
# exact-name echo rule (§5) quietly breaks:
#
#   * what the model is shown          — `entries`
#   * what its echoes are checked against — `names`
#   * what the result cache is keyed by — `fingerprint`
#
# Only in-stock items are included. A zero-quantity row is a row you keep (you'll buy
# more milk) but not something a recipe can be made with, and it must not be offered as
# a substitution, so it never reaches the model at all.
class InventorySnapshot
  # The keys the prompt promises and the parser validates against. §5 lists
  # "(name, quantity, unit, expiry)".
  KEYS = %w[ name quantity unit expires_on ].freeze

  attr_reader :entries

  class << self
    # The live pantry, as the model should see it.
    def current(scope = PantryItem.in_stock)
      new(build_entries(scope))
    end

    # The pantry as some past run saw it. Round-trips through the JSON column, which
    # is why entries are string-keyed everywhere.
    def for(run)
      new(run.inventory_snapshot)
    end

    private
      # Grouped by name *and* unit rather than by name alone. Two rows of the same
      # thing are one ingredient to a recipe, so the model should see one line — but
      # only quantities in the same unit can be added up. "1 gallon" and "200 g" of
      # milk stay two lines rather than becoming a meaningless "201". Both lines carry
      # the same name, so the echo rule is unaffected either way.
      def build_entries(scope)
        scope.group_by { |item| [ item.name, item.unit ] }.map { |(name, unit), items|
          {
            "name" => name,
            "quantity" => items.sum { |item| item.quantity || 0 }.to_f,
            "unit" => unit,
            # The soonest expiry in the group is the one that should pull the model
            # toward this ingredient — §5 prefers "items nearing expiry".
            "expires_on" => items.filter_map(&:expires_on).min&.to_s
          }
        }.sort_by { |entry| [ entry["name"], entry["unit"].to_s ] }
      end
  end

  def initialize(entries)
    @entries = Array(entries).map { |entry| entry.to_h.stringify_keys.slice(*KEYS) }
  end

  # The exact-name vocabulary (§5). A Set because the parser tests membership once
  # per returned `uses_items` and `use_instead` value.
  def names
    @names ||= entries.map { |entry| entry["name"] }.compact.to_set
  end

  def include?(name)
    names.include?(name)
  end

  # §5's cost control: "cache by inventory fingerprint (Solid Cache, 1-hour TTL)".
  # Digested over the entries themselves, so it moves when anything the model would
  # see moves and stays put when only `updated_at` does. Entries are already sorted,
  # which is what makes the digest stable across two builds of the same pantry.
  def fingerprint
    @fingerprint ||= Digest::SHA256.hexdigest(entries.to_json)
  end

  def empty?
    entries.empty?
  end

  def as_json(*)
    entries
  end
end
