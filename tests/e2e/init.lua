-- Minimal init for the end-to-end smoke test: lazy.nvim loads this checkout and its
-- dependency xyno-rust.nvim through `dir =` and calls setup().
-- XYNO_LAZY is the path of a lazy.nvim clone, XYNO_RUST_DIR the one of xyno-rust.nvim
-- (default: a sibling checkout).
-- Run:  XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
local rust = vim.env.XYNO_RUST_DIR
if not rust or rust == "" then
  rust = vim.fs.dirname(repo) .. "/xyno-rust.nvim"
end
vim.o.swapfile = false
vim.opt.rtp:prepend(assert(vim.env.XYNO_LAZY, "XYNO_LAZY not set"))
if vim.env.XYNO_TEST_RTP and vim.env.XYNO_TEST_RTP ~= "" then
  vim.opt.rtp:append(vim.env.XYNO_TEST_RTP) -- e.g. a directory holding parser/rust.so
end
require("lazy").setup({
  {
    dir = repo,
    name = "xyno-imports.nvim",
    lazy = false,
    main = "xyno_imports",
    opts = {},
    dependencies = { { dir = rust, name = "xyno-rust.nvim" } },
  },
}, {
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  performance = { reset_packpath = false, rtp = { reset = false } },
})
