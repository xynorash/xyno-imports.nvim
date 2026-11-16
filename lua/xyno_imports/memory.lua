-- xyno-imports engine: the per-project memory of chosen imports (stdpath("state")/xyno-imports/imports.json).
-- Part of xyno_imports.engine (the facade merges every part into one table).
local M = {}

-- ------------------------------------------------------------------ memory

local memory -- root -> { name -> path }

local function state_path()
  return require("xyno_imports.engine").state_file or (vim.fn.stdpath("state") .. "/xyno-imports/imports.json")
end

local function load_memory()
  if memory then
    return memory
  end
  memory = {}
  local f = io.open(state_path(), "rb")
  if f then
    local text = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
    if ok and type(data) == "table" then
      for root, names in pairs(data) do
        if type(root) == "string" and type(names) == "table" then
          memory[root] = {}
          for name, path in pairs(names) do
            -- from a file: only plain identifiers and paths are ever used
            if
              type(name) == "string"
              and name:match("^[%w_]+$")
              and type(path) == "string"
              and path:match("^[%w_]+[%w_:]*$")
            then
              memory[root][name] = path
            end
          end
        end
      end
    end
  end
  return memory
end

local function save_memory()
  local path = state_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local f = io.open(tmp, "wb")
  if not f then
    return false
  end
  f:write(vim.json.encode(memory))
  f:close()
  return require("xyno_rust.fsutil").rename(tmp, path) and true or false
end

--- Forget the in-memory copy (the next access reads the file again).
function M.reload_memory()
  memory = nil
end

function M.remembered(root, name)
  local m = load_memory()
  return root and m[root] and m[root][name] or nil
end

function M.remember(root, name, path)
  if not root or not tostring(name):match("^[%w_]+$") or not tostring(path):match("^[%w_]+[%w_:]*$") then
    return false
  end
  local m = load_memory()
  m[root] = m[root] or {}
  m[root][name] = path
  return save_memory()
end

--- Forget one name of a project, or all of them. Returns how many.
function M.forget(root, name)
  local m = load_memory()
  local n = 0
  if not m[root] then
    return 0
  end
  if name then
    if m[root][name] then
      m[root][name] = nil
      n = 1
    end
  else
    n = vim.tbl_count(m[root])
    m[root] = nil
  end
  if m[root] and next(m[root]) == nil then
    m[root] = nil
  end
  save_memory()
  return n
end

return M
