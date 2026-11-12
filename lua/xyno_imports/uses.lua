-- xyno-imports engine: reading `use` items: masking scanner, trees, bindings.
-- Part of xyno_imports.engine (the facade merges every part into one table).
local M = {}

-- --------------------------------------------------------------- use paths

local function blank(piece)
  return (piece:gsub("[^\n]", " "))
end

--- The text with comments (block comments nest), string and raw string contents and char
--- literals replaced by spaces; same length, newlines kept, so offsets stay valid. A lifetime
--- (`'a`) is not a char literal. Nothing that is left can hide a `;`, a brace or the word `use`
--- inside a string or a comment, which is what a pattern over the raw text got wrong.
function M.mask(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local s = text:find("[/\"']", i)
    if not s then
      out[#out + 1] = text:sub(i)
      break
    end
    out[#out + 1] = text:sub(i, s - 1)
    local c, nx = text:sub(s, s), text:sub(s + 1, s + 1)
    if c == "/" and nx == "/" then
      local e = text:find("\n", s, true) or (n + 1)
      out[#out + 1] = blank(text:sub(s, e - 1))
      i = e
    elseif c == "/" and nx == "*" then
      local depth, j = 1, s + 2
      while depth > 0 do
        local a = text:find("[/*]", j)
        if not a then
          j = n + 1
          break
        end
        local pair = text:sub(a, a + 1)
        if pair == "/*" then
          depth, j = depth + 1, a + 2
        elseif pair == "*/" then
          depth, j = depth - 1, a + 2
        else
          j = a + 1
        end
      end
      out[#out + 1] = blank(text:sub(s, j - 1))
      i = j
    elseif c == "/" then
      out[#out + 1] = "/"
      i = s + 1
    elseif c == '"' then
      -- raw string: r"..." / r#"..."# / br#"..."# (the prefix was copied above)
      local pre = text:sub(math.max(1, s - 40), s - 1)
      local hashes = pre:match("r(#*)$")
      local raw = false
      if hashes then
        local before = pre:sub(1, #pre - #hashes - 1)
        raw = not before:match("[%w_]$") or (before:match("[bc]$") and not before:sub(1, -2):match("[%w_]$")) and true or false
      end
      local j
      if raw then
        local close = '"' .. hashes
        local e = select(2, text:find(close, s + 1, true))
        j = (e or n) + 1
      else
        j = s + 1
        while j <= n do
          local a = text:find('[\\"]', j)
          if not a then
            j = n + 1
            break
          end
          if text:sub(a, a) == "\\" then
            j = a + 2
          else
            j = a + 1
            break
          end
        end
      end
      out[#out + 1] = '"' .. blank(text:sub(s + 1, j - 1))
      i = j
    else -- a quote: char literal or lifetime
      local e = text:match("^'\\[^\n']*'()", s)
        or text:match("^'[%z\1-\127\194-\244][\128-\191]*'()", s)
      if e then
        out[#out + 1] = blank(text:sub(s, e - 1))
        i = e
      else
        out[#out + 1] = "'"
        i = s + 1
      end
    end
  end
  return table.concat(out)
end

local function strip_comments(text)
  return M.mask(text)
end

local function join(prefix, segs)
  local t = {}
  for _, s in ipairs(prefix) do
    t[#t + 1] = s
  end
  for _, s in ipairs(segs) do
    t[#t + 1] = s
  end
  return t
end

local function tokenize(s)
  local toks, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    elseif s:sub(i, i + 1) == "::" then
      toks[#toks + 1] = "::"
      i = i + 2
    elseif c == "{" or c == "}" or c == "," or c == "*" then
      toks[#toks + 1] = c
      i = i + 1
    else
      local id = s:match("^r#[%w_]+", i) or s:match("^[%w_]+", i)
      if not id then
        i = i + 1
      else
        toks[#toks + 1] = id
        i = i + #id
      end
    end
  end
  return toks
end

--- `out` collects the imported paths; `binds` (optional) the bindings the statement
--- introduces: { path, name } with `name` the alias (`as x`), the last segment
--- otherwise, "_" for `as _` (binds nothing) and nil for a glob.
local function parse_tree(toks, i, prefix, out, binds)
  local segs = {}
  local alias
  while true do
    local t = toks[i]
    if t == "::" then
      i = i + 1
    elseif t == "{" then
      i = i + 1
      local base = join(prefix, segs)
      while toks[i] and toks[i] ~= "}" do
        local before = i
        i = parse_tree(toks, i, base, out, binds)
        if toks[i] == "," then
          i = i + 1
        end
        if i == before then
          i = i + 1
        end
      end
      return i + 1
    elseif t == "*" then
      local g = table.concat(join(prefix, segs), "::") .. "::*"
      out[#out + 1] = g
      if binds then
        binds[#binds + 1] = { path = g }
      end
      return i + 1
    elseif t and t:match("^[%w_#]+$") then
      segs[#segs + 1] = t
      i = i + 1
      if toks[i] == "as" then
        alias = toks[i + 1]
        i = i + 2
        break
      elseif toks[i] ~= "::" then
        break
      end
    else
      break
    end
  end
  if #segs > 0 then
    if segs[#segs] == "self" and (#segs > 1 or #prefix > 0) then
      segs[#segs] = nil
    end
    local path = table.concat(join(prefix, segs), "::")
    out[#out + 1] = path
    if binds then
      local last = join(prefix, segs)
      binds[#binds + 1] = { path = path, name = alias or last[#last], alias = alias ~= nil or nil }
    end
  end
  return i
end

local function strip_use(stmt)
  local body = strip_comments(stmt)
  return (body:gsub("^%s*pub%s*%b()", ""):gsub("^%s*pub%s+", ""):gsub("^%s*use%s+", ""):gsub("%s*;%s*$", ""))
end

--- The paths a `use` statement imports, braces expanded, aliases dropped:
--- "use a::{b, c::{self, d as e}};" -> a::b, a::c, a::c::d
function M.flatten_use(stmt)
  local out = {}
  parse_tree(tokenize(strip_use(stmt)), 1, {}, out)
  return out
end

--- The names a `use` statement binds: { { path, name, alias } }. `use a::b as c`
--- binds `c` (not `b`), `as _` binds nothing, a glob has no name.
function M.use_bindings(stmt)
  local out, binds = {}, {}
  parse_tree(tokenize(strip_use(stmt)), 1, {}, out, binds)
  return binds
end

--- Whether the `use` keyword at byte `s` of the masked text starts an item: the last thing before
--- it (a visibility `pub` or `pub(...)` skipped) is the start of the text, `;`, `{`, `}` or `]`
--- (the end of an attribute). `impl Trait + use<'a>` and `r#use` are not.
local function item_start(m, s)
  local p = s - 1
  local function is_pub(q)
    return m:sub(q - 2, q) == "pub" and not m:sub(q - 3, q - 3):match("[%w_]")
  end
  local function skip_ws()
    while p >= 1 and m:sub(p, p):match("%s") do
      p = p - 1
    end
  end
  skip_ws()
  if m:sub(p, p) == ")" then
    local depth = 0
    while p >= 1 do
      local ch = m:sub(p, p)
      if ch == ")" then
        depth = depth + 1
      elseif ch == "(" then
        depth = depth - 1
        if depth == 0 then
          break
        end
      end
      p = p - 1
    end
    p = p - 1
    skip_ws()
    if not is_pub(p) then
      return false
    end
    p = p - 3
    skip_ws()
  elseif is_pub(p) then
    p = p - 3
    skip_ws()
  end
  if p < 1 then
    return true
  end
  local ch = m:sub(p, p)
  return ch == ";" or ch == "{" or ch == "}" or ch == "]"
end

--- The `use` items of a source text, found on the masked text (see M.mask), so the keyword is
--- found wherever an item may start (after `{`, `;`, an attribute on the same line, ...) and never
--- inside a string or a comment. Each: { text = "use a::{b, c};", first = byte, last = byte }.
---@return { text: string, first: integer, last: integer }[]
function M.use_statements(text)
  local out = {}
  if not text:find("use", 1, true) then
    return out
  end
  local m = M.mask(text)
  local i = 1
  while true do
    local s = m:find("%f[%w_]use%f[^%w_]", i)
    if not s then
      break
    end
    i = s + 3
    if m:sub(s - 2, s - 1) ~= "r#" and item_start(m, s) then
      local e = m:find(";", s, true)
      if e then
        out[#out + 1] = { text = m:sub(s, e), first = s, last = e }
        i = e + 1
      end
    end
  end
  return out
end

--- All paths imported by the `use` statements of a text.
function M.use_paths(text)
  local out = {}
  for _, st in ipairs(M.use_statements(text)) do
    vim.list_extend(out, M.flatten_use(st.text))
  end
  return out
end

--- All bindings introduced by the `use` statements of a text (see use_bindings).
function M.use_binding_list(text)
  local out = {}
  for _, st in ipairs(M.use_statements(text)) do
    vim.list_extend(out, M.use_bindings(st.text))
  end
  return out
end

M._join = join
M._strip_comments = strip_comments

return M
