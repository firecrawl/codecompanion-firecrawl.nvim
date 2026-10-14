-- Runs web_search and fetch_webpage through a real CodeCompanion chat buffer.
-- Live: export FIRECRAWL_API_KEY. Offline: also set FIRECRAWL_API_URL to scripts/mock_server.py.
-- Optional: E2E_QUERY, E2E_URL, E2E_TRANSCRIPT (path to write the chat buffer to).

local query = os.getenv("E2E_QUERY") or "neovim lua plugin manager"
local url = os.getenv("E2E_URL") or "https://example.com"

require("codecompanion").setup({
  adapters = {
    http = {
      firecrawl = function()
        return require("codecompanion-firecrawl").adapter
      end,
      opts = { hidden = { firecrawl = true } },
    },
  },
  interactions = {
    chat = {
      adapter = "openai",
      tools = {
        web_search = { opts = { adapter = "firecrawl", opts = { max_results = 3 } } },
        fetch_webpage = { opts = { adapter = "firecrawl" } },
      },
    },
  },
})

local chat = require("codecompanion.interactions.chat").new({
  adapter = "openai",
  buffer_context = { bufnr = vim.api.nvim_get_current_buf(), filetype = "lua" },
})
-- Keep the run to the tools: don't send their output on to an LLM.
chat.submit = function() end

local function call(id, name, args)
  return { id = id, type = "function", ["function"] = { name = name, arguments = vim.json.encode(args) } }
end

local function tool_outputs()
  return vim.tbl_filter(function(m)
    return m.role == "tool"
  end, chat.messages)
end

local function run(id, name, args)
  local before = #tool_outputs()
  chat.tools:execute(chat, { call(id, name, args) })
  local ok = vim.wait(90000, function()
    return #tool_outputs() > before
  end, 200)
  if not ok then
    io.stderr:write(string.format("FAIL %s: no tool output within 90s\n", name))
    os.exit(1)
  end
  vim.wait(300)
  return tool_outputs()[#tool_outputs()].content
end

local search = run("call_search", "web_search", { query = query, domains = {} })
local page = run("call_fetch", "fetch_webpage", { url = url })

local lines = vim.api.nvim_buf_get_lines(chat.bufnr, 0, -1, false)
local transcript = table.concat(lines, "\n")
local out = os.getenv("E2E_TRANSCRIPT")
if out then
  vim.fn.writefile(lines, out)
end

print("==== chat buffer ====")
print(transcript)
print("==== web_search tool output (sent to the LLM) ====")
print(search:sub(1, 1500))
print("==== fetch_webpage tool output (sent to the LLM) ====")
print(page:sub(1, 1500))

local failed = false
local function check(cond, msg)
  print((cond and "PASS " or "FAIL ") .. msg)
  failed = failed or not cond
end
check(search:find("<attachment url=", 1, true) ~= nil, "web_search returned results as attachments")
check(page:find('<attachment url="' .. url, 1, true) ~= nil, "fetch_webpage returned the page")
check(not search:find("Error", 1, true) and not page:find("Error", 1, true), "no tool errors")
os.exit(failed and 1 or 0)
