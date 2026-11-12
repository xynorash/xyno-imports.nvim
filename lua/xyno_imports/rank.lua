-- xyno-imports engine: candidates and the ranking (known traits, weights, score, decide).
-- Part of xyno_imports.engine (the facade merges every part into one table).
local M = {}

M.known_traits = {
  ["std::error::Error"] = true,
  ["std::fmt::Display"] = true,
  ["std::fmt::Debug"] = true,
  ["std::fmt::Write"] = true,
  ["std::io::Write"] = true,
  ["std::io::Read"] = true,
  ["std::io::BufRead"] = true,
  ["std::io::Seek"] = true,
  ["std::str::FromStr"] = true,
  ["std::hash::Hash"] = true,
  ["std::hash::Hasher"] = true,
  ["std::ops::Deref"] = true,
  ["std::ops::DerefMut"] = true,
  ["std::ops::Add"] = true,
  ["std::ops::Sub"] = true,
  ["std::ops::Mul"] = true,
  ["std::ops::Div"] = true,
  ["std::iter::FromIterator"] = true,
  ["std::borrow::Borrow"] = true,
  ["std::future::Future"] = true,
}

-- ----------------------------------------------------------- candidates

--- "Import `std::io::Error`" -> "std::io::Error" (nil for other titles).
function M.parse_title(title)
  local p = type(title) == "string" and title:match("^Import `([^`]+)`") or nil
  if not p then
    return nil
  end
  p = p:gsub("%s+as%s+.*$", "")
  if not p:match("^[%w_]+[%w_:]*$") then
    return nil
  end
  return p
end

