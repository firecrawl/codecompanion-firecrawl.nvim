# codecompanion-firecrawl.nvim

A [Firecrawl](https://firecrawl.dev) adapter for [CodeCompanion.nvim](https://github.com/olimorris/codecompanion.nvim).
One `FIRECRAWL_API_KEY` powers CodeCompanion's built-in tools:

- `@{web_search}` searches the web through Firecrawl's `/v2/search`.
- `@{fetch_webpage}` and the `/fetch` slash command read any page as clean Markdown through `/v2/scrape`.

## Requirements

- Neovim 0.11+
- CodeCompanion.nvim (current `main`)
- A Firecrawl API key from [firecrawl.dev/app/api-keys](https://firecrawl.dev/app/api-keys)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    { "firecrawl/codecompanion-firecrawl.nvim", version = "*" },
  },
  opts = {
    adapters = {
      http = {
        firecrawl = function()
          return require("codecompanion-firecrawl").adapter
        end,
        opts = {
          hidden = { firecrawl = true }, -- keep it out of the chat adapter picker
        },
      },
    },
    interactions = {
      chat = {
        tools = {
          web_search = { opts = { adapter = "firecrawl" } },
          fetch_webpage = { opts = { adapter = "firecrawl" } },
        },
        slash_commands = {
          fetch = { opts = { adapter = "firecrawl" } },
        },
      },
    },
  },
}
```

Then export your key before starting Neovim:

```sh
export FIRECRAWL_API_KEY=fc-...
```

Any of CodeCompanion's key sources work, for example `env = { api_key = "cmd:op read op://vault/firecrawl/key" }`.

## Usage

```
Use @{web_search} to find the latest Neovim release and summarise what changed
Use @{fetch_webpage} to read https://neovim.io/doc/user/lsp.html and explain how to disable semantic tokens
```

## Options

`web_search` reads these from `interactions.chat.tools.web_search.opts.opts`:

| Option | Default | Firecrawl field |
| --- | --- | --- |
| `max_results` | `5` | `limit` |
| `time_range` | none | `tbs`: `day`, `week`, `month`, `year`, or a raw value such as `qdr:h` |
| `topic` | `general` | `news` searches news sources |
| `location` | none | `location`, e.g. `"Germany"` |
| `scrape_results` | `false` | Returns each result's full Markdown instead of a snippet. Uses more credits. |

The adapter itself takes:

```lua
firecrawl = function()
  return require("codecompanion.adapters").extend(require("codecompanion-firecrawl").adapter, {
    opts = {
      timeout = 60, -- seconds per request
      base_url = "http://localhost:3002", -- self-hosted Firecrawl; FIRECRAWL_API_URL also works
    },
  })
end,
```

## Errors

Failures come back to the chat as tool errors, with the reason shown as a notification:

| Situation | Message |
| --- | --- |
| Key not set | `FIRECRAWL_API_KEY is not set` (no request is sent) |
| 401 | Firecrawl rejected the API key |
| 402 | Account is out of credits |
| 429 | Rate limit reached |
| Timeout | Request timed out after the configured `timeout` |
| Network | Could not reach Firecrawl at the configured URL |

## Development

```sh
make test        # unit and integration tests (plenary)
make e2e         # both tools in a real chat buffer; needs FIRECRAWL_API_KEY
make e2e-errors  # error paths against the mock server
```

For offline runs, start `python3 scripts/mock_server.py 3999` and set
`FIRECRAWL_API_KEY=fc-mock-key FIRECRAWL_API_URL=http://127.0.0.1:3999`.

## License

MIT
