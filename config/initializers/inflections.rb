# Be sure to restart your server when you modify this file.

# Add new inflection rules using the following format. Inflections
# are locale specific, and you may define rules for as many different
# locales as you wish. All of these examples are active by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.plural /^(ox)$/i, "\\1en"
#   inflect.singular /^(ox)en/i, "\\1"
#   inflect.irregular "person", "people"
#   inflect.uncountable %w( fish sheep )
# end

# These inflection rules are supported but not enabled by default:
# ActiveSupport::Inflector.inflections(:en) do |inflect|
#   inflect.acronym "RESTful"
# end

# PantryItem singularizes names on save (§3), which walks the default inflector
# into a handful of food words it gets wrong: "asparagus" -> "asparagu",
# "olives" -> "olife", "pasta" -> "pastum". Teach it the ones a real pantry
# actually contains.
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.uncountable %w[asparagus couscous grits hummus molasses pasta]
  inflect.irregular "clove", "cloves"
  inflect.irregular "leaf", "leaves"
  inflect.irregular "loaf", "loaves"
  inflect.irregular "olive", "olives"
end
