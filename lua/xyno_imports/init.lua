-- xyno-imports.nvim: imports without the menu for Rust. setup() checks the
-- dependency, applies the options and starts the engine (xyno_imports.engine).
local M = {}

M.defaults = {
  commands = true, -- :ImportName :ImportForget :ImportOrganize
  keymaps = false, -- false | true | { import = lhs|false, organize = lhs|false } (buffer-local in Rust files)
  mode = "ask", -- "ask" | "single" | "off": what happens to an unresolved name (vim.g.xyno_auto_import overrides)
  config = {}, -- overrides of the engine's tuning values: debounce, max_names, retries, retry_ms, organize_rounds, max_lines, source_wait_ms
}

--- Default keys of `keymaps = true`.
M.default_keymaps = { import = "<leader>rI", organize = "<leader>rO" }

--- Configure and start the plugin. Safe to call again (autocmd groups are cleared and redefined).
---@param opts? { commands?: boolean, keymaps?: boolean|table<string, string|false>, mode?: "ask"|"single"|"off", config?: table }
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify("xyno-imports: Neovim 0.12 or newer is required", vim.log.levels.ERROR)
    return
  end
  for _, mod in ipairs({ "xyno_rust.crate_meta", "xyno_rust.code_actions", "xyno_rust.fsutil" }) do
    if not pcall(require, mod) then
      vim.notify("xyno-imports: needs xyno-rust.nvim (xynorash/xyno-rust.nvim), which is not installed", vim.log.levels.ERROR)
      return
    end
  end
  local engine = require("xyno_imports.engine")
  for k, v in pairs(opts.config) do
    if engine.config[k] ~= nil then
      engine.config[k] = v
    end
  end
  engine.setup({ commands = opts.commands, keymaps = opts.keymaps, mode = opts.mode })
end

return M
