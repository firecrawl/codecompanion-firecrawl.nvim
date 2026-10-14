local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local deps = os.getenv("DEPS_DIR") or (root .. "/.deps")

vim.opt.rtp:prepend(root)
vim.opt.rtp:append(deps .. "/plenary.nvim")
vim.opt.rtp:append(deps .. "/codecompanion.nvim")
vim.cmd("runtime plugin/plenary.vim")
