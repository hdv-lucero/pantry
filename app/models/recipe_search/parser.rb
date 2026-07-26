# §5 — "Parsing is defensive: strip code fences, `JSON.parse` inside a rescue,
# validate against the expected shape, retry once with an error-corrective message if
# malformed, then fail the run cleanly."
#
# Everything here treats the response as hostile-by-accident: the model is a good
# citizen most of the time, and the whole point of this class is the rest of the time.
# Two kinds of wrong get told apart, because they want different answers:
#
#   * `Malformed` — the response broke the contract. The caller retries once (§5).
#   * silently dropped — one recipe, substitution or name was unusable; the rest of
#     the response is fine and a retry would not improve it.
#
# The blocklist filter and the substitution check are both deliberately duplicated
# from the prompt. §5 calls this "belt-and-suspenders in the established pattern":
# the instruction asks, and this enforces, so a model that ignores the instruction
# cannot put a blocked recipe back on screen.
class RecipeSearch::Parser
  Malformed = Class.new(RecipeSearch::Error)

  REQUIRED_KEYS = %w[ title source_url summary uses_items missing_items substitutions ].freeze

  # §5 — "3–5 recipe cards". A response with more is not an error, it is just trimmed
  # after ranking so the extras that get cut are the worst-fitting ones.
  MAX_RESULTS = RecipeSearch::Prompt::TARGET_COUNT.max

  # §5's content boundary is a product promise ("never reproduce the source's
  # instructions or ingredient list"), so it gets an enforced ceiling and not only a
  # prompt sentence. Two sentences do not run to 400 characters; a pasted method does.
  SUMMARY_LIMIT = 400

  # §5's URL sanity check — "scheme, domain not obviously junk". `Recipe.normalize_url`
  # already guarantees http(s) with a host, so these are the checks it does not do.
  NON_PUBLIC_TLDS = %w[ local localhost internal test invalid example ].freeze

  attr_reader :snapshot, :blocked_urls

  def initialize(snapshot:, blocked_urls: default_blocked_urls)
    @snapshot = snapshot
    @blocked_urls = blocked_urls.to_set
  end

  # Returns an array of attribute hashes, ranked and positioned, ready to become
  # `RecipeSuggestion` rows. An empty array means the model genuinely found nothing —
  # not that everything it found was rejected, which raises instead.
  def call(text)
    recipes = extract_recipes(text)
    return [] if recipes.empty?

    results = recipes.filter_map { |recipe| build(recipe) }
    results = deduplicate(results)

    if results.empty?
      # The model answered, but nothing it returned survived validation. That is a
      # broken response rather than an empty pantry, so it is worth the one retry §5
      # allows — the corrective message names what went wrong.
      raise Malformed, "none of the #{recipes.size} #{'recipe'.pluralize(recipes.size)} returned were usable " \
                       "(check source URLs, and that uses_items are copied verbatim from the pantry)"
    end

    rank(results)
  end

  private
    # §5's parse ladder, loosest step last. Each rung is a real failure seen from
    # models: a fenced block, then prose wrapped around the object.
    def extract_recipes(text)
      payload = parse(text)

      unless payload.is_a?(Hash) && payload["recipes"].is_a?(Array)
        raise Malformed, "expected a JSON object with a \"recipes\" array, got #{payload.class.name.downcase}"
      end

      payload["recipes"].select { |recipe| recipe.is_a?(Hash) }
    end

    def parse(text)
      raise Malformed, "the response was empty" if text.blank?

      candidates = [ strip_fences(text), innermost_object(text) ].compact_blank.uniq
      error = nil

      candidates.each do |candidate|
        return JSON.parse(candidate)
      rescue JSON::ParserError => e
        error = e
      end

      raise Malformed, "the response was not valid JSON (#{error&.message&.truncate(120)})"
    end

    def strip_fences(text)
      text.strip.sub(/\A```(?:json)?\s*/i, "").sub(/```\s*\z/, "").strip
    end

    # Last resort for a model that wrapped the object in commentary. Spans the first
    # `{` to the last `}`, which is right for one top-level object and simply fails to
    # parse otherwise — it cannot turn a wrong response into a plausible one.
    def innermost_object(text)
      first, last = text.index("{"), text.rindex("}")
      text[first..last] if first && last && first < last
    end

    def build(recipe)
      missing_key = REQUIRED_KEYS.find { |key| !recipe.key?(key) }
      return drop(recipe, "missing the #{missing_key.inspect} field") if missing_key

      title = presence_of(recipe["title"])
      return drop(recipe, "no title") if title.nil?

      source_url = sanitized_url(recipe["source_url"])
      return drop(recipe, "unusable source_url #{recipe['source_url'].inspect}") if source_url.nil?

      # §5 — "any returned result whose normalized `source_url` upserts onto a
      # thumbs-downed recipe is dropped, so a blocked recipe cannot resurface even if
      # the model ignores the instruction."
      return drop(recipe, "on the do-not-suggest list") if blocked_urls.include?(source_url)

      uses_items = validated_uses_items(recipe["uses_items"], title:)
      # A recipe that uses nothing you own is not a suggestion, whatever else it got
      # right. This is also the backstop for a model that ignored the echo rule
      # wholesale — every name mismatched, so nothing is left.
      return drop(recipe, "uses none of the pantry") if uses_items.empty?

      missing_items = string_list(recipe["missing_items"])

      {
        title: title,
        source_url: source_url,
        source_name: presence_of(recipe["source_name"]) || host_of(source_url),
        summary: presence_of(recipe["summary"])&.truncate(SUMMARY_LIMIT),
        uses_items: uses_items,
        missing_items: missing_items,
        substitutions: validated_substitutions(recipe["substitutions"], missing_items:, title:)
      }
    end

    # §5's exact-name echo rule, the `uses_items` half: "any value that isn't an exact
    # match to a snapshot name is dropped (for subs) or flagged (for uses)."
    #
    # "Flagged" is not a column — §6's observability columns are explicitly later — so
    # it is a logged warning, and the unmatched name is left out of the stored list.
    # Keeping it would be worse than dropping it in both directions: coverage (§5)
    # would count a name that can never be in stock, archiving the run early, and the
    # "I made this" modal (§4.3) would offer a deduction against an item that does not
    # exist. The suggestion itself survives — that is what separates flagging from the
    # silent drop a bad substitution gets.
    def validated_uses_items(values, title:)
      matched, unmatched = string_list(values).partition { |name| snapshot.include?(name) }

      if unmatched.any?
        Rails.logger.warn(
          "[RecipeSearch] #{title.inspect}: dropped #{unmatched.size} uses_items not matching a pantry name " \
          "(#{unmatched.map(&:inspect).join(', ')})"
        )
      end

      matched
    end

    # §5 — "during parsing, any proposed `use_instead` that doesn't match an in-stock
    # item name in the snapshot is silently dropped." Silent because a substitution is
    # a bonus hint; losing one costs the card a muted line, not its meaning.
    #
    # The two halves are held to different standards on purpose. `use_instead` is a
    # pantry name that downstream code matches mechanically, so it must be exact.
    # `missing` is the recipe's own wording, shown to a person and never matched
    # against anything, so it is paired up case-insensitively and then re-stated using
    # the spelling from `missing_items` for a consistent card.
    def validated_substitutions(values, missing_items:, title:)
      return [] unless values.is_a?(Array)

      by_normalized_missing = missing_items.index_by { |item| item.downcase.squish }

      values.filter_map do |substitution|
        next unless substitution.is_a?(Hash)

        use_instead = presence_of(substitution["use_instead"])
        missing = by_normalized_missing[presence_of(substitution["missing"])&.downcase&.squish]

        next drop_substitution(title, substitution, "not in the pantry") unless use_instead && snapshot.include?(use_instead)
        next drop_substitution(title, substitution, "not one of the missing items") unless missing

        { "missing" => missing, "use_instead" => use_instead }
      end
    end

    # §5's link problem in its cheapest form. `normalize_url` proves it is http(s) with
    # a host (and strips tracking params so identity does not split); the rest rejects
    # hosts and paths no published recipe lives at.
    def sanitized_url(value)
      normalized = Recipe.normalize_url(value)
      return if normalized.nil?

      uri = URI.parse(normalized)
      host = uri.host.to_s

      return unless host.include?(".")
      return if host.match?(Resolv::IPv4::Regex) || host.match?(/\A\[?[0-9a-f:]+\]?\z/i)
      return if NON_PUBLIC_TLDS.include?(host.split(".").last.to_s.downcase)
      # A recipe lives at a path, never at a bare domain. This also catches the
      # homepage-plus-query shape (`https://site.com/?recipe=1234`), whose path is
      # empty once normalization strips the query. Sites that key recipes off a query
      # string on a real path remain the known gap normalization opened — no fixture
      # uses one, and nothing detects it yet.
      return if uri.path.blank?

      normalized
    rescue URI::InvalidURIError
      nil
    end

    # §3 — one row per recipe. Two cards for one URL in a single run would both upsert
    # onto the same `Recipe`, so the duplicate is dropped here rather than left to
    # surface as two identical cards.
    def deduplicate(results)
      results.uniq { |result| result[:source_url] }
    end

    # §4.2 — "sorted by fewest missing items". §5 is careful that this is "a defensible
    # heuristic, not a difficulty claim". Ties break on more pantry items used, then on
    # title, so the order is stable across runs rather than dependent on hash order.
    def rank(results)
      results
        .sort_by { |result| [ result[:missing_items].size, -result[:uses_items].size, result[:title].downcase ] }
        .first(MAX_RESULTS)
        .each_with_index { |result, index| result[:position] = index }
    end

    def string_list(values)
      return [] unless values.is_a?(Array)

      values.filter_map { |value| presence_of(value) }.uniq
    end

    def presence_of(value)
      value.to_s.squish.presence if value.is_a?(String) || value.is_a?(Numeric)
    end

    def host_of(url)
      URI.parse(url).host&.delete_prefix("www.")
    rescue URI::InvalidURIError
      nil
    end

    def drop(recipe, reason)
      Rails.logger.warn("[RecipeSearch] dropped #{recipe['title'].inspect}: #{reason}")
      nil
    end

    def drop_substitution(title, substitution, reason)
      Rails.logger.warn(
        "[RecipeSearch] #{title.inspect}: dropped substitution #{substitution['use_instead'].inspect} — #{reason}"
      )
      nil
    end

    def default_blocked_urls
      Recipe.blocked.pluck(:source_url)
    end
end
