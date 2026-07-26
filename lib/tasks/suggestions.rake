namespace :suggestions do
  desc "Make one real web-search call against the seeded pantry and save it as the success fixture (costs a live API call)"
  task capture_fixture: :environment do
    fixture = Rails.root.join("test/fixtures/files/anthropic/web_search_success.json")

    snapshot = InventorySnapshot.current
    abort "The pantry is empty — run bin/rails db:seed first." if snapshot.empty?

    unless Rails.application.credentials.dig(:anthropic, :api_key).present?
      abort "No anthropic.api_key in credentials."
    end

    prompt = RecipeSearch::Prompt.new(snapshot: snapshot)
    puts "Calling #{RecipeSearch::Client::MODEL} with #{snapshot.entries.size} pantry entries. This is a real, billable call…"

    # Deliberately the raw SDK response rather than RecipeSearch's parsed output: the
    # point of the fixture is the envelope, including the search-result blocks the
    # parser never sees.
    message = Anthropic::Client
      .new(api_key: Rails.application.credentials.dig(:anthropic, :api_key))
      .messages.create(
        model: RecipeSearch::Client::MODEL,
        max_tokens: RecipeSearch::Client::MAX_TOKENS,
        system_: prompt.system,
        messages: prompt.messages,
        tools: [ { type: RecipeSearch::Client::WEB_SEARCH_TOOL_TYPE, name: "web_search",
                   max_uses: RecipeSearch::Client::MAX_SEARCHES } ],
        output_config: { effort: RecipeSearch::Client::EFFORT },
        request_options: { timeout: RecipeSearch::Client::REQUEST_TIMEOUT }
      )

    fixture.write(JSON.pretty_generate(message.to_h) + "\n")

    puts "Wrote #{fixture.relative_path_from(Rails.root)}"
    puts "  stop_reason: #{message.stop_reason}"
    puts "  usage: #{message.usage.input_tokens} in / #{message.usage.output_tokens} out, " \
         "#{message.usage.server_tool_use&.web_search_requests || 0} searches"
    puts
    puts "Now update the provenance note in test/fixtures/files/anthropic/README.md, and"
    puts "re-point parser_test.rb's success-path assertions at whatever recipes came back."
  end
end
