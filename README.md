# ndsh

Neovim chat UI for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh).

`ndsh` spawns `dsh --profile sdk` and drives it over the SDK's
newline-delimited JSON-RPC protocol, rendering the session in native Neovim
windows: a multi-session agent panel with persisted, resumable
conversations — no external UI dependencies.

## Features

- **Chat panel** docked right/bottom/float, or full-tab takeover on empty
  windows — markdown transcript, folded tool results and reasoning, native
  window navigation
- **Multi-session**: one runtime, any number of conversations; telescope
  navigator with transcript-tail preview and `<C-d>` deletion
- **Sessions survive restarts**: registry + transcripts persist; wire
  sessions resume on the runtime with full context
- **Model & reasoning-effort switching**: live provider model discovery,
  per-session resumes keep context across runtime restarts
- **Plan-mode and effort indicators** in the winbar, with live context usage
- **Transcript navigation**: message scanner (telescope), `J`/`K` block jumps
- **Approvals & user questions** through `vim.ui`, with tool arguments
- **Zero-install runtime**: bootstraps a pinned Node.js + `@deepseek-ai/dsh`
  on first use (`:NDSHInstallRuntime`)

The full inventory with every key and command: [docs/features.md](docs/features.md).

## Requirements

- Neovim 0.12+
- `curl`, `tar`, `sha256sum` (runtime bootstrap only)
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
  (pickers; `vim.ui.select` fallback), nvim-treesitter markdown parser
  (assistant highlighting)

## Install

With lazy.nvim:

```lua
{
  "zzzYesYes/ndsh",
  dependencies = { "nvim-telescope/telescope.nvim" }, -- optional, better pickers
  opts = {},
}
```

On first run with no `dsh` available, ndsh offers to bootstrap a managed
runtime itself: a pinned Node.js plus `@deepseek-ai/dsh` downloaded into
`stdpath("data")/ndsh/bootstrap`. No manual installs required.

ndsh defines no keybindings on its own — bind the actions you want via
`keys`:

```lua
opts = {
  keys = {
    toggle = "<leader>ant",      -- open/close the panel
    sessions = "<leader>ans",    -- session navigator (<C-d> deletes an entry)
    messages = "<leader>anm",    -- scan the transcript
    resume = "<leader>anr",      -- jump back into the last session
    model = "<leader>anM",       -- model selector
    new_session = "<leader>ann", -- or use /new in the input
  },
}
```

## Quick start

1. `:NDSHConnect` — pick a provider, enter its API key, choose a model from
   the live catalog. Stored owner-only at `stdpath("data")/ndsh/credentials.json`.
2. Open the panel (your `toggle` key) and chat. `/new [name]` starts another
   session; `/rename`, `/compact`, `/goal`, `/plan` work in the input.
3. Restart Neovim freely: sessions and transcripts come back; resume the last
   one with your `resume` key.

## Commands

| Command | Action |
|---|---|
| `:NDSHToggle` / `:NDSHOpen` / `:NDSHClose` | Panel visibility |
| `:NDSHNew [name]` | New session (or `/new [name]` in the input) |
| `:NDSHResume` | Resume the most recently active session |
| `:NDSHSessions` | Session navigator (`<C-d>` deletes an entry) |
| `:NDSHMessages` | Scan transcript messages and jump to one |
| `:NDSHRename [name]` | Rename the current session (or `/rename <name>`) |
| `:NDSHDelete` | Delete the current session (with confirmation) |
| `:NDSHConnect` | Connect a provider (credentials + live model catalog) |
| `:NDSHModel` | Switch model (persists; sessions resume on the new route) |
| `:NDSHReasoning` | Switch reasoning effort (off/low/high/max or auto) |
| `:NDSHStop` / `:NDSHRestart` | Stop / restart the runtime |
| `:NDSHInstallRuntime` | Install/repair the managed runtime |
| `:NDSHLog` | Show the captured runtime stderr log |
| `:NDSHDemo` | Play a scripted session through the real rendering path |

Full key reference lives in the vim help: `:helptags doc` then `:help ndsh`.

## Development

```sh
nvim --headless -u NONE -l tests/deps.lua                                     # dependency tripwire
nvim --headless -u NONE --cmd "set rtp+=." -l tests/unit.lua        # protocol/framing units
nvim --headless -u NONE --cmd "set rtp+=." -l tests/smoke.lua       # UI frame
nvim --headless -u NONE --cmd "set rtp+=." -l tests/features.lua    # connect/model flows
nvim --headless -u NONE --cmd "set rtp+=." -l tests/restart.lua     # persistence across two processes
nvim --headless -u NONE --cmd "set rtp+=." -l tests/integration.lua # full stack vs tests/fixtures/fake_dsh.py
```

CI runs all six suites headlessly on every push. Dependencies are
inventoried in [docs/dependencies.md](docs/dependencies.md) and updated in
the same commit that introduces one.

## License

MIT
