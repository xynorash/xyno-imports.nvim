-- xyno_imports.setup(): options, opt-in keymaps, commands switch, mode option and
-- the one-line message when xyno-rust.nvim is missing.
local H = require("xyno_imports_test.helpers")
local I = require("xyno_imports")
local E = require("xyno_imports.engine")

local saved_mode, saved_debounce = E.default_mode, E.config.debounce

after_each(function()
  E.default_mode = saved_mode
  E.config.debounce = saved_debounce
  vim.g.xyno_auto_import = nil
  pcall(vim.cmd, "silent! %bwipeout!")
  for _, c in ipairs({ "ImportName", "ImportForget", "ImportOrganize" }) do
    pcall(vim.api.nvim_del_user_command, c)
  end
end)

describe("setup", function()
  it("registers the three commands and sets no keymap by default", function()
    I.setup({})
    for _, c in ipairs({ "ImportName", "ImportForget", "ImportOrganize" }) do
      H.eq(2, vim.fn.exists(":" .. c), c)
    end
    H.need_parser("rust")
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "rust"
    H.eq("", vim.fn.maparg("<leader>rI", "n"))
    H.eq("", vim.fn.maparg("<leader>rO", "n"))
  end)

  it("commands = false registers none", function()
    I.setup({ commands = false })
    for _, c in ipairs({ "ImportName", "ImportForget", "ImportOrganize" }) do
      H.eq(0, vim.fn.exists(":" .. c), c)
    end
  end)

  it("keymaps = true maps the default keys, buffer-local in Rust files", function()
    I.setup({ keymaps = true })
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "rust"
    H.eq(1, vim.fn.maparg("<leader>rI", "n", false, true).buffer)
    H.eq(1, vim.fn.maparg("<leader>rO", "n", false, true).buffer)
  end)

  it("a keymaps table maps only what it lists, false skips one", function()
    I.setup({ keymaps = { import = "<leader>ci", organize = false } })
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].filetype = "rust"
    H.eq(1, vim.fn.maparg("<leader>ci", "n", false, true).buffer)
    H.eq("", vim.fn.maparg("<leader>rO", "n"))
    H.eq("", vim.fn.maparg("<leader>rI", "n"))
  end)

  it("mode and config options reach the engine; vim.g.xyno_auto_import wins", function()
    I.setup({ mode = "single", config = { debounce = 55, nonsense = 1 } })
    H.eq("single", E.mode())
    H.eq(55, E.config.debounce)
    H.is_nil(E.config.nonsense)
    vim.g.xyno_auto_import = "off"
    H.eq("off", E.mode())
    vim.g.xyno_auto_import = "bogus"
    H.eq("single", E.mode())
  end)

  it("without xyno-rust.nvim: one notification line, no Lua error, nothing started", function()
    local notes = H.capture_notify()
    local saved = {}
    for _, k in ipairs({ "xyno_rust.crate_meta", "xyno_rust.code_actions", "xyno_rust.fsutil" }) do
      saved[k] = package.loaded[k]
      package.loaded[k] = nil
    end
    local rtp, loaders = vim.o.runtimepath, package.loaders
    package.loaders = { function() return nil end }
    vim.o.runtimepath = ""
    local ok, err = pcall(I.setup, {})
    vim.o.runtimepath = rtp
    package.loaders = loaders
    for k, v in pairs(saved) do
      package.loaded[k] = v
    end
    H.ok(ok, tostring(err))
    notes.restore()
    H.eq(1, #notes.list)
    H.match(notes.list[1].msg, "xyno-rust.nvim", true)
    H.not_ok(notes.list[1].msg:find("\n"))
    H.eq(vim.log.levels.ERROR, notes.list[1].level)
    H.eq(0, vim.fn.exists(":ImportName"))
  end)
end)
