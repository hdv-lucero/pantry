class PantryItem
  # §4.1 — the quick-add field takes "name x quantity unit" ("Bok Choi x3 stalks")
  # and falls back to treating the whole string as the name ("eggs"). Deliberately
  # a parser and nothing else: it reports what the text said and leaves defaulting,
  # normalizing and validating to PantryItem.
  class QuickAdd
    DEFAULT_QUANTITY = 1

    # The "x" has to stand as its own token, so names containing one survive
    # ("box of wine" is not a quantity of "bo"). The name is greedy, so the last
    # x-number in the string wins: "beer x6 x2" reads as two six-packs.
    NOTATION = /\A(?<name>.*\S)\s+x\s*(?<quantity>\d+(?:\.\d+)?)(?:\s+(?<unit>\S.*))?\z/i

    attr_reader :name, :quantity, :unit

    def initialize(input)
      text = input.to_s.squish

      if (notation = NOTATION.match(text))
        @name, @quantity, @unit = notation[:name], notation[:quantity].to_d, notation[:unit]
      else
        @name, @quantity, @unit = text.presence, DEFAULT_QUANTITY, nil
      end
    end

    # Only the keys the text actually spoke to, so the form's explicit fallback
    # fields can be merged over the top without nils clobbering them.
    def to_h
      { name: name, quantity: quantity, unit: unit }.compact
    end
  end
end
