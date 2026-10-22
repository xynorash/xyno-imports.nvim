# xyno-imports.nvim

Imports without the menu for Rust in Neovim: auto-import of unresolved names, ranked disambiguation with a per-project memory, and organize imports, on top of rust-analyzer code actions.

I use this in my own Rust setup, [xynovim](https://github.com/xynorash/xynovim), and pulled it out as a standalone plugin.

The auto-import flow and organize imports are inspired by the import handling of the JetBrains IDEs. I still use JetBrains tools; this plugin is my own independent project and is not affiliated with JetBrains.

## Why

rust-analyzer offers `Import X` as a code action, but you have to stop, open the menu and pick. When there is exactly one candidate that is a wasted round trip, and when there are several the list is in server order, not in the order your project would choose. This does the single case for you (or asks for one key), ranks the several-candidates case by what the project already does, and remembers the choice.

## Requirements

- Neovim 0.12+
- [xyno-rust.nvim](https://github.com/xynorash/xyno-rust.nvim) (modules `crate_meta`, `code_actions`, `fsutil`). It is checked in `setup()`: without it you get one error line and the plugin does not start.
- rust-analyzer started through `vim.lsp` (I use [rustaceanvim](https://github.com/mrcjkb/rustaceanvim))
- `cargo` in `$PATH` (workspace and dependency metadata)
- the tree-sitter `rust` parser for the scan of unresolved names

## Install (lazy.nvim)

```lua
{
  "xynorash/xyno-imports.nvim",
  dependencies = { "xynorash/xyno-rust.nvim" },
  ft = "rust",
  cmd = { "ImportName", "ImportForget", "ImportOrganize" },
  opts = {},
  keys = {
    { "<leader>rI", "<cmd>ImportName<cr>", ft = "rust", desc = "Import name (ranked)" },
    { "<leader>rO", "<cmd>ImportOrganize<cr>", ft = "rust", desc = "Organize imports" },
  },
}
```

The auto-import autocommands start with `setup()`, so load the plugin with `ft = "rust"` (as above) or `event = "VeryLazy"`, not only on the commands, if you want names imported while you type.

## Options

`require("xyno_imports").setup(opts)`; the defaults:

```lua
{
  commands = true, -- :ImportName :ImportForget :ImportOrganize
  keymaps = false, -- false | true | { import = lhs|false, organize = lhs|false }
  mode = "ask",    -- "ask" | "single" | "off"
  config = {},     -- engine tuning, see below
}
```

No global keymap is set by default. `keymaps = true` maps `<leader>rI` (import name) and `<leader>rO` (organize), buffer-local in Rust files; a table maps only what you list, to the keys you choose.

`mode` decides what happens to a name that resolves to nothing, after `InsertLeave`, a save or a paste:

- `"ask"` (default, never silent): exactly one `Import X` (or a choice remembered for this project) prompts for one key; `<CR>` or `y` accepts, anything else dismisses it for the session.
- `"single"`: that one import is applied as one undo step, with a one-line note.
- `"off"`: nothing is scanned.

Several candidates are never guessed at: use `:ImportName`. `vim.g.xyno_auto_import` set to one of the three values overrides `mode` at runtime.

`config` overrides engine values: `debounce = 600` (ms between the last change and the scan), `max_names = 8` (names looked at per scan), `retries = 5` and `retry_ms = 400` (retries of a code action request that answered "content modified"), `organize_rounds = 30`, `max_lines = 20000` (the scan reads the whole buffer per edit and is skipped above this), `source_wait_ms = 4000` (how long `resolve()` waits for asynchronous sources).

## Commands

| Command | What it does |
| --- | --- |
| `:ImportName [name]` | List the candidates for the name (default: under the cursor), best first with the reasons, and import the chosen one. The choice is remembered per project and wins from then on. |
| `:ImportForget [name]` | Forget the remembered choice for the name, or all choices of this project. |
| `:ImportOrganize` | rust-analyzer's merge, normalize and remove-unused import assists, applied in one undo step. |

## Lua API

`require("xyno_imports.engine")` has the pure parts and the flow: `mode()`, `score(cand, facts)`, `rank(cands, facts)`, `candidate(path)`, `decide`, `resolve(name, ctx)`, `import_name(name?)`, `organize()`, `trigger(buf)`, `remembered(root, name)`, `remember`, `forget(root, name?)`, `reload_memory()`, `register_source(fn)`, `config` and `weights`. `:help xyno-imports-api` lists the ones meant for other code.

`engine.resolve(name, ctx)` returns the ranked candidates of a name (`{ candidates = {...}, best = ... }`). `engine.register_source(fn)` adds candidates the language server does not know, for example a crate that is not a dependency yet; `fn(name, ctx)` returns `{ { path = "rand::Rng", crate = "rand", add_crate = true, apply = function(cb) ... cb(ok, err) end }, ... }`. Such candidates are ranked last and never applied automatically. It returns a function that unregisters the source.

## How it works

After `InsertLeave`, a save or a paste, the changed lines are scanned for names that resolve to nothing (diagnostics of rust-analyzer and the clippy tier, plus a tree-sitter scan), debounced. rust-analyzer is asked for the code actions at each one. Candidates are scored by what the project already does (the same `use` in this file, in sibling modules and in the crate), the context of the name (derive, error type, return type, trait position), the order of the dependencies, and a penalty for a crate that is not a dependency yet; the reasons are shown in the picker. The choices you make are stored per workspace root in `stdpath("state")/xyno-imports/imports.json`. An undo of an import is noticed, so the name does not come back by itself.

## Platforms

- Linux: tested by the specs in this repository (`nvim -l tests/run.lua`): the scoring, memory, scan and flow against a fake rust-analyzer client, plus cases against a real rust-analyzer on a small fixture crate where rust-analyzer, cargo and the registry crates are available (they skip with a printed reason otherwise).
- Windows: the Windows guards of the original code are kept, but I have no evidence for them from this repository. In xynovim's CI the Windows job passed overall (run 39673715062, import specs not skipped whole), while the live rust-analyzer flows of neighbouring specs failed or hung there as a known issue, so I do not claim the live part works on Windows.
- macOS: nothing tested here. In xynovim's CI one auto-import timing spec timed out on macOS (run 39647013043) and is skipped there as a known issue; the macOS runs were not stable, so I do not claim it works.

## Extracted from xynovim

This module comes from [xynovim](https://github.com/xynorash/xynovim), my Neovim configuration for Rust. The code is the same apart from the namespace (`config.*` became `xyno_imports.*` and `xyno_rust.*`), `setup()` taking options, the keys being opt-in (the original bound them itself), the mode also settable by option (the global is now `vim.g.xyno_auto_import`), and the state file and autocommand group carrying this plugin's name. The crates.io candidate source of xynovim (`Add crate X and import`) is not part of this plugin; `register_source` is the hook it used.

## Tests

```sh
nvim -l tests/run.lua    # specs, each file in its own headless nvim; needs xyno-rust.nvim in ../xyno-rust.nvim or XYNO_RUST_DIR
XYNO_LAZY=/path/to/lazy.nvim XYNO_RUST_DIR=/path/to/xyno-rust.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
```

## License

MIT, Copyright (c) 2026 Xynorash.
