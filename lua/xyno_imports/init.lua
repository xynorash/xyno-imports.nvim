-- xyno-imports.nvim: imports without the menu for Rust. setup() checks the
-- dependency, applies the options and starts the engine (xyno_imports.engine).
local M = {}

M.version = "0.2.0" -- the plugin release (CI of the dependents pins this tag)

M.defaults = {
  commands = true, -- :ImportName :ImportForget :ImportOrganize
  keymaps = false, -- false | true | { import = lhs|false, organize = lhs|false } (buffer-local in Rust files)
  mode = "ask", -- "ask" | "single" | "off": what happens to an unresolved name (vim.g.xyno_auto_import overrides)
  config = {}, -- overrides of the engine's tuning values: debounce, max_names, retries, retry_ms, organize_rounds, max_lines, source_wait_ms (positive numbers)
  weights = {}, -- overrides of the ranking weights, see require("xyno_imports.engine").default_weights (finite numbers; near in [0,1])
}

--- Default keys of `keymaps = true`.
M.default_keymaps = { import = "<leader>rI", organize = "<leader>rO" }

--- The xyno-rust.nvim API this plugin was written against (see xyno_rust.compatible).
M.requires_rust_api = "1.1"

--- Fails with one clear line when xyno-rust.nvim is too old or too new for this plugin.
local function rust_api_ok(name)
  local ok, rust = pcall(require, "xyno_rust")
  if not ok or type(rust.compatible) ~= "function" then
    vim.notify(name .. ": the installed xyno-rust.nvim is too old to say which API it has (needs API " .. M.requires_rust_api .. "): update xyno-rust.nvim", vim.log.levels.ERROR)
    return false
  end
  local good, why = rust.compatible(M.requires_rust_api)
  if not good then
    vim.notify(name .. ": " .. why, vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Configure and start the plugin. Safe to call again (autocmd groups are cleared and redefined).
---@param opts? { commands?: boolean, keymaps?: boolean|table<string, string|false>, mode?: "ask"|"single"|"off", config?: table, weights?: table<string, number> }
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
  if not rust_api_ok("xyno-imports") then
    return
  end
  local engine = require("xyno_imports.engine")
  local problems = {}
  if type(opts.config) ~= "table" then
    problems[#problems + 1] = "config must be a table"
  else
    for k, v in pairs(opts.config) do
      if engine.config[k] == nil then
        problems[#problems + 1] = ("unknown config key `%s`"):format(tostring(k))
      elseif type(v) ~= "number" or v ~= v or v <= 0 or v == math.huge then
        problems[#problems + 1] = ("config `%s` must be a positive number, got %s"):format(k, vim.inspect(v))
      else
        engine.config[k] = v
      end
    end
  end
  local ok, werrs = engine.set_weights(opts.weights)
  if not ok then
    vim.list_extend(problems, werrs) -- the weights stay at their defaults
  end
  if #problems > 0 then
    vim.notify("xyno-imports: invalid options ignored:\n  " .. table.concat(problems, "\n  "), vim.log.levels.WARN)
  end
  engine.setup({ commands = opts.commands, keymaps = opts.keymaps, mode = opts.mode })
end

return M
