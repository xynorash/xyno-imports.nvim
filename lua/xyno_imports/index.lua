-- xyno-imports engine: the `use` index of a workspace (what the project already imports).
-- Part of xyno_imports.engine (the facade merges every part into one table).
local M = {}

local Uses = require("xyno_imports.uses")
-- ------------------------------------------------------------ use index

local uses_cache = {} -- root -> { [file] = { paths } }

local function add_file_uses(map, file, text)
  local paths = Uses.use_paths(text)
  if #paths > 0 then
    map[file] = paths
  end
end

local function walk_uses(root)
  local map, n = {}, 0
  for name, t in
    vim.fs.dir(root, {
      depth = 8,
      -- vim.fs.dir: false = do not descend (the opposite of what "skip" suggests)
      skip = function(d)
        local base = vim.fs.basename(d)
        return not (base == "target" or base:sub(1, 1) == ".")
      end,
    })
  do
    if t == "file" and name:match("%.rs$") and n < 3000 then
      n = n + 1
      local f = io.open(root .. "/" .. name, "rb")
      if f then
        local text = f:read("*a")
        f:close()
        add_file_uses(map, root .. "/" .. name, text)
      end
    end
  end
  return map
end

--- `use` statements of every .rs file under root: cb({ [file] = { paths } }).
--- ripgrep with an argv list (multi-line statements included), a Lua walk when
--- it is not installed; cached per root until a save invalidates it.
function M.use_index(root, cb)
  if uses_cache[root] then
    return vim.schedule(function()
      cb(uses_cache[root])
    end)
  end
  local function done(map)
    uses_cache[root] = map
    cb(map)
  end
  if vim.fn.executable("rg") ~= 1 then
    return vim.schedule(function()
      done(walk_uses(root))
    end)
  end
  local argv = {
    "rg",
    "--json",
    "-U",
    "--max-filesize",
    "1M",
    "-g",
    "*.rs",
    "-g",
    "!target",
    "-e",
    "^[ \\t]*(pub(\\([^)]*\\))?[ \\t]+)?use[ \\t][^;]*;",
    "--",
    root,
  }
  local ok = pcall(vim.system, argv, { text = true, timeout = 20000 }, function(r)
    vim.schedule(function()
      if r.code ~= 0 and r.code ~= 1 then
        return done(walk_uses(root))
      end
      local by_file = {}
      for line in (r.stdout or ""):gmatch("[^\n]+") do
        local okj, rec = pcall(vim.json.decode, line)
        if okj and type(rec) == "table" and rec.type == "match" and rec.data and rec.data.path and rec.data.lines then
          local f = rec.data.path.text
          if f and rec.data.lines.text then
            by_file[f] = (by_file[f] or "") .. "\n" .. rec.data.lines.text
          end
        end
      end
      local map = {}
      for f, text in pairs(by_file) do
        add_file_uses(map, f, text)
      end
      done(map)
    end)
  end)
  if not ok then
    vim.schedule(function()
      done(walk_uses(root))
    end)
  end
end

function M.invalidate_uses(root)
  if root then
    uses_cache[root] = nil
  else
    uses_cache = {}
  end
end

return M
