require "test_helper"

# §8's WebMock cases at the transport layer: the request we send, the continuation
# handshake, and every way the call can fail. `disable_net_connect!` in test_helper.rb
# means a missing stub here fails rather than dialing out.
class RecipeSearch::ClientTest < ActiveSupport::TestCase
  setup do
    @client = stubbed_search_client
    @prompt = RecipeSearch::Prompt.new(snapshot: InventorySnapshot.current)
  end

  # ── the SSE stubbing itself ─────────────────────────────────────────────────

  test "a fixture survives the round trip through the SSE stub" do
    # The stubs render a JSON Message into an event stream, which the SDK's accumulator
    # rebuilds. If that round trip lost anything, every other test here would be
    # asserting against a message the API would never send.
    stub_anthropic(:web_search_success)
    fixture = JSON.parse(anthropic_fixture(:web_search_success))

    reply = call

    assert_equal fixture["content"].map { |b| b["type"] }, reply.content.map { |b| b.type.to_s }
    assert_equal fixture["content"].select { |b| b["type"] == "text" }.map { |b| b["text"] }.join, reply.text
    assert_equal fixture.dig("usage", "input_tokens"), reply.usage.input_tokens
    assert_equal fixture.dig("usage", "output_tokens"), reply.usage.output_tokens
  end

  test "the request is streamed" do
    stub_anthropic(:web_search_success)
    call

    assert_equal true, anthropic_requests.sole["stream"],
      "a non-streaming call sits silent for minutes and trips its own timeout"
  end

  # ── the request we actually send ────────────────────────────────────────────

  test "the request names the cheap model tier and caps its spend" do
    stub_anthropic(:web_search_success)
    call

    body = anthropic_requests.sole

    assert_equal "claude-sonnet-5", body["model"]
    assert_equal RecipeSearch::Client::MAX_TOKENS, body["max_tokens"]
    assert_equal "medium", body.dig("output_config", "effort")
  end

  test "the web search tool is enabled with a use cap" do
    stub_anthropic(:web_search_success)
    call

    tool = anthropic_requests.sole["tools"].sole

    assert_equal "web_search_20260209", tool["type"]
    assert_equal "web_search", tool["name"]
    assert_equal RecipeSearch::Client::MAX_SEARCHES, tool["max_uses"]
  end

  test "the system prompt is sent as system, not as a message" do
    stub_anthropic(:web_search_success)
    call

    body = anthropic_requests.sole

    assert_match(/Retrieval, not invention/, body["system"])
    assert_equal [ "user" ], body["messages"].map { |m| m["role"] }
  end

  test "sampling parameters are not sent" do
    # §5 says "Temperature low", which this model tier rejects outright — see the
    # recap. Asserted so a well-meaning future edit reintroducing it fails here rather
    # than as a 400 in production.
    stub_anthropic(:web_search_success)
    call

    body = anthropic_requests.sole

    assert_not body.key?("temperature")
    assert_not body.key?("top_p")
    assert_not body.key?("top_k")
  end

  test "the reply carries only the model's own text, never the search results" do
    stub_anthropic(:web_search_success)

    reply = call

    # §5's content boundary starts here: the fixture's web_search_tool_result blocks
    # carry page content, and none of it reaches the caller. Nor does anything else
    # the turn accumulated — a real response opens with a thinking block and carries
    # the dynamic filter's own code_execution results, and `text` is only the model's
    # own words.
    assert_match(/"recipes"/, reply.text)
    assert_no_match(/encrypted_content/, reply.text)
    assert_no_match(/encrypted_stdout/, reply.text)

    assert_equal [ :thinking, :server_tool_use, :web_search_tool_result, :code_execution_tool_result, :text ],
      reply.content.map(&:type).uniq
    assert_equal 1, reply.content.count { |block| block.type == :text }
  end

  test "usage comes back for the caller to log" do
    stub_anthropic(:web_search_success)

    assert_equal 3, call.usage.server_tool_use.web_search_requests
  end

  # ── the pause_turn continuation ─────────────────────────────────────────────

  test "a pause_turn is resumed by replaying the turn" do
    stub_anthropic_sequence(:web_search_pause_turn, :web_search_success)

    reply = call

    assert_match(/"recipes"/, reply.text)
    assert_equal 2, anthropic_requests.size

    # The continuation hands the assistant turn back verbatim and adds no new user
    # message — a nudge there reads as a fresh instruction.
    continuation = anthropic_requests.last
    assert_equal %w[ user assistant ], continuation["messages"].map { |m| m["role"] }
  end

  test "an endless pause_turn loop is bounded" do
    stub_anthropic(:web_search_pause_turn)

    error = assert_raises(RecipeSearch::Client::Error) { call }

    assert_match(/did not finish after #{RecipeSearch::Client::MAX_CONTINUATIONS} continuations/, error.message)
    assert_equal RecipeSearch::Client::MAX_CONTINUATIONS + 1, anthropic_requests.size
  end

  # ── failure modes, all surfacing as one error type ──────────────────────────

  test "a timeout becomes a client error" do
    stub_anthropic_timeout

    assert_raises(RecipeSearch::Client::Error) { call }
  end

  test "a server error becomes a client error" do
    stub_anthropic_error(500)

    assert_raises(RecipeSearch::Client::Error) { call }
  end

  test "a rate limit becomes a client error" do
    stub_anthropic_error(429, type: "rate_limit_error", message: "Too many requests")

    assert_raises(RecipeSearch::Client::Error) { call }
  end

  test "an authentication failure becomes a client error" do
    stub_anthropic_error(401, type: "authentication_error", message: "invalid x-api-key")

    assert_raises(RecipeSearch::Client::Error) { call }
  end

  test "a truncated reply is reported as the cap it hit, not as bad JSON" do
    stub_anthropic(body: message_fixture(stop_reason: "max_tokens"))

    error = assert_raises(RecipeSearch::Client::Error) { call }

    assert_match(/token cap/, error.message)
  end

  test "a refusal is reported as a refusal" do
    stub_anthropic(body: message_fixture(stop_reason: "refusal"))

    error = assert_raises(RecipeSearch::Client::Error) { call }

    assert_match(/declined/, error.message)
  end

  test "every failure descends from RecipeSearch::Error so the job needs one rescue" do
    assert_operator RecipeSearch::Client::Error, :<, RecipeSearch::Error
    assert_operator RecipeSearch::Client::MissingCredentials, :<, RecipeSearch::Error
    assert_operator RecipeSearch::Parser::Malformed, :<, RecipeSearch::Error
  end

  # ── credentials ─────────────────────────────────────────────────────────────

  test "a missing api key raises before any request is made" do
    without_anthropic_credentials do
      assert_raises(RecipeSearch::Client::MissingCredentials) do
        RecipeSearch::Client.new.call(system: @prompt.system, messages: @prompt.messages)
      end
    end

    assert_not_requested :post, AnthropicTestHelper::MESSAGES_URL
  end

  test "the credentials helper is restored after the block" do
    # Guards the hand-rolled swap in without_anthropic_credentials: a leak here would
    # quietly disarm every other test's credential handling.
    without_anthropic_credentials { assert_nil RecipeSearch::Client.credentials_api_key }

    assert_equal Rails.application.credentials.dig(:anthropic, :api_key),
      RecipeSearch::Client.credentials_api_key
  end

  test "a blank api key is treated as missing" do
    assert_raises(RecipeSearch::Client::MissingCredentials) do
      RecipeSearch::Client.new(api_key: "  ").call(system: @prompt.system, messages: @prompt.messages)
    end
  end

  test "an injected key is used ahead of credentials" do
    stub_anthropic(:web_search_success)

    without_anthropic_credentials do
      client = RecipeSearch::Client.new(api_key: AnthropicTestHelper::TEST_API_KEY)

      assert_nothing_raised { client.call(system: @prompt.system, messages: @prompt.messages) }
    end
  end

  private
    def call
      @client.call(system: @prompt.system, messages: @prompt.messages)
    end

    def message_fixture(stop_reason:)
      JSON.parse(anthropic_fixture(:web_search_success))
        .merge("stop_reason" => stop_reason)
        .to_json
    end
end
