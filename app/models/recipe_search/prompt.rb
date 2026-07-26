# §5 — "The prompt". Builds the two halves of the request and nothing else: no API
# call, no parsing, so the wording is diffable and testable on its own.
#
# The split between `system` and `user_message` is deliberate. `system` is frozen
# text — the same bytes on every call — while everything that varies per request
# (inventory, notes, preference lists) goes in the user message. That is the ordering
# prompt caching wants, so if the system prompt ever grows past the cacheable minimum
# a `cache_control` breakpoint can be added with no restructuring. It is well under
# that minimum today, so adding one now would cost a little noise and cache nothing.
class RecipeSearch::Prompt
  # §5 — "find 3–5 existing, published recipes".
  TARGET_COUNT = 3..5

  # §5's fixed schema, quoted into the system prompt and enforced by the parser.
  SCHEMA = <<~JSON.strip
    {
      "recipes": [
        {
          "title": "the recipe's title, as the source page gives it",
          "source_url": "the exact URL of the recipe page you visited",
          "source_name": "the publication or site name, e.g. 'Just One Cookbook'",
          "summary": "one or two sentences, in your own words",
          "uses_items": ["pantry item name", "..."],
          "missing_items": ["ingredient the pantry lacks", "..."],
          "substitutions": [{ "missing": "a missing_items entry", "use_instead": "pantry item name" }]
        }
      ]
    }
  JSON

  attr_reader :snapshot, :notes, :favorites, :blocked

  def initialize(snapshot:, notes: nil, favorites: Recipe.favorites, blocked: Recipe.blocked)
    @snapshot = snapshot
    @notes = notes.presence
    @favorites = favorites
    @blocked = blocked
  end

  # Frozen across requests — see the note above about caching.
  def system
    <<~PROMPT.strip
      You match a home cook's pantry against recipes that already exist on the web.

      ## Retrieval, not invention

      You do not write recipes. Every suggestion you return must be a specific,
      already-published recipe page that you found with the `web_search` tool during
      this conversation and could link a person to right now. Search before you
      answer — always, even when you are confident you know a suitable recipe from
      memory, because a remembered URL is a guess and a guess here is a dead link.
      Never assemble a plausible-looking URL, never return a search results page, a
      category or tag listing, or a site's front page, and never return a recipe you
      did not actually see in a search result.

      If you cannot find #{TARGET_COUNT.min} suitable recipes, return the ones you did
      find. Returning two real recipes is a good answer; padding to #{TARGET_COUNT.max}
      with inventions is a broken one.

      ## What makes a good match

      Aim for #{TARGET_COUNT.min}–#{TARGET_COUNT.max} recipes that lean substantially on
      what the cook already has, preferring recipes that use items close to expiry.

      Exact pantry coverage is explicitly not required. A genuinely good published
      recipe that needs one or two ordinary purchasable extras beats a contrived
      perfect match every time. Do not distort a recipe's real ingredient list to make
      the overlap look better — report it honestly and let the cook judge.

      ## Naming: echo the pantry's words back verbatim

      This one is mechanical and it matters more than it looks. Every value in
      `uses_items`, and every `use_instead` in `substitutions`, must be copied
      character for character from the `name` of an item in the pantry list you are
      given. Not the recipe's word for the ingredient — the pantry's word.

      If the recipe calls for "pak choi" and the pantry says "bok choi", write
      "bok choi". If the recipe wants "scallions" and the pantry has "spring onion",
      write "spring onion". You can see both lists; do that translation yourself.
      Anything that is not an exact match to a pantry name is discarded downstream, so
      an approximate spelling is the same as saying nothing.

      `missing_items` is the opposite case: those are ingredients the pantry does not
      have, so name them in the recipe's own words.

      ## Substitutions

      Optional, and only ever for something in `missing_items`. A substitution must
      point at an item the pantry actually holds — `use_instead` follows the same
      verbatim-echo rule as `uses_items`. Suggest one only where the swap genuinely
      works in that dish; a bad substitution is worse than none. If nothing on hand
      substitutes, leave the array empty.

      ## Use your own words

      Write your own one-to-two-sentence summary of what the dish is and why it suits
      this pantry. Do not reproduce the source's instructions, its ingredient list, or
      its prose — not in the summary, not anywhere. The link is how a cook gets the
      recipe; your job is the matchmaking, not the reprint.

      ## Response format

      Reply with a single JSON object and nothing else — no preamble, no explanation,
      no markdown fences, no commentary after it. It must match this shape exactly:

      #{SCHEMA}

      Every field is required on every recipe. Use `[]` for empty lists, never null.
    PROMPT
  end

  def messages
    [ { role: "user", content: user_message } ]
  end

  def user_message
    sections = [ "Here is everything in the pantry right now:\n\n#{inventory_lines}" ]
    sections << "The cook also said: #{notes}" if notes
    sections << favorites_section if favorites.any?
    sections << blocked_section if blocked.any?
    sections << "Search the web and reply with the JSON object."
    sections.join("\n\n")
  end

  # §5 — "retry once with an error-corrective message if malformed". Sent as a second
  # user turn after the model's own reply, so it can see what it produced and what was
  # wrong with it rather than starting over blind.
  def correction_message(error)
    <<~PROMPT.strip
      That response could not be parsed: #{error}

      Reply again with the same recipes — the ones you already found, do not search
      again — as a single JSON object matching the required shape exactly. No prose
      before or after it, no markdown fences, no trailing commas. Every recipe needs
      all seven fields, and `uses_items` and `use_instead` values must be copied
      verbatim from the pantry names above.
    PROMPT
  end

  private
    def inventory_lines
      snapshot.entries.map { |entry| "- #{inventory_line(entry)}" }.join("\n")
    end

    def inventory_line(entry)
      amount = [ format_quantity(entry["quantity"]), entry["unit"] ].compact_blank.join(" ")
      line = entry["name"].dup
      line << " (#{amount})" if amount.present?
      line << " — #{expiry_note(entry['expires_on'])}" if entry["expires_on"].present?
      line
    end

    # "in 2 days" is what actually drives §5's "preferring items nearing expiry"; the
    # bare date would make the model do calendar arithmetic against a today it has to
    # guess at.
    def expiry_note(expires_on)
      days = (Date.parse(expires_on) - Date.current).to_i

      case days
      when ..-1 then "expired #{-days} #{'day'.pluralize(-days)} ago"
      when 0 then "expires today"
      else "expires in #{days} #{'day'.pluralize(days)}"
      end
    rescue Date::Error
      "expires #{expires_on}"
    end

    def format_quantity(quantity)
      return if quantity.blank?

      number = quantity.to_d
      number == number.to_i ? number.to_i.to_s : number.to_s("F")
    end

    # §5's preference lists, "sent as title + source URL".
    def favorites_section
      <<~SECTION.strip
        The cook has marked these recipes as ones they'd make again. If one of them
        fits this pantry well, resurface it — otherwise ignore this list.

        #{recipe_lines(favorites)}
      SECTION
    end

    def blocked_section
      <<~SECTION.strip
        Do not suggest these recipes. The cook has ruled them out.

        #{recipe_lines(blocked)}
      SECTION
    end

    def recipe_lines(recipes)
      recipes.map { |recipe| "- #{recipe.canonical_title.presence || 'Untitled'} — #{recipe.source_url}" }.join("\n")
    end
end
