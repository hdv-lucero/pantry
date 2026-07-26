# §5 — one round of "find me recipes for this pantry", start to finish: build the
# prompt, make the web-search call, parse the reply, and if the reply was malformed,
# spend exactly one corrective retry before giving up.
#
# Deliberately not an ActiveRecord object and deliberately ignorant of `SuggestionRun`.
# It takes a snapshot and gives back plain attribute hashes; the job owns persistence,
# status, and broadcasting. That split is what lets every rule in §5 be tested against
# a fixture with no database rows and no network.
class RecipeSearch
  # One error type for the job to rescue. `Client::Error` (transport, timeout,
  # refusal) and `Parser::Malformed` (unusable response) both descend from it, so
  # §4.2's "failed with a human-readable message" needs a single rescue.
  Error = Class.new(StandardError)

  # `text` is the raw reply the parse succeeded against. §5's cache stores *this*
  # rather than the parsed rows, so a cache hit re-runs the filters against the
  # current blocklist and current stock instead of replaying stale verdicts.
  Result = Data.define(:suggestions, :text, :usage)

  attr_reader :snapshot, :notes

  def initialize(snapshot:, notes: nil, client: RecipeSearch::Client.new, parser: nil)
    @snapshot = snapshot
    @notes = notes
    @client = client
    @parser = parser || RecipeSearch::Parser.new(snapshot: snapshot)
  end

  def call
    prompt = RecipeSearch::Prompt.new(snapshot: snapshot, notes: notes)
    messages = prompt.messages
    reply = @client.call(system: prompt.system, messages: messages)

    begin
      Result.new(suggestions: @parser.call(reply.text), text: reply.text, usage: reply.usage)
    rescue Parser::Malformed => e
      raise if @retried

      @retried = true
      Rails.logger.warn("[RecipeSearch] retrying once after a malformed response: #{e.message}")

      # The model's own turn is replayed back to it — including the search-result
      # blocks — so the correction reads as "fix what you just wrote" rather than
      # "start over", and it does not pay for a second round of searching.
      messages += [
        { role: :assistant, content: reply.content },
        { role: :user, content: prompt.correction_message(e.message) }
      ]
      reply = @client.call(system: prompt.system, messages: messages)
      retry
    end
  end
end
