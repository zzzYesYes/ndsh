# Dependencies

Update this file in the same commit that introduces any dependency.
`tests/deps.lua` enforces the "no undeclared external modules" rule.

## Hard dependencies — none

ndsh runs on stock Neovim only (developed against 0.12). Everything the
panel uses is built-in: windows/tabpages, winbar, extmarks, manual folds,
jobstart channels, `vim.json`, `vim.ui`, autocmds. All test suites run
under `nvim -u NONE` to prove this stays true.

## External runtime dependencies

| Dependency | Purpose | Resolution |
|---|---|---|
| `dsh` executable | the agent runtime (`dsh --profile sdk`) | `dsh.cmd` config, else `$PATH`, else `~/workspace/deepseek-harness` via pnpm |
| node + pnpm | only for the source-checkout launch path | `~/.local/share/pnpm/bin/pnpm` fallback |

## Test-only dependencies

| Dependency | Purpose |
|---|---|
| `python3` | runs `tests/fixtures/fake_dsh.py` for `tests/integration.lua` |

## Soft integrations (optional, degrade gracefully)

| Plugin | Used for | Without it |
|---|---|---|
| nvim-treesitter (markdown parser) | assistant output highlighting | plain text |
| dressing.nvim / any `vim.ui` override | approvals, questions, pickers | builtin cmdline UI |
| startup.nvim / dashboard plugins | restore after takeover close | scratch buffer |
| lazy.nvim | install mechanism | plain runtimepath works |

## Deliberately avoided

| Plugin | Why |
|---|---|
| lualine | disabled for panel filetypes (`ndsh`, `ndshinput`) via the user's lualine config, so our statuslines stay blank; panel chrome uses winbar, which lualine never touches |

## Rules

- No new required Neovim plugin without a documented reason here and a
  degradation path.
- Optional integrations must fail soft ("less pretty", never "broken").
