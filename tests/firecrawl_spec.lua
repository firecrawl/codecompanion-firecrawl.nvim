local firecrawl = require("codecompanion-firecrawl")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")

local function fixture(name)
  return table.concat(vim.fn.readfile(root .. "/fixtures/" .. name .. ".json"), "\n")
end

local function response(status, body)
  return { status = status, body = body, headers = {} }
end

local function with_env(vars, fn)
  local saved = {}
  for k, v in pairs(vars) do
    saved[k] = vim.env[k]
    vim.env[k] = v ~= false and v or nil
  end
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    vim.env[k] = v
  end
  if not ok then
    error(err, 0)
  end
end

describe("search request", function()
  it("sends the query, a default limit and the origin", function()
    local body = firecrawl.search_body({}, { query = "neovim", domains = {} })
    assert.are.same({ query = "neovim", limit = 5, origin = "codecompanion" }, body)
  end)

  it("maps tool options and domains to Firecrawl fields", function()
    local body = firecrawl.search_body(
      { max_results = 3, time_range = "week", topic = "news", location = "Germany", scrape_results = true },
      { query = "neovim", domains = { "neovim.io" } }
    )
    assert.are.equal(3, body.limit)
    assert.are.same({ "neovim.io" }, body.includeDomains)
    assert.are.equal("qdr:w", body.tbs)
    assert.are.same({ "news" }, body.sources)
    assert.are.equal("Germany", body.location)
    assert.are.same({ formats = { "markdown" }, onlyMainContent = true }, body.scrapeOptions)
  end)

  it("ignores domains the LLM sends as an empty string", function()
    local body = firecrawl.search_body({}, { query = "neovim", domains = "" })
    assert.is_nil(body.includeDomains)
  end)

  it("passes a raw tbs value through", function()
    assert.are.equal("qdr:h", firecrawl.search_body({ time_range = "qdr:h" }, { query = "q" }).tbs)
  end)
end)

