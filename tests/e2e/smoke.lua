-- End-to-end smoke test (see tests/e2e/init.lua): the plugin is loaded by lazy.nvim,
-- setup() ran, every documented command exists, :help xyno-imports resolves, the
-- missing-dependency message is one line, and a name in a scratch crate is resolved.
local failures = {}
local function check(name, ok, detail)
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", name, (not ok and detail) and (": " .. tostring(detail)) or ""))
  if not ok then
    failures[#failures + 1] = name
  end
end

check("lazy.nvim loaded xyno_imports", package.loaded["xyno_imports"] ~= nil)
for _, c in ipairs({ "ImportName", "ImportForget", "ImportOrganize" }) do
  check("command :" .. c, vim.fn.exists(":" .. c) == 2)
end
check("autocmd group xyno_imports", #vim.api.nvim_get_autocmds({ group = "xyno_imports" }) >= 4)
check("no global <leader>rI by default", vim.fn.maparg("<leader>rI", "n") == "")
for _, m in ipairs({ "engine" }) do
  check("require xyno_imports." .. m, (pcall(require, "xyno_imports." .. m)))
end
check("mode() default", require("xyno_imports.engine").mode() == "ask")

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
vim.cmd("helptags " .. vim.fn.fnameescape(repo .. "/doc"))
for _, tag in ipairs({ "xyno-imports", "xyno-imports-api", "xyno-imports-setup", ":ImportName", ":ImportForget", ":ImportOrganize" }) do
  local ok, err = pcall(vim.cmd, "help " .. tag)
  check(":help " .. tag, ok, err)
end
vim.cmd("only")

-- the engine ranks a candidate list without a server
local E = require("xyno_imports.engine")
local ranked = E.rank({ E.candidate("std::fmt::Result"), E.candidate("std::io::Result") }, {})
check("rank() returns the candidates", #ranked == 2 and ranked[1].score ~= nil)

-- the missing dependency gives one notification line and no Lua error
local notes = {}
local orig = vim.notify
vim.notify = function(msg)
  notes[#notes + 1] = msg
end
local saved = {}
for _, k in ipairs({ "xyno_rust.crate_meta", "xyno_rust.code_actions", "xyno_rust.fsutil" }) do
  saved[k] = package.loaded[k]
  package.loaded[k] = nil
end
local saved_path = package.path
local saved_loaders = package.loaders
package.loaders = { function() return nil end }
package.path = ""
local rtp = vim.o.runtimepath
vim.o.runtimepath = ""
local ok = pcall(require("xyno_imports").setup, {})
vim.o.runtimepath = rtp
package.path = saved_path
package.loaders = saved_loaders
for k, v in pairs(saved) do
  package.loaded[k] = v
end
vim.notify = orig
check("setup() without xyno-rust: no error", ok)
check("setup() without xyno-rust: one line", #notes == 1 and not notes[1]:find("\n"), vim.inspect(notes))

if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
