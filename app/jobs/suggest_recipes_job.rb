# §4.2 — the job behind "Suggest recipes". Snapshots the inventory onto the run,
# flips it to `running`, makes the web-search call, and either persists the cards or
# fails the run with something a person can read. Every status write broadcasts
# (SuggestionRun#broadcast_card), so the card in the browser follows along.
#
# Errors end the run rather than raising. §4.2 step 4 puts a retry button on the failed
# card, which makes retrying a decision the user makes — and §5 is emphatic that "new
# LLM calls happen only on explicit user action". An ActiveJob `retry_on` here would
# quietly spend the same money two more times on a pantry nobody is looking at.
class SuggestRecipesJob < ApplicationJob
  # §5 — "the inventory-fingerprint cache (Solid Cache, 1-hour TTL) already dedupes
  # repeat requests against an unchanged pantry."
  CACHE_TTL = 1.hour
  CACHE_NAMESPACE = "recipe_search"

  # §5 — "the job wrapped in a timeout". This is the outer wall-clock budget over the
  # whole exchange; RecipeSearch::Client::REQUEST_TIMEOUT bounds each individual HTTP
  # request. Both exist because one call is not the same as one job: a corrective
  # retry plus server-side search continuations can be several requests, each of them
  # individually on time.
  #
  # Sized off a measured 258s for a single call, which has to leave room for §5's
  # corrective retry on top. A budget that cannot fit the retry fires on healthy runs
  # and the retry never happens — which is what a 5-minute budget against a 4.3-minute
  # call did. Long-lived by design: §4.2 has the user watching a card, not a spinner
  # they are blocked on.
  TIMEOUT = 20.minutes

  # A run that no longer exists is not worth an exception in the log.
  discard_on ActiveJob::DeserializationError

  def perform(run)
    return unless run.queued?

    snapshot = InventorySnapshot.current
    run.start!(snapshot)

    return run.fail!("Your pantry is empty — add a few items and try again.") if snapshot.empty?
    return run.fail!("That's #{SuggestionRun::DAILY_LIMIT} suggestion runs today. Try again tomorrow.") unless run.within_daily_limit?

    run.complete!(search(snapshot, run.prompt_notes))
  rescue RecipeSearch::Error => e
    # The message reaches the card, so it is written for a cook, not an operator. The
    # cause is logged in full for whoever has to debug it.
    Rails.logger.error("[SuggestRecipesJob] run #{run.id} failed: #{e.class} — #{e.message}")
    run.fail!(user_facing_message(e))
  rescue Timeout::Error
    Rails.logger.error("[SuggestRecipesJob] run #{run.id} timed out after #{TIMEOUT.inspect}")
    run.fail!("The search took too long. Try again?")
  end

  private
    def search(snapshot, notes)
      # `Timeout.timeout` around live socket IO is a blunt instrument — it can cut a
      # request at an arbitrary point — but the thing it guards is a job whose only
      # failure mode is a run marked failed, and the alternative is a run stuck on
      # `running` forever if a request somehow outlives its own timeout.
      Timeout.timeout(TIMEOUT) do
        parser = RecipeSearch::Parser.new(snapshot: snapshot)

        cached(snapshot, notes, parser) || live(snapshot, notes, parser)
      end
    end

    # §5's cache stores the raw reply, not the parsed rows, so the filters re-run on
    # every hit. That matters: the fingerprint covers the pantry, but a recipe can be
    # thumbs-downed between two identical requests, and §5 promises a blocked recipe
    # "cannot resurface". Caching the rows would resurface it for up to an hour.
    def cached(snapshot, notes, parser)
      text = Rails.cache.read(cache_key(snapshot, notes))
      return if text.blank?

      parser.call(text).tap { Rails.logger.info("[SuggestRecipesJob] cache hit for #{snapshot.fingerprint[0, 12]}") }
    rescue RecipeSearch::Parser::Malformed
      # Everything in a still-valid response was filtered out — the blocklist grew
      # since it was stored. Treat it as a miss and pay for a fresh search.
      nil
    end

    def live(snapshot, notes, parser)
      result = RecipeSearch.new(snapshot: snapshot, notes: notes, parser: parser).call
      Rails.cache.write(cache_key(snapshot, notes), result.text, expires_in: CACHE_TTL)
      result.suggestions
    end

    # Notes are part of the key, not just the fingerprint: "something quick" and
    # "vegetarian" against the same pantry are different questions. §5 says "an
    # identical re-request", and the note is part of what makes a request identical.
    def cache_key(snapshot, notes)
      [ CACHE_NAMESPACE, snapshot.fingerprint, Digest::SHA256.hexdigest(notes.to_s) ]
    end

    def user_facing_message(error)
      case error
      when RecipeSearch::Client::MissingCredentials
        "Recipe suggestions aren't configured yet."
      when RecipeSearch::Parser::Malformed
        "The recipe search came back garbled. Try again?"
      else
        "Couldn't reach the recipe search. Try again?"
      end
    end
end
