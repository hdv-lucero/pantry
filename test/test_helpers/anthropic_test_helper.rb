# §8 — "WebMock fixture responses for success, malformed-JSON, and timeout cases".
# Everything that would otherwise reach api.anthropic.com goes through here.
module AnthropicTestHelper
  MESSAGES_URL = "https://api.anthropic.com/v1/messages"

  # Credentials are not readable in CI without RAILS_MASTER_KEY, and a test that
  # depends on a real key is a test that fails on somebody else's machine. Every
  # stubbed call runs against this instead.
  TEST_API_KEY = "sk-ant-test-key-not-real"

  def anthropic_fixture(name)
    file_fixture("anthropic/#{name}.json").read
  end

  # The parsed reply text a fixture carries, for tests that want to drive the parser
  # directly without going through the client.
  def anthropic_fixture_text(name)
    JSON.parse(anthropic_fixture(name))
      .fetch("content")
      .select { |block| block["type"] == "text" }
      .map { |block| block["text"] }
      .join
  end

  # The client streams (RecipeSearch::Client#create explains why), so a stub has to
  # answer in SSE rather than with a JSON body. Fixtures stay plain JSON `Message`
  # documents — reviewable, and the same shape the capture task writes — and this
  # renders one into the event sequence the SDK's accumulator expects to rebuild it
  # from. `client_test.rb` asserts the round trip is lossless.
  def anthropic_sse(message)
    message = JSON.parse(message) if message.is_a?(String)
    events = []

    # message_start carries the envelope with an empty content array; the blocks
    # arrive as their own events.
    events << [ "message_start", { type: "message_start",
                                   message: message.merge("content" => [], "stop_reason" => nil) } ]

    message["content"].each_with_index do |block, index|
      if block["type"] == "text"
        # Text streams as deltas, which is also what makes `stream.text` work.
        events << [ "content_block_start", { type: "content_block_start", index: index,
                                             content_block: block.merge("text" => "") } ]
        events << [ "content_block_delta", { type: "content_block_delta", index: index,
                                             delta: { type: "text_delta", text: block["text"] } } ]
      else
        # Server-tool blocks are handed over whole. The real API dribbles tool input in
        # as `input_json_delta`; the accumulator keeps whatever `content_block_start`
        # gave it, and reconstructing partial-JSON chunking would test the SDK rather
        # than our code.
        events << [ "content_block_start", { type: "content_block_start", index: index, content_block: block } ]
      end

      events << [ "content_block_stop", { type: "content_block_stop", index: index } ]
    end

    events << [ "message_delta", { type: "message_delta",
                                   delta: { stop_reason: message["stop_reason"], stop_sequence: nil },
                                   usage: message["usage"] } ]
    events << [ "message_stop", { type: "message_stop" } ]

    events.map { |name, payload| "event: #{name}\ndata: #{payload.to_json}\n\n" }.join
  end

  def stub_anthropic(name = nil, body: nil, status: 200)
    stub_request(:post, MESSAGES_URL)
      .to_return(status: status, body: anthropic_sse(body || anthropic_fixture(name)),
                 headers: { "content-type" => "text/event-stream" })
  end

  # Consecutive responses for one stub — the corrective retry (§5) and the
  # `pause_turn` continuation both need the second call to answer differently.
  def stub_anthropic_sequence(*names)
    stub_request(:post, MESSAGES_URL).to_return(
      *names.map { |name|
        { status: 200, body: anthropic_sse(anthropic_fixture(name)),
          headers: { "content-type" => "text/event-stream" } }
      }
    )
  end

  def stub_anthropic_timeout
    stub_request(:post, MESSAGES_URL).to_timeout
  end

  def stub_anthropic_error(status, type: "api_error", message: "Internal server error")
    stub_request(:post, MESSAGES_URL).to_return(
      status: status,
      body: { type: "error", error: { type: type, message: message } }.to_json,
      headers: { "content-type" => "application/json" }
    )
  end

  # A client wired to the fake key, so no test depends on credentials being present.
  # Not named `test_…` — Minitest collects any method with that prefix as a test case.
  def stubbed_search_client(**options)
    RecipeSearch::Client.new(client: Anthropic::Client.new(api_key: TEST_API_KEY, max_retries: 0, **options))
  end

  # Runs the block with the credentials lookup returning nil, for the "not configured
  # yet" paths.
  #
  # Hand-rolled rather than `stub`: Minitest 6 dropped `minitest/mock`, so `Object#stub`
  # no longer exists, and CLAUDE.md's no-new-gems rule does not need bending for six
  # lines. The earlier attempt at `Rails.application.credentials.stub(:dig, nil)` was
  # worse than unavailable — `EncryptedConfiguration#method_missing` answered it with
  # `config[:stub]`, so the block never ran and the test passed having done nothing.
  # Swapping a real singleton method cannot fail that way.
  def without_anthropic_credentials(&block)
    with_credentials_api_key(nil, &block)
  end

  # The mirror, for tests that drive SuggestRecipesJob rather than a client they
  # constructed themselves. The job builds its own `RecipeSearch::Client`, so the only
  # seam is this one, and without it such a test quietly depends on whoever runs it
  # holding `config/master.key` — true on this machine, false in CI, where
  # RAILS_MASTER_KEY is not set and credentials decrypt to nothing. The request is
  # stubbed either way; this only stops the call being refused before WebMock sees it.
  def with_anthropic_credentials(&block)
    with_credentials_api_key(TEST_API_KEY, &block)
  end

  def with_credentials_api_key(value)
    singleton = RecipeSearch::Client.singleton_class
    singleton.alias_method(:__credentials_api_key, :credentials_api_key)
    RecipeSearch::Client.define_singleton_method(:credentials_api_key) { value }

    yield
  ensure
    singleton.alias_method(:credentials_api_key, :__credentials_api_key)
    singleton.remove_method(:__credentials_api_key)
  end

  # The request bodies WebMock saw, parsed. Assertions about the prompt and the tool
  # definition read better against this than against a raw string.
  def anthropic_requests
    requests = []
    WebMock::RequestRegistry.instance.requested_signatures.each { |signature, count| count.times { requests << signature } }
    requests.map { |signature| JSON.parse(signature.body) }
  end
end

ActiveSupport.on_load(:active_support_test_case) do
  include AnthropicTestHelper
end
