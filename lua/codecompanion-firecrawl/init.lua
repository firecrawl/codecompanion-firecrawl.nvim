local fmt = string.format

local ORIGIN = "codecompanion"
local DEFAULT_BASE_URL = "https://api.firecrawl.dev"
local DEFAULT_TIMEOUT = 60
local CURL_TIMEOUT_EXIT = 28

local M = {}

---@param adapter table
---@return string
function M.base_url(adapter)
  local url = adapter.opts.base_url or os.getenv("FIRECRAWL_API_URL") or DEFAULT_BASE_URL
  return (url:gsub("/+$", ""))
end

---Return an error message when the API key is configured as a plain environment variable that is not set.
---Keys supplied through `cmd:`, `file:` or a function are left for the API to judge.
---@param adapter table
---@return string|nil
function M.missing_key(adapter)
  local var = adapter.env and adapter.env.api_key
  if type(var) ~= "string" or not var:match("^[%a_][%w_]*$") then
    return nil
  end
  local value = os.getenv(var)
  if value and value ~= "" then
    return nil
  end
  return fmt("%s is not set. Get an API key at https://firecrawl.dev/app/api-keys and export it.", var)
end

---Turn a non-success HTTP response into a message the user and the LLM can act on.
---@param status number
---@param body table|nil
---@return string
function M.http_error(status, body)
  local detail = type(body) == "table" and (body.error or body.message) or nil
  local message
  if status == 401 then
    message = "Firecrawl rejected the API key (401). Check FIRECRAWL_API_KEY."
  elseif status == 402 then
    message = "Firecrawl account is out of credits (402). Upgrade or top up at https://firecrawl.dev/pricing."
  elseif status == 429 then
    message = "Firecrawl rate limit reached (429). Wait a moment and try again."
  elseif status == 408 then
    message = "Firecrawl timed out fetching the page (408)."
  else
    message = fmt("Firecrawl returned HTTP %s.", status)
  end
  if detail and detail ~= "" then
    message = message .. " " .. tostring(detail)
  end
  return message
end

---Decode a response, returning the body on success or an error result for the tool.
---@param data table The response from the HTTP client, or a synthetic one from `request`
---@return table|nil body, table|nil err
function M.decode(data)
  if data.firecrawl_error then
    return nil, { status = "error", content = data.firecrawl_error }
  end

  local ok, body = pcall(vim.json.decode, data.body or "", { luanil = { object = true, array = true } })
  if not ok or type(body) ~= "table" then
    body = nil
  end

  if data.status ~= 200 then
    return nil, { status = "error", content = M.http_error(data.status, body) }
  end
  if not body then
    return nil, { status = "error", content = "Could not parse the Firecrawl response as JSON." }
  end
  if body.success == false then
    return nil, { status = "error", content = "Firecrawl error: " .. tostring(body.error or "unknown error") }
  end

  return body, nil
end

local TIME_RANGES = { day = "qdr:d", week = "qdr:w", month = "qdr:m", year = "qdr:y" }

---@param opts table Options from the web_search tool config
---@param data table The arguments from the LLM's tool call
---@return table
function M.search_body(opts, data)
  local body = {
    query = data.query,
    limit = opts.max_results or 5,
    origin = ORIGIN,
  }
  if type(data.domains) == "table" and #data.domains > 0 then
    body.includeDomains = data.domains
  end
  if opts.time_range then
    body.tbs = TIME_RANGES[opts.time_range] or opts.time_range
  end
  if opts.topic == "news" then
    body.sources = { "news" }
  end
  if opts.location then
    body.location = opts.location
  end
  if opts.scrape_results then
    body.scrapeOptions = { formats = { "markdown" }, onlyMainContent = true }
  end
  return body
end

---@param data table The response from the HTTP client
---@return table{status: string, content: table|string}
function M.search_result(data)
  local body, err = M.decode(data)
  if err then
    -- The web_search tool only reports "Error searching for <query>", so surface the reason here.
    require("codecompanion.utils.log"):error("[Firecrawl] %s", err.content)
    return err
  end

  local results = {}
  local groups = type(body.data) == "table" and body.data or {}
  for _, group in ipairs({ groups.web or {}, groups.news or {} }) do
    for _, item in ipairs(group) do
      local content = item.markdown
      if not content or content == "" then
        content = item.description or item.snippet or ""
      end
      table.insert(results, { title = item.title or "", url = item.url or "", content = content })
    end
  end

  if #results == 0 then
    return { status = "error", content = "No results found" }
  end
  return { status = "success", content = results }
