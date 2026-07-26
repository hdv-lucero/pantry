# §5 Option B — "use the Anthropic web search tool in the API call. The model
# searches the live web during the call and returns real recipe pages it actually
# visited." This class owns exactly that call: request shape, the server-tool
# continuation handshake, and turning transport failures into one error type. It
# knows nothing about pantries, and it does not parse — `Parser` does that.
class RecipeSearch::Client
  # §2 — "Model: a fast/cheap tier model is fine for this task." Sonnet is the cheap
  # tier that can still run the web search tool version below; Haiku 4.5 only supports
  # the older basic `web_search_20250305`, without the dynamic filtering that keeps
  # search results from flooding the context (and the bill).
  MODEL = :"claude-sonnet-5"

  # `web_search_20260209` filters results before they reach the context window. It does
  # that by running code server-side, so a real response comes back carrying
  # `code_execution_tool_result` blocks we never asked for — 14 of them in the measured
  # call. They are the tool's own machinery, not a second tool leaking in, and the one
  # thing not to do about them is declare `code_execution` in `tools` as well: a second
  # execution environment confuses the model.
  #
  # The SDK also ships a newer `web_search_20260318`, which adds a `response_inclusion`
  # knob that looks well suited to §5's content boundaries — worth revisiting once its
  # model support is documented.
  WEB_SEARCH_TOOL_TYPE = "web_search_20260209"

  # §5 cost control. These are measured, not guessed: one real call against the seeded
  # 23-item pantry took **258s** and billed **219k input / 7.1k output tokens over 8
  # searches**. Two of the original guesses were wrong in ways that only a live call
  # showed, so the numbers behind each are recorded here.
  #
  # The input-token figure is the surprising one and it is where the money goes — the
  # server-side search loop accumulates every result it reads. `max_uses` is therefore
  # the strongest cost lever in this file, well ahead of `max_tokens`.
  # Observed 7,135 output tokens with thinking on. The original 8,192 was close enough
  # to truncate the JSON and waste the whole call on a corrective retry.
  MAX_TOKENS = 12_000

  # The model spent all 8 searches it was first given. §5 wants 3–5 recipes, and 5
  # searches found 3 good ones.
  MAX_SEARCHES = 5

  # First dial to turn if searches come back thin.
  EFFORT = :medium

  # Generous because it is a safety net, not a schedule. The request streams (see
  # `create`), so this bounds a genuinely stuck connection rather than a slow one —
  # two non-streaming attempts died on this timeout at 120s and again at 300s while
  # the call itself was still healthy.
  REQUEST_TIMEOUT = 900

  # The SDK retries 5xx/429 twice by default, silently turning one timeout into three.
  # That is what burned the first live run: three 120s attempts consumed the job's
  # whole budget before anything useful happened. §5 wants new calls to come from
  # explicit user action, and §4.2 puts a retry button on the failed card — so a
  # failure belongs to the user, not to a hidden loop.
  MAX_RETRIES = 0

  # A `pause_turn` means the server-side search loop hit its own iteration cap and
  # wants to keep going. Resuming is a plain re-request, but it bills again, so it is
  # bounded rather than a `while`.
  MAX_CONTINUATIONS = 2

  Error = Class.new(RecipeSearch::Error)
  MissingCredentials = Class.new(Error)

  # `content` is carried alongside `text` because the corrective retry (§5) replays
  # the model's own turn back to it, and that turn includes the search-result blocks.
  Reply = Data.define(:text, :content, :usage)

  # §5 — "API key via Rails credentials, never env-committed." Resolved through a
  # class method rather than inline so it is one named seam: the rake fixture-capture
  # task reads the same source, and a test can replace it without reaching into
  # `Rails.application.credentials` (whose `method_missing` silently absorbs an
  # attempt to stub it, producing a test that passes without running).
  def self.credentials_api_key
    Rails.application.credentials.dig(:anthropic, :api_key)
  end

  def initialize(client: nil, api_key: nil)
    @client = client
    @api_key = api_key
  end

  def call(system:, messages:)
    conversation = messages.dup
    continuations = 0

    loop do
      message = create(system:, messages: conversation)

      case message.stop_reason
      when :pause_turn
        raise Error, "The search did not finish after #{MAX_CONTINUATIONS} continuations." if continuations >= MAX_CONTINUATIONS

        # Resuming means handing back the turn verbatim and asking for more; the API
        # picks up where its search loop stopped. No extra user message — a nudge here
        # is read as a new instruction.
        conversation += [ { role: :assistant, content: message.content } ]
        continuations += 1
      when :refusal
        raise Error, "The model declined the request#{refusal_detail(message)}."
      when :max_tokens
        # The reply is truncated, so its JSON is unclosed. Say so plainly rather than
        # letting the parser report a syntax error and the retry burn a second call.
        raise Error, "The reply hit the #{MAX_TOKENS}-token cap before it finished."
      else
        return Reply.new(text: text_from(message), content: message.content, usage: message.usage)
      end
    end
  end

  private
    # Streams, and then waits for the whole message before returning any of it.
    #
    # That looks like the worst of both worlds until you have watched a non-streaming
    # version of this call fail twice. A web-search turn spends minutes server-side
    # doing searches and thinking, sending nothing; a plain POST is one long silence
    # that any HTTP timeout reasonably reads as a hung connection. Streaming keeps
    # events flowing, so the timeout goes back to meaning "the connection died" —
    # which is the only thing a timeout should mean.
    #
    # Nothing consumes the deltas yet. §M4's "staged progress messages" ("searching…
    # found 4 candidates…") is where they earn their keep, and this is the plumbing
    # that makes that a UI change rather than a rewrite.
    def create(system:, messages:)
      stream = client.messages.stream(
        model: MODEL,
        max_tokens: MAX_TOKENS,
        system_: system,
        messages: messages,
        tools: [ { type: WEB_SEARCH_TOOL_TYPE, name: "web_search", max_uses: MAX_SEARCHES } ],
        # Adaptive thinking is left on (the default on this model). §5's note that
        # temperature should be low predates the current API, which rejects
        # `temperature` on this model tier outright — see the recap. Effort is the
        # supported dial, and turning thinking off is the wrong way to save tokens
        # here: it makes the model measurably less willing to reach for a tool, and
        # the tool call is the entire feature.
        output_config: { effort: EFFORT },
        request_options: { timeout: REQUEST_TIMEOUT }
      )

      stream.accumulated_message
    rescue Anthropic::Errors::APIError => e
      # One error type out, so the job's rescue does not have to know the SDK's
      # hierarchy. `APITimeoutError` is a subclass, so §5's "job wrapped in a timeout"
      # is satisfied by the request timeout above without a thread-killing
      # `Timeout.timeout` around live socket IO.
      raise Error, e.message
    end

    # §5's content boundaries mean only the model's own text is ever wanted. The
    # `server_tool_use` and `web_search_tool_result` blocks in the same response carry
    # the raw search results, and dropping them here is what keeps scraped page
    # content from reaching the parser, let alone a card.
    def text_from(message)
      message.content.select { |block| block.type == :text }.map(&:text).join.strip
    end

    def refusal_detail(message)
      category = message.stop_details&.category
      category ? " (#{category})" : ""
    end

    def client
      @client ||= Anthropic::Client.new(api_key: api_key, max_retries: MAX_RETRIES)
    end

    def api_key
      (@api_key || self.class.credentials_api_key).presence ||
        raise(MissingCredentials, "No anthropic.api_key in Rails credentials — see tmp/set_anthropic_key.rb or bin/rails credentials:edit.")
    end
end
