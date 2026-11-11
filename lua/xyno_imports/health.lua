-- :checkhealth xyno_imports
local M = {}

function M.check()
  local h = vim.health
  h.start("xyno-imports")
  if vim.fn.has("nvim-0.12") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim 0.12 or newer is required")
  end
  for _, mod in ipairs({ "xyno_rust.crate_meta", "xyno_rust.code_actions", "xyno_rust.fsutil" }) do
    if pcall(require, mod) then
      h.ok(mod .. " (xyno-rust.nvim)")
    else
      h.error(mod .. " not found", { "install xynorash/xyno-rust.nvim" })
    end
  end
  local ok, E = pcall(require, "xyno_imports.engine")
  if not ok then
    return h.error("engine does not load: " .. tostring(E))
  end
  h.info(("mode: %s (vim.g.xyno_auto_import overrides)"):format(E.mode()))
  local ok_ts = pcall(vim.treesitter.language.add, "rust")
  if ok_ts then
    h.ok("tree-sitter parser for rust (syntax scan of unresolved names)")
  else
    h.warn("no tree-sitter parser for rust: names are not found by syntax, only by diagnostics", { ":TSInstall rust" })
  end
  if vim.fn.executable("cargo") == 1 then
    h.ok("cargo found (dependency order for ranking)")
  else
    h.warn("cargo not found: dependency facts are missing, candidates rank without them")
  end
  local clients = vim.lsp.get_clients({ name = "rust-analyzer" })
  if #clients > 0 then
    h.ok(("rust-analyzer attached (%d client%s)"):format(#clients, #clients == 1 and "" or "s"))
  else
    h.info("rust-analyzer is not attached in this session (open a Rust file)")
  end
  local d, w = E.default_weights, E.weights
  local changed = {}
  for k, v in pairs(w) do
    if d[k] ~= v then
      changed[#changed + 1] = ("%s=%g (default %g)"):format(k, v, d[k])
    end
  end
  table.sort(changed)
  h.info(#changed > 0 and ("custom weights: " .. table.concat(changed, ", ")) or "ranking weights: defaults")
  h.info("action detection: assist id (data.id), then edit shape, then English title; organize and resolve are asynchronous")
  local state = E.state_file or (vim.fn.stdpath("state") .. "/xyno-imports/imports.json")
  h.info("remembered choices: " .. state)
end

return M
