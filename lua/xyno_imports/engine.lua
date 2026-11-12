-- Imports without the menu: auto-import of unresolved names, ranked
-- disambiguation with a per-project memory, organize imports, import on paste.
--
--   * setup{ mode = ... } or vim.g.xyno_auto_import (wins) = "ask" (default, never silent) | "single" | "off"
--     After InsertLeave, after a save and after a paste the changed lines are
--     scanned for names that resolve to nothing (diagnostics of both tiers plus
--     a treesitter scan). rust-analyzer is asked for the code actions at each
--     one. Exactly one `Import X` (or a choice remembered for this project):
--     "single" applies it as one undo step with a one-line note, "ask" prompts
--     for one key (<CR>/y accepts, anything else dismisses for the session).
--     Several candidates are never guessed at: use :ImportName.
--   * :ImportName [name] (suggested key <leader>rI) lists the candidates ranked by what the
--     project already does (see M.score), best first, with the reasons; the
--     choice is remembered per project in stdpath("state")/xyno-imports/imports.json
--     and wins from then on (picker order, "single" auto-import). :ImportForget
--     [name] clears it.
--   * :ImportOrganize (suggested key <leader>rO): rust-analyzer's merge / normalize / remove
--     unused import assists, applied in one undo step.
--   * engine.resolve(name, ctx) for other modules, engine.register_source(fn)
--     for candidates the language server does not know (a crate that is not a
--     dependency yet): fn(name, ctx) -> { { path = "rand::Rng", crate = "rand",
--     add_crate = true, apply = function(cb) ... cb(ok, err) end }, ... }.
--     Such candidates are ranked last and never applied automatically.
local ca = require("xyno_rust.code_actions")
local cm = require("xyno_rust.crate_meta")

local M = {}

-- The parts live next to this file: uses (reading `use` items), memory (per-project choices), rank
-- (candidates, weights, scoring) and index (the project's `use` index). This file merges them
-- into the one table other modules and the specs use, and holds the stateful rest.
local Parts = { "uses", "memory", "rank", "index" }
local P = {}
for _, name in ipairs(Parts) do
  P[name] = require("xyno_imports." .. name)
end

--- Workspace root of a file for the hot paths (scans, undo guard, commands): the cached
--- cargo answer or the file-system one, never waiting for cargo (xyno-rust's root() would
--- block up to cargo.config.wait_ms on a cold cache). resolve() asks cargo asynchronously.
local function root_of(file)
  if file == "" then
    return nil
  end
  return require("xyno_rust.rust_context").root(file, { nowait = true })
end

M.config = {
  debounce = 600, -- ms between the last change and the scan
  max_names = 8, -- names looked at per scan
  retries = 5, -- "content modified" retries of a code action request
  retry_ms = 400,
  organize_rounds = 30,
  max_lines = 20000, -- the syntax scan reads the whole buffer per edit: skipped above this
  source_wait_ms = 4000, -- how long resolve() waits for the async sources (crates.io)
}
M.state_file = nil -- default stdpath("state")/xyno-imports/imports.json
for _, name in ipairs(Parts) do
  for k, v in pairs(P[name]) do
    if k:sub(1, 1) ~= "_" then
      M[k] = v
    end
  end
end
local make_candidate, STD, join = P.rank._make_candidate, P.rank._STD, P.uses._join

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "imports" })
end

M.default_mode = "ask" -- set by setup{ mode = ... }

--- "ask" (default), "single" or "off".
function M.mode()
  local v = vim.g.xyno_auto_import
  if v == "single" or v == "off" or v == "ask" then
    return v
  end
  return M.default_mode
end

-- --------------------------------------------------------- treesitter bits

local function ts_root(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "rust")
  if not ok or not parser then
    return nil
  end
  local ok2, trees = pcall(function()
    return parser:parse()
  end)
  if not ok2 or not trees or not trees[1] then
    return nil
  end
  return trees[1]:root()
end

local function node_text(node, buf)
  return vim.treesitter.get_node_text(node, buf)
end

--- Syntax context of a position: { derive, error, trait_pos, ret, in_macro_def }.
function M.context_at(buf, row, col)
  local ctx = {}
  local root = ts_root(buf)
  if not root then
    return ctx
  end
  local node = root:named_descendant_for_range(row, col, row, col)
  local fn_done = false
  while node do
    local t = node:type()
    if t == "macro_definition" then
      ctx.in_macro_def = true
    elseif t == "attribute_item" then
      local text = node_text(node, buf)
      if text:match("^#%[%s*derive%s*%(") or text:find("derive%s*%(") then
        ctx.derive = true
      end
    elseif t == "impl_item" then
      local tr = node:field("trait")[1]
      if tr then
        local name = node_text(tr, buf):gsub("<.*$", ""):match("([%w_]+)$")
        if name == "From" or name == "Display" or name == "Error" then
          ctx.error = true
        end
        if vim.treesitter.is_in_node_range(tr, row, col) then
          ctx.trait_pos = true
        end
      end
    elseif t == "function_item" and not fn_done then
      fn_done = true
      local rt = node:field("return_type")[1]
      if rt then
        local r = M.parse_return(node_text(rt, buf))
        if r then
          ctx.ret = r
          ctx.error = true
        end
      end
    elseif t == "trait_bounds" or t == "abstract_type" or t == "dynamic_type" or t == "where_predicate" then
      ctx.trait_pos = true
    end
    node = node:parent()
  end
  return ctx
end

local PRELUDE = {}
for n in
  ([[Option Some None Result Ok Err Vec String Box Default Clone Copy Send Sync Sized Drop Fn FnMut FnOnce
Iterator IntoIterator DoubleEndedIterator ExactSizeIterator Extend From Into TryFrom TryInto AsRef AsMut ToString
ToOwned PartialEq Eq PartialOrd Ord Hash Self Unpin]]):gmatch("%S+")
do
  PRELUDE[n] = true