end

---@param url string
---@return table
function M.scrape_body(url)
  return { url = url, formats = { "markdown" }, onlyMainContent = true, origin = ORIGIN }
end

---@param data table The response from the HTTP client
---@return table{status: string, content: string}
function M.scrape_result(data)
  local body, err = M.decode(data)
  if err then
    return err
  end

  local page = type(body.data) == "table" and body.data or {}
  local markdown = page.markdown or ""
  if markdown == "" then
    local code = page.metadata and page.metadata.statusCode
    if code and code >= 400 then
      return { status = "error", content = fmt("The page returned HTTP %s and had no readable content.", code) }
    end
    return { status = "error", content = "Firecrawl returned no content for this page." }
  end
  return { status = "success", content = markdown }
end

---Wrap CodeCompanion's HTTP client so every outcome reaches the tool exactly once:
---a missing key fails before any request, and curl failures such as timeouts become a response.
---@param client table CodeCompanion.HTTPClient
---@param payload table
---@param actions table
---@param opts? table
---@return table|nil
function M.request(client, payload, actions, opts)
  local adapter = vim.deepcopy(client.adapter)
  adapter.opts.request = nil

  local delivered = false
  local function deliver(data)
    if delivered then
      return
    end
    delivered = true
    actions.callback(nil, data)
  end

  local missing = M.missing_key(adapter)
  if missing then
    vim.schedule(function()
      deliver({ status = 0, firecrawl_error = missing })
    end)
    return nil
  end

  local timeout = tostring(adapter.opts.timeout or DEFAULT_TIMEOUT)
  adapter.raw = vim.list_extend(adapter.raw or {}, { "--max-time", timeout, "--retry-max-time", timeout })

  local inner = setmetatable({ adapter = adapter }, { __index = client })
  return inner:request(payload, {
    callback = function(err, data)
      if data then
        return deliver(data)
      end
      local message
      if err and err.exit == CURL_TIMEOUT_EXIT then
        message = fmt("Firecrawl request timed out after %ss.", timeout)
      else
        message = fmt("Could not reach Firecrawl at %s. %s", M.base_url(adapter), err and err.message or "")
      end
      deliver({ status = 0, firecrawl_error = message })
    end,
    done = actions.done,
  }, opts)
end

---@param self CodeCompanion.HTTPAdapter
---@param url string
local function setup_scrape(self, url)
  self.url = M.base_url(self) .. "/v2/scrape"
  self.handlers.set_body = function()
    return M.scrape_body(url)
  end
end

---@class CodeCompanion.HTTPAdapter
M.adapter = {
  name = "firecrawl",
  formatted_name = "Firecrawl",
  roles = {
    llm = "assistant",
    user = "user",
  },
  opts = {
    stream = false,
    timeout = DEFAULT_TIMEOUT,
    base_url = nil,
    request = function(...)
      return require("codecompanion-firecrawl").request(...)
    end,
  },
  url = DEFAULT_BASE_URL,
  env = {
    api_key = "FIRECRAWL_API_KEY",
  },
  headers = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer ${api_key}",
  },
  schema = {
    model = {
      default = "firecrawl",
    },
  },
  handlers = {},
  methods = {
    slash_commands = {
      fetch = {
        setup = function(self, data)
          setup_scrape(self, data.url)
        end,
        callback = function(_, data)
          return M.scrape_result(data)
        end,
      },
    },
    tools = {
      web_search = {
        setup = function(self, opts, data)
          self.url = M.base_url(self) .. "/v2/search"
          self.handlers.set_body = function()
            return M.search_body(opts or {}, data)
          end
        end,
        callback = function(_, data)
          return M.search_result(data)
        end,
      },
      fetch_webpage = {
        setup = function(self, data)
          setup_scrape(self, data.url)
        end,
        callback = function(_, data)
          return M.scrape_result(data)
        end,
      },
    },
  },
}

return M