local function make_candidate(path, extra)
  local segs = vim.split(path, "::", { plain = true })
  local c = {
    path = path,
    name = segs[#segs],
    crate = segs[1],
    parent = table.concat(vim.list_slice(segs, 1, #segs - 1), "::"),
  }
  if M.known_traits[path] then
    c.kind = "trait"
  end
  return vim.tbl_extend("force", c, extra or {})
end
M.candidate = make_candidate

local STD = { std = true, core = true, alloc = true }

-- ----------------------------------------------------------------- scoring

-- Every number the ranking uses. setup{ weights = {...} } overrides single keys
-- (validated, see M.set_weights); M.weights is the live table.
M.default_weights = {
  file = 4, -- per `use <path>` in this file
  sibling = 3, -- per `use <path>` in the module siblings
  crate = 2, -- per `use <path>` elsewhere in the crate
  near = 0.5, -- factor for a use from the same parent module (not the same item)
  cap = 5, -- uses counted per tier at most
  derive_macro = 10, -- derive context: candidate of a proc-macro crate
  derive_std = -4, -- derive context: a std item
  error_type = 5, -- error context: `...Error` name
  return_type = 8, -- matches the module of the enclosing fn's Result
  trait_pos = 5, -- a trait where a trait is expected
  shadowed_std = -3, -- a dependency offers the same name as a std item
  std_twin = -2, -- core/alloc item that std offers too
  dependency = 1, -- divided by the dependency position (dependency #1 gets all of it)
  not_dependency = -5, -- the crate is not a dependency yet
}
M.weights = vim.deepcopy(M.default_weights)

--- Validate and apply weight overrides: `w` is { name = number }. Unknown names, non-finite
--- or non-number values are refused (nothing is applied then). near must be within [0, 1],
--- cap must be a positive integer. Resets the weights not mentioned to their defaults.
--- Returns true, or false + a list of problems.
function M.set_weights(w)
  local errs = {}
  local merged = vim.deepcopy(M.default_weights)
  if w ~= nil and type(w) ~= "table" then
    return false, { "weights must be a table" }
  end
  for k, v in pairs(w or {}) do
    if M.default_weights[k] == nil then
      errs[#errs + 1] = ("unknown weight `%s`"):format(tostring(k))
    elseif type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
      errs[#errs + 1] = ("weight `%s` must be a finite number, got %s"):format(k, vim.inspect(v))
    elseif k == "near" and (v < 0 or v > 1) then
      errs[#errs + 1] = "weight `near` must be within [0, 1]"
    elseif k == "cap" and (v < 1 or v % 1 ~= 0) then
      errs[#errs + 1] = "weight `cap` must be a positive integer"
    else
      merged[k] = v
    end
  end
  if #errs > 0 then
    return false, errs
  end
  for k in pairs(M.weights) do
    M.weights[k] = nil
  end
  for k, v in pairs(merged) do
    M.weights[k] = v
  end
  return true
end

--- Return-type hint of a function: { error = bool (it returns a Result),
--- mod = the module/crate the Result or its error comes from }.
--- "io::Result<()>" -> mod io; "Result<T, io::Error>" -> mod io;
--- "anyhow::Result<T>" -> mod anyhow.
function M.parse_return(text)
  if type(text) ~= "string" or not text:find("Result", 1, true) then
    return nil
  end
  local r = { error = true }
  local qual = text:match("([%w_]+)::Result%s*<")
  if qual then
    r.mod = qual
  else
    local e = text:match("Result%s*<.*,%s*([%w_:]+)%s*>")
    local seg = e and e:match("([%w_]+)::[%w_]+$")
    r.mod = seg
  end
  return r
end

local function count_in(paths, cand)
  local W = M.weights
  local exact, near = 0, 0
  for _, p in ipairs(paths or {}) do
    if p == cand.path or vim.startswith(p, cand.path .. "::") then
      exact = exact + 1
    elseif cand.parent ~= "" and (p:match("^(.*)::[^:]+$") or "") == cand.parent then
      near = near + 1
    end
  end
  return math.min(exact, W.cap), math.min(near, W.cap)
end

--- Score of one candidate and the reasons for it.
--- facts = { uses = { file, sibling, crate = list of use paths }, ctx = {
---   derive, error, trait_pos, ret = { mod } }, dep_index = { crate -> 1.. },
---   proc_macro = { crate -> true }, shadowed = { name -> true } }
function M.score(cand, facts)
  local W = M.weights
  local score, why = 0, {}
  local function add(v, reason)
    if v ~= 0 then
      score = score + v
      why[#why + 1] = ("%s (%+g)"):format(reason, v)
    end
  end
  for _, tier in ipairs({ { "file", "this file" }, { "sibling", "module siblings" }, { "crate", "the crate" } }) do
    local exact, near = count_in(facts.uses and facts.uses[tier[1]], cand)
    if exact > 0 then
      add(exact * W[tier[1]], ("`use %s` %dx in %s"):format(cand.path, exact, tier[2]))
    end
    if near > 0 then
      add(near * W[tier[1]] * W.near, ("%d use(s) from %s in %s"):format(near, cand.parent, tier[2]))
    end
  end
  local ctx = facts.ctx or {}
  local is_std = STD[cand.crate] or false
  if ctx.derive then
    if facts.proc_macro and facts.proc_macro[cand.crate] then
      add(W.derive_macro, "derive macro of a proc-macro crate")
    elseif is_std then
      add(W.derive_std, "std items are not derive macros")
    end
  end
  if ctx.error and cand.name:match("Error$") then
    add(W.error_type, "error type in an error context")
  end
  if ctx.ret and ctx.ret.mod then
    local parent_last = cand.parent:match("([^:]+)$")
    if parent_last == ctx.ret.mod or cand.crate == ctx.ret.mod then
      add(W.return_type, ("matches the return type `%s::Result`"):format(ctx.ret.mod))
    end
  end
  if ctx.trait_pos and cand.kind == "trait" then
    add(W.trait_pos, "a trait where a trait is expected")
  end
  if facts.shadowed and facts.shadowed[cand.name] and is_std then
    add(W.shadowed_std, "a dependency offers the same name")
  end
  if cand.crate == "core" or cand.crate == "alloc" then
    if facts.std_twin and facts.std_twin[cand.name] then
      add(W.std_twin, "std offers it too")
    end
  end
  local idx = facts.dep_index and facts.dep_index[cand.crate]
  if idx then
    add(math.floor(W.dependency / idx * 10 + 0.5) / 10, ("dependency #%d"):format(idx))
  end
  if cand.add_crate then
    add(W.not_dependency, "not a dependency yet")
  end
  return score, why
end

--- Rank candidates (new list, best first; each gets .score and .why).
function M.rank(cands, facts)
  facts = vim.tbl_extend("force", {}, facts or {})
  local shadowed, std_twin, by_name = {}, {}, {}
  for _, c in ipairs(cands) do
    by_name[c.name] = by_name[c.name] or {}
    table.insert(by_name[c.name], c)
  end
  for name, list in pairs(by_name) do
    for _, c in ipairs(list) do
      if not STD[c.crate] and facts.dep_index and facts.dep_index[c.crate] then
        shadowed[name] = true
      end
      if c.crate == "std" then
        std_twin[name] = true
      end
    end
  end
  facts.shadowed, facts.std_twin = shadowed, std_twin
  local out = {}
  for _, c in ipairs(cands) do
    local copy = vim.tbl_extend("force", {}, c)
    copy.score, copy.why = M.score(c, facts)
    out[#out + 1] = copy
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.path < b.path
  end)
  return out
end

--- What to do with the candidates of one name. Returns { act, cand, why }:
--- act = "apply" | "ask" | "pick" | "none" | "off". A remembered choice wins
--- over ambiguity; add_crate candidates are never taken automatically.
function M.decide(mode, cands, remembered)
  if mode == "off" then
    return { act = "off" }
  end
  local real = vim.tbl_filter(function(c)
    return not c.add_crate
  end, cands)
  local pick, why
  if remembered then
    for _, c in ipairs(cands) do
      if c.path == remembered then
        pick, why = c, "remembered"
      end
    end
  end
  if not pick and #real == 1 and #cands == 1 then
    pick, why = real[1], "single"
  end
  if pick then
    return { act = mode == "single" and "apply" or "ask", cand = pick, why = why }
  end
  if #cands == 0 then
    return { act = "none" }
  end
  return { act = "pick" }
end

M._make_candidate = make_candidate
M._STD = STD

return M
