require "test_helper"

class RecipeTest < ActiveSupport::TestCase
  test "normalize_url strips query parameters and fragments" do
    assert_equal "https://example.com/gyudon",
      Recipe.normalize_url("https://example.com/gyudon?utm_source=newsletter&utm_medium=email")
    assert_equal "https://example.com/gyudon",
      Recipe.normalize_url("https://example.com/gyudon#print")
    assert_equal "https://example.com/gyudon",
      Recipe.normalize_url("https://example.com/gyudon?utm_source=x#ingredients")
  end

  test "normalize_url downcases the host but leaves the path alone" do
    assert_equal "https://www.example.com/Recipes/Gyudon",
      Recipe.normalize_url("HTTPS://WWW.Example.COM/Recipes/Gyudon")
  end

  test "normalize_url drops a trailing slash" do
    assert_equal "https://example.com/recipes/gyudon",
      Recipe.normalize_url("https://example.com/recipes/gyudon/")
    assert_equal "https://example.com", Recipe.normalize_url("https://example.com/")
  end

  test "normalize_url keeps a non-default port" do
    assert_equal "https://example.com:8443/gyudon", Recipe.normalize_url("https://example.com:8443/gyudon?x=1")
  end

  test "normalize_url returns nil for anything that isn't an http url with a host" do
    assert_nil Recipe.normalize_url(nil)
    assert_nil Recipe.normalize_url("")
    assert_nil Recipe.normalize_url("   ")
    assert_nil Recipe.normalize_url("not a url")
    assert_nil Recipe.normalize_url("/recipes/gyudon")
    assert_nil Recipe.normalize_url("javascript:alert(1)")
    assert_nil Recipe.normalize_url("ftp://example.com/gyudon")
  end

  test "source_url is normalized on assignment" do
    recipe = Recipe.new(source_url: " https://example.com/gyudon/?utm_source=x#print ")

    assert_equal "https://example.com/gyudon", recipe.source_url
  end

  test "a url that cannot be normalized is invalid" do
    assert_predicate Recipe.new(source_url: "not a url"), :invalid?
    assert_predicate Recipe.new(source_url: nil), :invalid?
  end

  # The acceptance check for this task: url variants must not split identity (§3).
  test "url variants of one recipe resolve to a single row" do
    canonical = "https://www.justonecookbook.com/gyudon"
    variants = [
      canonical,
      "#{canonical}?utm_source=pinterest",
      "#{canonical}/#recipe-card",
      "HTTPS://WWW.JustOneCookbook.com/gyudon"
    ]

    assert_no_difference -> { Recipe.count } do
      variants.each do |url|
        assert_equal recipes(:gyudon), Recipe.find_or_create_by(source_url: url)
      end
    end
  end

  test "the unique index refuses a second row for the same normalized url" do
    duplicate = Recipe.new(source_url: "#{recipes(:gyudon).source_url}?utm_source=x")

    assert_predicate duplicate, :invalid?
    assert_includes duplicate.errors[:source_url], "has already been taken"
  end

  test "upsert_by_source_url creates a recipe with its canonical facts" do
    recipe = nil

    assert_difference -> { Recipe.count }, 1 do
      recipe = Recipe.upsert_by_source_url(
        "https://smittenkitchen.com/2019/01/pasta/?ref=x",
        canonical_title: "Pasta with Garlic",
        source_name: "Smitten Kitchen"
      )
    end

    assert_equal "https://smittenkitchen.com/2019/01/pasta", recipe.source_url
    assert_equal "Pasta with Garlic", recipe.canonical_title
    assert_equal "Smitten Kitchen", recipe.source_name
  end

  test "upsert_by_source_url returns the existing recipe and keeps its verdict and title" do
    shakshuka = recipes(:shakshuka)

    assert_no_difference -> { Recipe.count } do
      found = Recipe.upsert_by_source_url(
        "#{shakshuka.source_url}?utm_campaign=weekly",
        canonical_title: "Some Other Title",
        source_name: "Some Other Site"
      )

      assert_equal shakshuka, found
      assert_equal "Shakshuka", found.canonical_title
      assert_equal "Serious Eats", found.source_name
      assert found.make_again
    end
  end

  test "upsert_by_source_url raises rather than persisting an unusable url" do
    assert_raises(ActiveRecord::RecordInvalid) { Recipe.upsert_by_source_url("not a url") }
  end

  # §5 — the two prompt lists. A recipe with no verdict belongs to neither.
  test "favorites and blocked select on the verdict, ignoring recipes never rated" do
    assert_equal [ recipes(:shakshuka) ], Recipe.favorites
    assert_equal [ recipes(:tuna_casserole) ], Recipe.blocked
    assert_nil recipes(:gyudon).make_again
    assert_not_predicate recipes(:gyudon), :favorite?
    assert_not_predicate recipes(:gyudon), :blocked?
  end

  test "the verdict predicates read the recipe, not the suggestion" do
    assert_predicate recipes(:shakshuka), :favorite?
    assert_predicate recipes(:tuna_casserole), :blocked?
  end

  # §3 — the reason the table exists: one recipe recurring across runs.
  test "a recipe carries its suggestions across runs" do
    gyudon = recipes(:gyudon)

    assert_equal [ recipe_suggestions(:beef_night_gyudon), recipe_suggestions(:history_gyudon) ].sort_by(&:id),
      gyudon.recipe_suggestions.sort_by(&:id)
    assert_equal [ suggestion_runs(:beef_night), suggestion_runs(:history) ].sort_by(&:id),
      gyudon.suggestion_runs.sort_by(&:id)
  end
end
