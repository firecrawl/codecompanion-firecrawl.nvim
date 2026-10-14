-- Runs the error paths through CodeCompanion's real tools and curl against scripts/mock_server.py.
-- Usage: FIRECRAWL_API_URL=http://127.0.0.1:3999 nvim --headless --noplugin -u tests/minimal_init.lua -l scripts/e2e_errors.lua

local mock_url = assert(os.getenv("FIRECRAWL_API_URL"), "FIRECRAWL_API_URL must point at the mock server")

require("codecompanion").setup({
  adapters = {
    http = {
      firecrawl = function()
        return require("codecompanion.adapters").extend(require("codecompanion-firecrawl").adapter, {
          opts = { timeout = 2 },
        })
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

local function run(name, args)
  local tool = require("codecompanion.interactions.chat.tools.builtin." .. name)
  local outputs = {}
  tool.cmds[1]({ tool = { opts = { adapter = "firecrawl" } } }, args, {
    output_cb = function(msg)
      table.insert(outputs, msg)
    end,
  })
  vim.wait(15000, function()
    return #outputs > 0
  end, 100)
  vim.wait(300)
  return outputs
end

local cases = {
  {
    "missing key",
    "web_search",
    { query = "neovim", domains = {} },
    "FIRECRAWL_API_KEY is not set",
    { FIRECRAWL_API_KEY = "" },
  },
  {
    "invalid key (401)",
    "fetch_webpage",
    { url = "https://example.com" },
    "(401)",
    { FIRECRAWL_API_KEY = "fc-wrong" },
  },
  { "out of credits (402)", "web_search", { query = "trigger-402", domains = {} }, "(402)" },
  { "out of credits (402)", "fetch_webpage", { url = "https://example.com/trigger-402" }, "(402)" },
  { "rate limited (429)", "fetch_webpage", { url = "https://example.com/trigger-429" }, "(429)" },
  { "timeout", "web_search", { query = "trigger-timeout", domains = {} }, "timed out after 2s" },
  { "timeout", "fetch_webpage", { url = "https://example.com/trigger-timeout" }, "timed out after 2s" },
  {
    "unreachable",
    "fetch_webpage",
    { url = "https://example.com" },
    "Could not reach Firecrawl",
    { FIRECRAWL_API_URL = "http://127.0.0.1:9" },
  },
}

local failed = false
for _, case in ipairs(cases) do
  local label, name, args, expect, env = unpack(case)
  vim.env.FIRECRAWL_API_KEY = "fc-mock-key"
  vim.env.FIRECRAWL_API_URL = mock_url
  for k, v in pairs(env or {}) do
    vim.env[k] = v
  end

  local captured = {}
  local log = require("codecompanion.utils.log")
  local original = log.error
  log.error = function(self, msg, ...)
    table.insert(captured, string.format(msg, ...))
    return original(self, msg, ...)
  end
  local started = vim.uv.hrtime()
  local outputs = run(name, args)
  log.error = original

  local text = table.concat(
    vim.tbl_map(function(o)
      return tostring(o.data)
    end, outputs),
    "\n"
  ) .. "\n" .. table.concat(captured, "\n")
  local ok = #outputs == 1 and outputs[1].status == "error" and text:find(expect, 1, true) ~= nil
  failed = failed or not ok
  print(
    string.format(
      "%s %-22s %-14s %4dms  %s",
      ok and "PASS" or "FAIL",
      label,
      name,
      (vim.uv.hrtime() - started) / 1e6,
      (#outputs == 1 and outputs[1].data or ("outputs=" .. #outputs)):gsub("\n", " ")
    )
  )
end

os.exit(failed and 1 or 0)