describe("search response", function()
  it("maps web results to title, url and content", function()
    local out = firecrawl.search_result(response(200, fixture("search")))
    assert.are.equal("success", out.status)
    assert.are.same({
      { title = "Home - Neovim", url = "https://neovim.io/", content = "Hyperextensible Vim-based text editor" },
      {
        title = "neovim/neovim",
        url = "https://github.com/neovim/neovim",
        content = "Vim-fork focused on extensibility and usability",
      },
    }, out.content)
  end)

  it("maps a recorded live response", function()
    local out = firecrawl.search_result(response(200, fixture("search_live")))
    assert.are.equal("success", out.status)
    assert.are.equal("https://github.com/olimorris/codecompanion.nvim", out.content[1].url)
    assert.truthy(#out.content[1].content > 0)
  end)

  it("prefers scraped markdown and includes news results", function()
    local out = firecrawl.search_result(response(200, fixture("search_scraped")))
    assert.are.equal("# Neovim\n\nhyperextensible Vim-based text editor", out.content[1].content)
    assert.are.equal("Release notes", out.content[2].content)
  end)

  it("reports an empty result set", function()
    assert.are.same(
      { status = "error", content = "No results found" },
      firecrawl.search_result(response(200, fixture("search_empty")))
    )
  end)
end)

describe("scrape", function()
  it("builds a markdown scrape request", function()
    assert.are.same(
      { url = "https://example.com", formats = { "markdown" }, onlyMainContent = true, origin = "codecompanion" },
      firecrawl.scrape_body("https://example.com")
    )
  end)

  it("returns the page markdown", function()
    local out = firecrawl.scrape_result(response(200, fixture("scrape")))
    assert.are.equal("success", out.status)
    assert.truthy(out.content:find("# Example Domain", 1, true))
  end)

  it("reports the page status when there is no content", function()
    local out = firecrawl.scrape_result(response(200, fixture("scrape_404")))
    assert.are.equal("error", out.status)
    assert.truthy(out.content:find("HTTP 404", 1, true))
  end)
end)

describe("errors", function()
  local cases = {
    { 401, '{"success":false,"error":"Unauthorized: Invalid token"}', "rejected the API key (401)" },
    { 402, '{"success":false,"error":"Insufficient credits"}', "out of credits (402)" },
    { 429, '{"success":false,"error":"Rate limit exceeded"}', "rate limit reached (429)" },
    { 408, '{"success":false,"error":"Request timed out"}', "timed out fetching the page (408)" },
    { 500, '{"success":false,"error":"Internal error"}', "returned HTTP 500" },
  }

  for _, case in ipairs(cases) do
    it("maps HTTP " .. case[1] .. " for both tools", function()
      for _, map in ipairs({ firecrawl.search_result, firecrawl.scrape_result }) do
        local out = map(response(case[1], case[2]))
        assert.are.equal("error", out.status)
        assert.truthy(out.content:find(case[3], 1, true), out.content)
        local detail = vim.json.decode(case[2]).error
        assert.truthy(out.content:find(detail, 1, true), out.content)
      end
    end)
  end

  it("handles a non-JSON error body", function()
    local out = firecrawl.scrape_result(response(502, "<html>Bad Gateway</html>"))
    assert.are.same({ status = "error", content = "Firecrawl returned HTTP 502." }, out)
  end)

  it("handles a non-JSON success body", function()
    local out = firecrawl.search_result(response(200, "not json"))
    assert.are.same({ status = "error", content = "Could not parse the Firecrawl response as JSON." }, out)
  end)

  it("handles success=false on a 200", function()
    local out = firecrawl.search_result(response(200, '{"success":false,"error":"Bad query"}'))
    assert.are.same({ status = "error", content = "Firecrawl error: Bad query" }, out)
  end)

  it("detects a missing key only for plain environment variables", function()
    with_env({ FIRECRAWL_API_KEY = false }, function()
      assert.truthy(
        firecrawl.missing_key({ env = { api_key = "FIRECRAWL_API_KEY" } }):find("FIRECRAWL_API_KEY is not set", 1, true)
      )
      assert.is_nil(firecrawl.missing_key({ env = { api_key = "cmd:op read op://x" } }))
      assert.is_nil(firecrawl.missing_key({
        env = {
          api_key = function()
            return "k"
          end,
        },
      }))
    end)
    with_env({ FIRECRAWL_API_KEY = "fc-test" }, function()
      assert.is_nil(firecrawl.missing_key({ env = { api_key = "FIRECRAWL_API_KEY" } }))
    end)
  end)
end)

describe("base url", function()
  it("defaults to the hosted API", function()
    with_env({ FIRECRAWL_API_URL = false }, function()
      assert.are.equal("https://api.firecrawl.dev", firecrawl.base_url({ opts = {} }))
    end)
  end)

  it("honours FIRECRAWL_API_URL and the base_url option", function()
    with_env({ FIRECRAWL_API_URL = "http://localhost:3002/" }, function()
      assert.are.equal("http://localhost:3002", firecrawl.base_url({ opts = {} }))
      assert.are.equal("https://fc.example", firecrawl.base_url({ opts = { base_url = "https://fc.example" } }))
    end)
  end)
end)

describe("inside CodeCompanion", function()
  local http = require("codecompanion.http")
  local config = require("codecompanion.config")
  local original_post = http.static.methods.post.default
  local calls

  local function read_headers(raw)
    for i, arg in ipairs(raw) do
      if arg == "--header" and raw[i + 1]:sub(1, 1) == "@" then
        return table.concat(vim.fn.readfile(raw[i + 1]:sub(2)), "\n")
      end
    end
  end

  ---Stub curl with a sequence of outcomes: a response table, or { error = curl_error }.
  local function stub_curl(outcomes)
    calls = {}
    http.static.methods.post.default = function(opts)
      local outcome = table.remove(outcomes, 1)
      table.insert(calls, {
        url = opts.url,
        body = vim.json.decode(table.concat(vim.fn.readfile(opts.body), "\n")),
        headers = read_headers(opts.raw),
        raw = opts.raw,
      })
      if outcome.error then
        opts.on_error(outcome.error)
      else
        opts.callback(outcome)
      end
      return { args = {}, shutdown = function() end }
    end
  end

  local function run_tool(name, args, tool_opts)
    local tool = dofile(
      vim.api.nvim_get_runtime_file("lua/codecompanion/interactions/chat/tools/builtin/" .. name .. ".lua", false)[1]
    )
    local result, count = nil, 0
    local self = { tool = { opts = vim.tbl_extend("force", { adapter = "firecrawl" }, tool_opts or {}) } }
    tool.cmds[1](self, args, {
      output_cb = function(msg)
        count = count + 1
        result = result or msg
      end,
    })
    vim.wait(1000, function()
      return result ~= nil
    end)
    vim.wait(100)
    assert.are.equal(1, count, "output_cb must be called exactly once")
    return result
  end

  before_each(function()
    config.setup({
      adapters = {
        http = {
          firecrawl = function()
            return require("codecompanion-firecrawl").adapter
          end,
        },
      },
      interactions = {
        chat = {
          tools = {
            web_search = { opts = { adapter = "firecrawl" } },
            fetch_webpage = { opts = { adapter = "firecrawl" } },
          },
        },
      },
    })
    vim.env.FIRECRAWL_API_KEY = "fc-test-key"
    vim.env.FIRECRAWL_API_URL = nil
  end)

  after_each(function()
    http.static.methods.post.default = original_post
  end)

  it("runs web_search against /v2/search with the key and timeout", function()
    stub_curl({ response(200, fixture("search")) })
    local out = run_tool("web_search", { query = "neovim", domains = {} }, { opts = { max_results = 2 } })
    assert.are.equal("success", out.status)
    assert.are.equal("Home - Neovim", out.data[1].title)
    assert.are.equal("https://api.firecrawl.dev/v2/search", calls[1].url)
    assert.are.same({ query = "neovim", limit = 2, origin = "codecompanion" }, calls[1].body)
    assert.truthy(calls[1].headers:find("Authorization: Bearer fc-test-key", 1, true))
    assert.truthy(table.concat(calls[1].raw, " "):find("--max-time 60", 1, true))
  end)

  it("runs fetch_webpage against /v2/scrape", function()
    stub_curl({ response(200, fixture("scrape")) })
    local out = run_tool("fetch_webpage", { url = "https://example.com" })
    assert.are.equal("success", out.status)
    assert.truthy(out.data:find("# Example Domain", 1, true))
    assert.are.equal("https://api.firecrawl.dev/v2/scrape", calls[1].url)
    assert.are.equal("https://example.com", calls[1].body.url)
  end)

  it("reports a 402 once, even though the client signals the error twice", function()
    stub_curl({ response(402, '{"success":false,"error":"Insufficient credits"}') })
    local out = run_tool("fetch_webpage", { url = "https://example.com" })
    assert.are.equal("error", out.status)
    assert.truthy(out.data:find("out of credits (402)", 1, true))
  end)

  it("reports a 401 and 429 from web_search", function()
    stub_curl({ response(401, '{"success":false,"error":"Unauthorized"}') })
    assert.truthy(run_tool("web_search", { query = "q", domains = {} }).data:find("(401)", 1, true))
    stub_curl({ response(429, '{"success":false,"error":"Rate limit exceeded"}') })
    assert.truthy(run_tool("web_search", { query = "q", domains = {} }).data:find("(429)", 1, true))
  end)

  it("turns a curl timeout into an error for web_search instead of hanging", function()
    stub_curl({ { error = { message = "curl error exit_code=28", stderr = "", exit = 28 } } })
    local out = run_tool("web_search", { query = "q", domains = {} })
    assert.are.equal("error", out.status)
    assert.truthy(out.data:find("timed out after 60s", 1, true))
  end)

  it("reports an unreachable server for fetch_webpage", function()
    vim.env.FIRECRAWL_API_URL = "http://127.0.0.1:9"
    stub_curl({ { error = { message = "curl error exit_code=7", stderr = "", exit = 7 } } })
    local out = run_tool("fetch_webpage", { url = "https://example.com" })
    assert.are.equal("error", out.status)
    assert.truthy(out.data:find("Could not reach Firecrawl at http://127.0.0.1:9", 1, true))
  end)

  it("fails fast without a request when the key is missing", function()
    vim.env.FIRECRAWL_API_KEY = nil
    stub_curl({})
    local out = run_tool("web_search", { query = "q", domains = {} })
    assert.are.equal("error", out.status)
    assert.truthy(out.data:find("FIRECRAWL_API_KEY is not set", 1, true))
    assert.are.equal(0, #calls)
  end)

  it("serves the /fetch slash command", function()
    local adapter = require("codecompanion.adapters").resolve("firecrawl")
    adapter.methods.slash_commands.fetch.setup(adapter, { url = "https://example.com" })
    assert.are.equal("https://api.firecrawl.dev/v2/scrape", adapter.url)
    local out = adapter.methods.slash_commands.fetch.callback(adapter, response(200, fixture("scrape")))
    assert.are.equal("success", out.status)
  end)
end)