end

-- derive macros the prelude brings in
local PRELUDE_DERIVES = { Debug = true, Clone = true, Copy = true, PartialEq = true, Eq = true, PartialOrd = true, Ord = true, Hash = true, Default = true }

local DECL = { "struct", "enum", "trait", "type", "union", "mod", "fn", "const", "static" }

local function declared_names(text)
  local set = {}
  for l in (text or ""):gmatch("[^\n]+") do
    for _, kw in ipairs(DECL) do
      local n = l:match("^%s*[%w_()%s]-%f[%w_]" .. kw .. "%s+([%w_]+)")
      if n then
        set[n] = true
      end
    end
    local m = l:match("macro_rules!%s*([%w_]+)")
    if m then
      set[m] = true
    end
    local x = l:match("^%s*extern%s+crate%s+([%w_]+)")
    if x then
      set[x] = true
    end
  end
  return set
end

-- Node names differ between grammar versions: each pattern is tried alone and
-- the ones this grammar does not know are left out.
local GENERIC_QS
local function generic_queries()
  if not GENERIC_QS then
    GENERIC_QS = {}
    for _, src in ipairs({
      "(type_parameter name: (type_identifier) @g)",
      "(constrained_type_parameter left: (type_identifier) @g)",
      "(const_parameter name: (identifier) @g)",
      "(associated_type name: (type_identifier) @g)",
    }) do
      local ok, q = pcall(vim.treesitter.query.parse, "rust", src)
      if ok then
        GENERIC_QS[#GENERIC_QS + 1] = q
      end
    end
  end
  return GENERIC_QS
end

local SCAN_Q
local function scan_query()
  if not SCAN_Q then
    SCAN_Q = vim.treesitter.query.parse(
      "rust",
      [[(type_identifier) @name
        (scoped_identifier path: (identifier) @head)
        (scoped_type_identifier path: (identifier) @head)
        (attribute_item (attribute (identifier) @attr (token_tree (identifier) @derive)))]]
    )
  end
  return SCAN_Q
end

local function under(node, types)
  while node do
    if types[node:type()] then
      return true
    end
    node = node:parent()
  end
  return false
end

local known_memo = {} -- buf -> { tick, known }

--- Names in rows [from, to] that look unresolved by syntax alone: type names
--- and path heads that nothing in the file declares, imports or binds as a
--- generic, derives of the prelude excluded. A superset on purpose: the
--- language server decides, a name it knows nothing to import is dropped.
--- opts.meta (cargo metadata) enables lowercase path heads (`io::Error`).
--- Returns { { name, row, col, end_col, src = "ts" } } (rows 0-based).
function M.scan_syntax(buf, from, to, opts)
  opts = opts or {}
  if vim.api.nvim_buf_line_count(buf) > M.config.max_lines then
    return {}
  end
  local root = ts_root(buf)
  if not root then
    return {}
  end
  -- the whole-buffer part (declarations, uses, generics) is the same for every row range of
  -- one buffer state: computed once per changedtick
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local memo = known_memo[buf]
  local known
  if memo and memo.tick == tick then
    known = memo.known
  else
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    known = declared_names(text)
    for _, b in ipairs(M.use_binding_list(text)) do
      -- `use a::B as C` binds C, not B; `as _` binds nothing
      if b.name and b.name ~= "_" then
        known[b.name] = true
      end
    end
    for _, gq in ipairs(generic_queries()) do
      for _, node in gq:iter_captures(root, buf, 0, -1) do
        known[node_text(node, buf)] = true
      end
    end
    known_memo[buf] = { tick = tick, known = known }
  end
  local file = vim.api.nvim_buf_get_name(buf)
  local croot = root_of(file)
  local out, seen = {}, {}
  local skip = { use_declaration = true, macro_definition = true }
  local q = scan_query()
  for id, node in q:iter_captures(root, buf, from, to + 1) do
    local cap = q.captures[id]
    local name = node_text(node, buf)
    local r, c, _, ec = node:range()
    local ok = not known[name] and not PRELUDE[name] and not under(node, skip)
    if ok and cap == "name" then
      ok = not name:match("^%u%d?$")
    elseif ok and cap == "head" then
      if name:match("^%l") then
        ok = opts.meta ~= nil and croot ~= nil and cm.is_known_path_head(croot, name, { meta = opts.meta, file = file }) == nil
      end
    elseif ok and cap == "derive" then
      local prev, nxt = node:prev_sibling(), node:next_sibling()
      local attr = node:parent():parent():child(0)
      ok = attr and node_text(attr, buf) == "derive" and not (prev and prev:type() == "::") and not (nxt and nxt:type() == "::")
      ok = ok and name:match("^%u") ~= nil and not PRELUDE_DERIVES[name]
    elseif cap == "attr" then
      ok = false
    end
    local key = r .. ":" .. c
    if ok and not seen[key] and r >= from and r <= to then
      seen[key] = true
      out[#out + 1] = { name = name, row = r, col = c, end_col = ec, src = "ts" }
    end
  end
  return out
end

local UNRESOLVED = { "cannot find", "undeclared", "failed to resolve", "unresolved" }

--- Unresolved names the diagnostics of the buffer (both tiers) report in the rows.
function M.scan_diagnostics(buf, from, to)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local msg = (d.message or ""):lower()
    local hit = false
    for _, p in ipairs(UNRESOLVED) do
      hit = hit or msg:find(p, 1, true) ~= nil
    end
    if hit and not msg:find("unresolved import", 1, true) and d.lnum >= from and d.lnum <= to then
      local name
      local line = vim.api.nvim_buf_get_lines(buf, d.lnum, d.lnum + 1, false)[1] or ""
      local ec = d.end_lnum == d.lnum and d.end_col or #line
      local txt = line:sub(d.col + 1, ec)
      if txt:match("^[%a_][%w_]*$") then
        name = txt
      else
        local b = (d.message or ""):match("`([%w_:]+)`")
        local head = b and b:match("^([%w_]+)")
        if head and line:find(head, d.col + 1, true) then
          name = head
        end
      end
      if name and not PRELUDE[name] then
        local c = line:find(name, d.col + 1, true)
        if c then
          out[#out + 1] = { name = name, row = d.lnum, col = c - 1, end_col = c - 1 + #name, src = "diag", diag = d }
        end
      end
    end
  end
  return out
end

--- Diagnostics + syntax, one entry per position, none inside a macro
--- definition. Entries of the diagnostics win (they carry the diagnostic).
function M.unresolved(buf, from, to, opts)
  local out, seen = {}, {}
  local function add(list)
    for _, p in ipairs(list) do
      local key = p.row .. ":" .. p.col
      -- context_at (a treesitter walk) only for hits that survive the dedup
      if not seen[key] and not M.context_at(buf, p.row, p.col).in_macro_def then
        seen[key] = true
        out[#out + 1] = p
      end
    end
  end
  add(M.scan_diagnostics(buf, from, to))
  add(M.scan_syntax(buf, from, to, opts))
  table.sort(out, function(a, b)
    return a.row ~= b.row and a.row < b.row or (a.row == b.row and a.col < b.col)
  end)
  return out
end

-- ------------------------------------------------------------------ facts

local function is_proc_macro(dep)
  local dir = dep.resolved and dep.resolved.dir
  local toml = dir and cm.read_manifest(dir)
  return toml ~= nil and toml:find("proc[-_]macro%s*=%s*true") ~= nil
end

--- Everything the scoring wants to know about a position, gathered async:
--- cb(facts) (never fails: what cannot be read is left out).
function M.facts_async(buf, pos, cands, cb, root)
  local file = vim.api.nvim_buf_get_name(buf)
  local facts = { uses = { file = {}, sibling = {}, crate = {} }, ctx = {}, dep_index = {}, proc_macro = {} }
  if pos then
    facts.ctx = M.context_at(buf, pos[1], pos[2])
  end
  facts.uses.file = M.use_paths(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
  root = root or root_of(file)
  local function with_meta(meta)
    if meta then
      local member = file ~= "" and cm.member_of(meta, file) or nil
      local i = 0
      for _, d in ipairs(meta.dependencies) do
        if (not member or d.member == member.name) and d.kind == "normal" then
          i = i + 1
          facts.dep_index[d.alias] = facts.dep_index[d.alias] or i
          if is_proc_macro(d) then
            facts.proc_macro[d.alias] = true
          end
        end
      end
    end
    cb(facts)
  end
  local function with_uses(map)
    local dir = file ~= "" and vim.fs.dirname(file) or nil
    local crate_dir = file ~= "" and vim.fs.root(file, "Cargo.toml") or nil
    for f, paths in pairs(map or {}) do
      if f ~= file then
        if dir and vim.fs.dirname(f) == dir then
          vim.list_extend(facts.uses.sibling, paths)
        elseif crate_dir and vim.startswith(f, crate_dir .. "/") then
          vim.list_extend(facts.uses.crate, paths)
        end
      end
    end
    cm.metadata_async(root, function(meta)
      with_meta(meta)
    end)
  end
  if not root then
    return vim.schedule(function()
      cb(facts)
    end)
  end
  M.use_index(root, with_uses)
end

-- ------------------------------------------------------------ sources

local sources = {}
local async_sources = {} -- fn -> true: fn(name, ctx, cb) answers through cb(list)

--- Register fn(name, ctx) -> { { path, crate, add_crate = true, apply = fn,
--- guess = bool, note = text }, ... } for candidates rust-analyzer does not
--- offer. ctx = the resolve() context plus bufnr, root, pos and
--- local_candidates (what rust-analyzer offered: a source that only fills gaps
--- returns nothing when it is not empty). With opts.async the function is
--- fn(name, ctx, cb) and may answer later (cb(list)); resolve waits for it at
--- most M.config.source_wait_ms. Returns a function that unregisters it.
function M.register_source(fn, opts)
  if not vim.tbl_contains(sources, fn) then
    sources[#sources + 1] = fn
  end
  async_sources[fn] = (opts and opts.async) or nil
  return function()
    for i, f in ipairs(sources) do
      if f == fn then
        table.remove(sources, i)
        async_sources[fn] = nil
        return
      end
    end
  end
end

local function add_extras(out, list, have)
  for _, e in ipairs(type(list) == "table" and list or {}) do
    if type(e) == "table" and type(e.path) == "string" and e.path:match("^[%w_]+[%w_:]*$") and not have[e.path] then
      have[e.path] = true
      out[#out + 1] = make_candidate(e.path, {
        crate = e.crate or e.path:match("^[%w_]+"),
        add_crate = e.add_crate,
        apply = e.apply,
        kind = e.kind,
        guess = e.guess,
        note = type(e.note) == "string" and e.note or nil,
      })
    end
  end
end

local function extra_candidates(name, ctx, have)
  local out = {}
  for _, fn in ipairs(sources) do
    if not async_sources[fn] then
      local ok, list = pcall(fn, name, ctx)
      add_extras(out, ok and list or nil, have)
    end
  end
  return out
end

--- The async sources: cb(candidates) once all answered or the wait is over.
local function extra_candidates_async(name, ctx, have, cb)
  local pending, out, finished = 0, {}, false
  local function done()
    if not finished then
      finished = true
      cb(out)
    end
  end
  for _, fn in ipairs(sources) do
    if async_sources[fn] then
      pending = pending + 1
      local ok = pcall(fn, name, ctx, function(list)
        if not finished then
          add_extras(out, list, have)
          pending = pending - 1
          if pending == 0 then
            done()
          end
        end
      end)
      if not ok then
        pending = pending - 1
      end
    end
  end
  if pending <= 0 then
    return done()
  end
  vim.defer_fn(done, M.config.source_wait_ms)
end

-- ---------------------------------------------------- asking the server

local function busy(errs)
  for _, e in ipairs(errs or {}) do
    if e.code == -32801 or e.code == -32802 or tostring(e.message or ""):lower():find("content modified", 1, true) then
      return true
    end
  end
  return false
end

-- rust-analyzer puts the id of the assist in `data.id` ("auto_import:QuickFix:3:"), which does not
-- depend on the language of the title. Detection order: that id, then the shape of the
-- action (a quickfix whose edit inserts a `use`), then the English title.
local function assist_id(a)
  local id = type(a.data) == "table" and a.data.id or nil
  return type(id) == "string" and id:match("^([%w_]+)") or nil
end

--- The `use` paths an edit inserts or rewrites (workspace edit: changes or documentChanges).
local function edit_use_paths(edit)
  local out = {}
  if type(edit) ~= "table" then
    return out
  end
  local function scan(edits)
    for _, e in ipairs(edits or {}) do
      if type(e.newText) == "string" then
        vim.list_extend(out, M.use_paths(e.newText))
      end
    end
  end
  for _, edits in pairs(edit.changes or {}) do
    scan(edits)
  end
  for _, dc in ipairs(edit.documentChanges or {}) do
    scan(dc.edits)
  end
  return out
end

--- The path an import code action brings in, or nil when the action is not an import.
--- Matches by the assist id (data.id), then by the edit shape, then by the English title
--- "Import `a::B`"; the path is taken from the backticked part of the title (any language)
--- or, when the title has none, from the single path the edit inserts.
function M.import_path(a)
  if type(a) ~= "table" then
    return nil
  end
  local viaid = assist_id(a) == "auto_import"
  local title = type(a.title) == "string" and a.title or ""
  local ticked = title:match("`([^`]+)`")
  if ticked then
    ticked = ticked:gsub("%s+as%s+.*$", "")
    if not ticked:match("^[%w_]+[%w_:]*$") then
      ticked = nil
    end
  end
  if viaid then
    if ticked then
      return ticked
    end
    local ps = edit_use_paths(a.edit)
    return #ps == 1 and ps[1]:match("^[%w_:]+$") and ps[1] or nil
  end
  if assist_id(a) then
    return nil -- some other assist (its id is known and is not an import)
  end
  local english = M.parse_title(title)
  if english then
    return english
  end
  -- shape: a quickfix whose edit adds exactly one `use`; the title only names the path
  if a.kind and tostring(a.kind):match("^quickfix") and ticked then
    local ps = edit_use_paths(a.edit)
    if #ps == 1 and (ps[1] == ticked or ps[1]:match("::" .. ticked:gsub("%p", "%%%0") .. "$") or ticked:match("::" .. ps[1]:gsub("%p", "%%%0") .. "$")) then
      return ticked
    end
  end
  return nil
end

--- Import candidates rust-analyzer offers for the name at `pos`
--- ({ row, col, end_col }): cb(list of candidates, err).
function M.candidates_at(buf, pos, cb, diags, tries)
  tries = tries or 0
  local range = { start = { pos.row, pos.col }, ["end"] = { pos.row, pos.end_col or pos.col } }
  ca.request(buf, range, { diagnostics = diags, only = { "quickfix" } }, function(list, errs)
    if busy(errs) and tries < M.config.retries then
      return vim.defer_fn(function()
        if vim.api.nvim_buf_is_valid(buf) then
          M.candidates_at(buf, pos, cb, diags, tries + 1)
        end
      end, M.config.retry_ms)
    end
    local out, have = {}, {}
    for _, a in ipairs(list) do
      local path = M.import_path(a)
      if path and not have[path] then
        have[path] = true
        out[#out + 1] = make_candidate(path, { action = a })
      end
    end
    cb(out, errs and #out == 0 and tostring(errs[1].message or "request failed") or nil)
  end)
end

local function word_range(buf, name)
  -- the first use of `name` as a whole word outside of `use` items (a multi-line tree included),
  -- comments and strings
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local m = M.mask(text)
  for _, st in ipairs(M.use_statements(text)) do
    m = m:sub(1, st.first - 1) .. (m:sub(st.first, st.last):gsub("[^\n]", " ")) .. m:sub(st.last + 1)
  end
  local s = 1
  while true do
    local a, b = m:find(name, s, true)
    if not a then
      return nil
    end
    local before, after = m:sub(a - 1, a - 1), m:sub(b + 1, b + 1)
    if not before:match("[%w_]") and not after:match("[%w_]") then
      local row = select(2, m:sub(1, a - 1):gsub("\n", "")) -- newlines before it
      local line_start = (m:sub(1, a - 1):match(".*\n()") or 1)
      return { row = row, col = a - line_start, end_col = b - line_start + 1 }
    end
    s = b + 1
  end
end

M.word_range = word_range

--- Ranked candidates of `name`, for other modules (the derive acceptance of
--- macro-attrs, the crate-adding stage).
---   ctx = { bufnr = 0, pos = { row, col } (default: the name's first use in
---           the buffer), derive = true (override the syntactic context),
---           context = {..} (more context overrides), cb = fn }
--- Result: { name, candidates = ranked (best first, .score/.why/.action),
--- best, remembered = the candidate remembered for this project (if offered),
--- choice = remembered or the only candidate (what "single" mode would take),
--- unambiguous = bool, root }.
--- Asynchronous: the result goes to ctx.cb(result). There is no blocking form (it used to
--- spin vim.wait for up to 30 s, which froze the UI); a call without ctx.cb returns nil
--- and a message and does nothing.
function M.resolve(name, ctx)
  ctx = ctx or {}
  if type(ctx.cb) ~= "function" then
    return nil, "xyno_imports.engine.resolve needs ctx.cb (it is asynchronous)"
  end
  if type(name) ~= "string" or not name:match("^[%w_]+$") then
    local r = { name = name, candidates = {}, unambiguous = false }
    vim.schedule(function()
      ctx.cb(r)
    end)
    return
  end
  local buf = ctx.bufnr and ctx.bufnr ~= 0 and ctx.bufnr or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local root
  local pos = ctx.pos and { row = ctx.pos[1], col = ctx.pos[2], end_col = ctx.pos[2] + #name } or word_range(buf, name)

  local rank_and_report
  local function finish(cands)
    local have = {}
    for _, c in ipairs(cands) do
      have[c.path] = true
    end
    if ctx.sources == false then
      return rank_and_report(cands)
    end
    local sctx = vim.tbl_extend("force", ctx, { bufnr = buf, root = root, pos = pos, local_candidates = vim.list_slice(cands) })
    vim.list_extend(cands, extra_candidates(name, sctx, have))
    extra_candidates_async(name, sctx, have, function(more)
      vim.list_extend(cands, more)
      rank_and_report(cands)
    end)
  end

  rank_and_report = function(cands)
    M.facts_async(buf, pos and { pos.row, pos.col } or nil, cands, function(facts)
      facts.ctx = vim.tbl_extend("force", facts.ctx or {}, ctx.context or {}, ctx.derive and { derive = true } or {})
      local ranked = M.rank(cands, facts)
      local rem = root and M.remembered(root, name)
      local remembered
      for _, c in ipairs(ranked) do
        if c.path == rem then
          remembered = c
        end
      end
      local real = vim.tbl_filter(function(c)
        return not c.add_crate
      end, ranked)
      local choice = remembered or (#ranked == 1 and real[1]) or nil
      local result = {
        name = name,
        root = root,
        candidates = ranked,
        best = ranked[1],
        remembered = remembered,
        choice = choice,
        unambiguous = choice ~= nil,
        facts = facts,
      }
      ctx.cb(result)
    end, root)
  end

  local function start()
    if pos then
      local diags = {}
      for _, d in ipairs(vim.diagnostic.get(buf, { lnum = pos.row })) do
        diags[#diags + 1] = d
      end
      M.candidates_at(buf, pos, function(cands)
        finish(cands)
      end, diags)
    else
      vim.schedule(function()
        finish({})
      end)
    end
  end
  if file == "" then
    return start()
  end
  require("xyno_rust.rust_context").root_async(file, function(r)
    root = r
    start()
  end)
end

-- ------------------------------------------------------------- applying

--- Apply a candidate (a language server action or the source's own apply).
--- cb(ok, err). opts.join: undojoin to the previous edit (one undo step).
function M.apply_candidate(buf, cand, cb, opts)
  opts = opts or {}
  if not vim.bo[buf].modifiable then
    return cb(false, "buffer is not modifiable")
  end
  if cand.action then
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    return ca.resolve_async(cand.action, function(a, err)
      if not a then
        return cb(false, err)
      end
      if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        return cb(false, "buffer changed meanwhile")
      end
      ca.apply_async(a, cb, { join = opts.join })
    end)
  end
  if type(cand.apply) == "function" then
    return cand.apply(cb)
  end
  cb(false, "needs the crate added first: " .. (cand.crate or cand.path))
end

local last_import = {} -- buf -> { name, seq } for the undo guard
local dismissed = {} -- root .. "\0" .. name .. "\0" .. path -> true (this session)

local function undo_seq(buf)
  local ok, t = pcall(vim.api.nvim_buf_call, buf, function()
    return vim.fn.undotree()
  end)
  return ok and t.seq_cur or 0
end

--- Replace in specs; default: a confirm dialog. Not echo + getcharstr: a notification UI hides
--- that prompt after a few seconds while nvim still waits, and the next key typed (":w") was
--- taken as the answer. confirm() stays until y/n/<CR>/<Esc> and ignores other keys. Without a
--- UI (headless) nothing can answer: no.
function M.ask_key(cand, name)
  if #vim.api.nvim_list_uis() == 0 then
    return false
  end
  local ok, n = pcall(vim.fn.confirm, ("Import %s?"):format(cand.path), "&Yes\n&No", 1)
  return ok and n == 1
end

local ns = vim.api.nvim_create_namespace("xyno_imports")

local function dkey(root, name, path)
  return table.concat({ root or "", name, path }, "\0")
end

--- Handle the unresolved names of rows [from, to]: auto-import per mode.
--- opts = { mode, join_all (default true), done = fn(n_imported) }
function M.run(buf, from, to, opts)
  opts = opts or {}
  local mode = opts.mode or M.mode()
  if mode == "off" or not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    return opts.done and opts.done(0)
  end
  if #ca.clients(buf) == 0 then
    return opts.done and opts.done(0)
  end
  local file = vim.api.nvim_buf_get_name(buf)
  local root = root_of(file)
  local nrows = vim.api.nvim_buf_line_count(buf)
  from, to = math.max(0, math.min(from, nrows - 1)), math.max(0, math.min(to, nrows - 1))
  local function go(meta)
    local okf, found = pcall(M.unresolved, buf, from, to, { meta = meta })
    if not okf then
      notify("import scan failed: " .. tostring(found), vim.log.levels.WARN)
      return opts.done and opts.done(0)
    end
    local names, queue = {}, {}
    for _, p in ipairs(found) do
      if not names[p.name] and #queue < M.config.max_names then
        names[p.name] = true
        p.mark = vim.api.nvim_buf_set_extmark(buf, ns, p.row, p.col, { end_col = p.end_col, right_gravity = false })
        queue[#queue + 1] = p
      end
    end
    local imported, i = 0, 0
    local function finish()
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      if opts.done then
        opts.done(imported)
      end
    end
    local function nextp()
      i = i + 1
      local p = queue[i]
      if not p or not vim.api.nvim_buf_is_valid(buf) then
        return finish()
      end
      local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, p.mark, { details = true })
      if not m[1] then
        return nextp()
      end
      local cur = { row = m[1], col = m[2], end_col = m[3] and m[3].end_col or (m[2] + #p.name) }
      local line = vim.api.nvim_buf_get_lines(buf, cur.row, cur.row + 1, false)[1] or ""
      if line:sub(cur.col + 1, cur.col + #p.name) ~= p.name then
        return nextp() -- the text under the mark was edited meanwhile
      end
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      local diags = p.diag and { p.diag } or {}
      M.candidates_at(buf, cur, function(cands)
        if not vim.api.nvim_buf_is_valid(buf) then
          return finish()
        end
        local rem = root and M.remembered(root, p.name)
        local d = M.decide(mode, cands, rem)
        if d.act == "none" or d.act == "pick" or (d.cand and (dismissed[dkey(root, p.name, d.cand.path)] or dismissed[dkey(root, p.name, "*")])) then
          return nextp()
        end
        local function apply()
          if vim.api.nvim_buf_get_changedtick(buf) ~= tick then
            return nextp() -- typed since: the next run looks again
          end
          M.apply_candidate(buf, d.cand, function(ok, err)
            if ok then
              imported = imported + 1
              last_import[buf] = { name = p.name, seq = undo_seq(buf) }
              notify("imported " .. d.cand.path)
            elseif err then
              notify(("cannot import %s: %s"):format(d.cand.path, err), vim.log.levels.WARN)
            end
            nextp()
          end, { join = imported > 0 })
        end
        if d.act == "ask" then
          if vim.api.nvim_get_current_buf() ~= buf or vim.fn.mode() ~= "n" then
            return nextp()
          end
          if p.answered or M.ask_key(d.cand, p.name) then
            if not p.answered and vim.api.nvim_buf_get_changedtick(buf) ~= tick then
              -- typed while the question was open: the candidate's edit is stale; look again
              -- at the extmark instead of dropping the yes
              p.answered = true
              i = i - 1
              return nextp()
            end
            apply()
          else
            dismissed[dkey(root, p.name, d.cand.path)] = true
            nextp()
          end
        else
          apply()
        end
      end, diags)
    end
    nextp()
  end
  -- lowercase path heads (`io::Error`) need the dependency list; the metadata
  -- is cached, a failure only means those heads are left to the diagnostics
  if root then
    cm.metadata_async(root, function(meta)
      if vim.api.nvim_buf_is_valid(buf) then
        go(meta)
      end
    end)
  else
    go(nil)
  end
end

-- ----------------------------------------------------------- :ImportName

--- Picker entries: best first, the reasons after the path.
function M.format_item(c)
  local tag = c.remembered and "  (remembered)" or ""
  if c.add_crate then
    tag = tag .. "  (adds the crate)"
  end
  if c.guess then
    tag = tag .. "  (guess)"
  end
  if c.note then
    tag = tag .. "  " .. c.note
  end
  return ("%s  [%g]%s  %s"):format(c.path, math.floor(c.score * 10 + 0.5) / 10, tag, #c.why > 0 and table.concat(c.why, "; ") or "no signals")
end

M.select = function(...)
  return vim.ui.select(...)
end

--- Interactive: rank the candidates of `name` (default: the word under the
--- cursor), let the user pick (best first), apply and remember the choice.
function M.import_name(name)
  local buf = vim.api.nvim_get_current_buf()
  name = (name and name ~= "") and name or vim.fn.expand("<cword>")
  if not name:match("^[%w_]+$") then
    return notify("no name to import under the cursor", vim.log.levels.WARN)
  end
  local c = vim.api.nvim_win_get_cursor(0)
  local pos
  if name == vim.fn.expand("<cword>") then
    local line = vim.api.nvim_get_current_line()
    local s = line:sub(1, c[2] + 1):find("[%w_]*$")
    pos = { c[1] - 1, s - 1 }
  end
  M.resolve(name, {
    bufnr = buf,
    pos = pos,
    cb = function(res)
      if #res.candidates == 0 then
        return notify(("no import candidates for %s (is it already in scope?)"):format(name), vim.log.levels.WARN)
      end
      for _, cand in ipairs(res.candidates) do
        cand.remembered = res.remembered and res.remembered.path == cand.path or nil
      end
      -- the remembered choice leads the list (the "preselected" entry)
      local items = vim.deepcopy(res.candidates)
      if res.remembered then
        -- no table.sort: LuaJIT's is not stable and would scramble the ranked order
        local first, rest = {}, {}
        for _, c in ipairs(items) do
          table.insert(c.remembered and first or rest, c)
        end
        items = vim.list_extend(first, rest)
      end
      local by_path = {}
      for _, cand in ipairs(res.candidates) do
        by_path[cand.path] = cand
      end
      M.select(items, { prompt = "Import " .. name, format_item = M.format_item }, function(choice)
        if not choice then
          return
        end
        local cand = by_path[choice.path] or choice
        M.apply_candidate(buf, cand, function(ok, err)
          if ok then
            -- a crate-adding guess is not a settled choice
            if res.root and not cand.add_crate then
              M.remember(res.root, name, cand.path)
            end
            notify("imported " .. cand.path)
          else
            notify(("cannot import %s: %s"):format(cand.path, err or "failed"), vim.log.levels.WARN)
          end
        end)
      end)
    end,
  })
end

-- -------------------------------------------------------------- organize

-- What counts as an organize assist. rust-analyzer's assist ids (data.id, independent of the
-- language of the title) first, the kind source.organizeImports, then the English titles
-- measured on rust-analyzer 1.99 ("Merge imports" and "Normalize import" are refactor.rewrite,
-- offered at a cursor inside a `use`, not for a selection of it; "Remove unnecessary braces"
-- and "Remove all unused imports" are quickfixes).
local ORGANIZE_IDS = { merge_imports = true, normalize_import = true, remove_unused_imports = true, unnecessary_braces_in_use_statement = true }
local ORGANIZE = { "^Merge imports", "^Normalize import", "^Remove unnecessary braces", "^Remove all unused imports" }

local function organize_match(a)
  if tostring(a.kind or ""):match("^source%.organizeImports") then
    return true
  end
  local id = assist_id(a)
  if id then
    return ORGANIZE_IDS[id] == true
  end
  for _, p in ipairs(ORGANIZE) do
    if (a.title or ""):find(p) then
      return true
    end
  end
  return false
end

--- One empty range inside each top-level `use` (at its path), plus the whole
--- buffer for the "remove all unused imports" fix.
local function organize_ranges(buf)
  local out = {}
  local last = vim.api.nvim_buf_line_count(buf) - 1
  out[1] = { start = { 0, 0 }, ["end"] = { last, #(vim.api.nvim_buf_get_lines(buf, last, last + 1, false)[1] or "") } }
  local root = ts_root(buf)
  if not root then
    return out
  end
  for node in root:iter_children() do
    if node:type() == "use_declaration" then
      local arg = node:field("argument")[1] or node
      local r, c = arg:range()
      out[#out + 1] = { start = { r, c }, ["end"] = { r, c }, text = node_text(node, buf) }
    end
  end
  return out
end

--- Merge / normalize / remove unused imports with rust-analyzer's assists, in ONE undo
--- step. Asynchronous (it can take a while on a cold server, the editor stays usable);
--- the result is reported with a notification and as cb(applied) when given:
--- M.organize(buf?, cb?) or M.organize(cb).
function M.organize(buf, cb)
  if type(buf) == "function" then
    buf, cb = nil, buf
  end
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  cb = cb or function() end
  if not vim.bo[buf].modifiable then
    notify("buffer is not modifiable", vim.log.levels.WARN)
    return cb(0)
  end
  if #ca.clients(buf) == 0 then
    notify("rust-analyzer is not attached", vim.log.levels.WARN)
    return cb(0)
  end
  local applied, skipped, settled, rounds, finished = 0, {}, false, 0, false
  local function finish(msg, level)
    if finished then
      return
    end
    finished = true
    notify(msg or (applied > 0 and ("organized imports (%d change%s)"):format(applied, applied == 1 and "" or "s") or "imports already organized"), level)
    cb(applied)
  end
  local max_tries = math.max(1, math.ceil(8000 / math.max(M.config.retry_ms, 1)))
  local ask, round

  -- one request for a range; "content modified" is retried up to ~8 s
  function ask(r, tries, k)
    if not vim.api.nvim_buf_is_valid(buf) then
      return finish("buffer is gone", vim.log.levels.WARN)
    end
    local only = { "quickfix", "refactor.rewrite", "source.organizeImports" }
    ca.request(buf, r, { diagnostics = vim.diagnostic.get(buf, { lnum = r.start[1] }), only = only }, function(list, errs)
      if busy(errs) and tries < max_tries then
        return vim.defer_fn(function()
          ask(r, tries + 1, k)
        end, M.config.retry_ms)
      end
      k(list or {})
    end)
  end

  function round()
    rounds = rounds + 1
    if rounds > M.config.organize_rounds or not vim.api.nvim_buf_is_valid(buf) then
      return finish()
    end
    local ranges = organize_ranges(buf)
    local function try_range(i)
      if i > #ranges then
        -- rust-analyzer may still be re-analysing after our last edit: look once more
        -- before concluding that nothing is left
        if settled then
          return finish()
        end
        settled = true
        return vim.defer_fn(round, 800)
      end
      local r = ranges[i]
      ask(r, 0, function(list)
        local matches = vim.tbl_filter(organize_match, list)
        local function try_action(j)
          local a = matches[j]
          if not a then
            return try_range(i + 1)
          end
          local key = tostring(a.title) .. "\0" .. (r.text or "")
          if skipped[key] then
            return try_action(j + 1)
          end
          local before = vim.api.nvim_buf_get_changedtick(buf)
          ca.apply_async(a, function(ok)
            if not ok or vim.api.nvim_buf_get_changedtick(buf) == before then
              skipped[key] = true
              return try_action(j + 1)
            end
            applied = applied + 1
            settled = false
            round() -- the ranges moved: look again from the top
          end, { join = applied > 0 })
        end
        try_action(1)
      end)
    end
    try_range(1)
  end

  round()
end

-- ------------------------------------------------------------- triggers

local dirty = {} -- buf -> { first, last } rows changed since the last scan
local timers = {} -- buf -> uv timer
local tracked = {}
local seen_seq = {} -- buf -> highest undo seq seen (an undo/redo is no new change)
local running = {}

local function mark_dirty(buf, first, last)
  local d = dirty[buf]
  if d then
    d[1], d[2] = math.min(d[1], first), math.max(d[2], last)
  else
    dirty[buf] = { first, last }
  end
end

local function track(buf)
  if tracked[buf] or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  tracked[buf] = true
  seen_seq[buf] = undo_seq(buf)
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, _, new_last)
      mark_dirty(b, first, math.max(first, new_last - 1))
    end,
    on_detach = function(_, b)
      tracked[b], dirty[b], seen_seq[b] = nil, nil, nil
    end,
  })
end

local function eligible(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == "rust" and vim.bo[buf].buftype == "" and M.mode() ~= "off"
end

--- Scan the rows changed since the last scan, after the debounce.
function M.trigger(buf)
  if not eligible(buf) then
    return
  end
  track(buf)
  local t = timers[buf]
  if not t then
    t = assert(vim.uv.new_timer())
    timers[buf] = t
  end
  t:stop()
  t:start(
    M.config.debounce,
    0,
    vim.schedule_wrap(function()
      local d = dirty[buf]
      if not d or not eligible(buf) then
        return
      end
      if running[buf] then
        return M.trigger(buf)
      end
      dirty[buf] = nil
      running[buf] = true
      local ok, err = pcall(M.run, buf, d[1], d[2], {
        done = function()
          running[buf] = nil
        end,
      })
      if not ok then
        running[buf] = nil
        notify("import scan failed: " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  )
end

local paste_wrapped = false
local function wrap_paste()
  if paste_wrapped then
    return
  end
  paste_wrapped = true
  local orig = vim.paste
  -- vim.paste is what bracketed paste (the terminal clipboard) and nvim_paste
  -- call; `p` does not, TextChanged below covers that
  vim.paste = function(lines, phase)
    local ret = orig(lines, phase)
    if phase == -1 or phase == 3 then
      local buf = vim.api.nvim_get_current_buf()
      if eligible(buf) then
        M.trigger(buf)
      end
    end
    return ret
  end
end

local function undo_guard(buf)
  -- an undo of an import must not re-import the name
  local seq = undo_seq(buf)
  local li = last_import[buf]
  if li and seq < li.seq then
    local file = vim.api.nvim_buf_get_name(buf)
    local root = root_of(file)
    dismissed[dkey(root, li.name, "*")] = true
    last_import[buf] = nil
  end
  local is_new = seq > (seen_seq[buf] or 0)
  seen_seq[buf] = math.max(seen_seq[buf] or 0, seq)
  return is_new
end

-- ---------------------------------------------------------------- setup

M.default_keymaps = { import = "<leader>rI", organize = "<leader>rO" }

local keymaps = false -- false | true | { import = lhs|false, organize = lhs|false }

local function map_buffer(buf)
  if not keymaps or vim.bo[buf].filetype ~= "rust" then
    return
  end
  local keys = keymaps == true and M.default_keymaps or keymaps
  local function map(lhs, rhs, desc)
    if type(lhs) == "string" then
      vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc, silent = true })
    end
  end
  map(keys.import, function()
    M.import_name()
  end, "Import name (ranked)")
  map(keys.organize, function()
    M.organize()
  end, "Organize imports")
end

local function define_commands()
  vim.api.nvim_create_user_command("ImportName", function(a)
    M.import_name(a.args)
  end, { nargs = "?", desc = "Import a name, candidates ranked (remembered per project)" })
  vim.api.nvim_create_user_command("ImportForget", function(a)
    local file = vim.api.nvim_buf_get_name(0)
    local root = root_of(file)
    if not root then
      return notify("not in a cargo workspace", vim.log.levels.WARN)
    end
    local n = M.forget(root, a.args ~= "" and a.args or nil)
    for k in pairs(dismissed) do
      if vim.startswith(k, root .. "\0") then
        dismissed[k] = nil
      end
    end
    notify(("forgot %d remembered import choice%s"):format(n, n == 1 and "" or "s"))
  end, { nargs = "?", desc = "Forget the remembered import choices of this project" })
  vim.api.nvim_create_user_command("ImportOrganize", function()
    M.organize()
  end, { desc = "Merge, normalize and remove unused imports (one undo step)" })
end

--- opts: { commands = true, keymaps = false, mode = "ask" } (see xyno_imports.setup).
function M.setup(opts)
  opts = opts or {}
  keymaps = opts.keymaps or false
  if opts.mode == "ask" or opts.mode == "single" or opts.mode == "off" then
    M.default_mode = opts.mode
  end
  local group = vim.api.nvim_create_augroup("xyno_imports", { clear = true })
  if opts.commands ~= false then
    define_commands()
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "rust",
    callback = function(ev)
      track(ev.buf)
      map_buffer(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function(ev)
      if eligible(ev.buf) then
        undo_guard(ev.buf)
        M.trigger(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local f = vim.api.nvim_buf_get_name(ev.buf)
      if f:match("%.rs$") then
        M.invalidate_uses()
      end
      if eligible(ev.buf) then
        M.trigger(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TextChanged", {
    group = group,
    callback = function(ev)
      if not eligible(ev.buf) then
        return
      end
      local new = undo_guard(ev.buf)
      local d = dirty[ev.buf]
      -- a multi-line change in normal mode is a put (p, P, :put), not a keystroke
      if new and d and d[2] > d[1] then
        M.trigger(ev.buf)
      end
    end,
  })
  wrap_paste()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "rust" then
      track(b)
      map_buffer(b)
    end
  end
end

return M
