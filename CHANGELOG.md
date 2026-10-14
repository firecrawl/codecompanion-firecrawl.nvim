# Changelog

## 0.1.0

- `web_search` adapter backed by Firecrawl `/v2/search`.
- `fetch_webpage` and `/fetch` backed by Firecrawl `/v2/scrape`, returning Markdown.
- Clear errors for a missing key, 401, 402, 429, timeouts and network failures.
