# ndsh

Neovim chat UI for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh).

`ndsh` spawns `dsh --profile sdk` and drives it over the SDK's
newline-delimited JSON-RPC protocol, rendering the session in native Neovim
buffers. Approvals and user questions are answered through `vim.ui`.

Status: milestone 2 done — panel frame plus a live SDK backend verified
against a scripted fixture runtime and a real `dsh` process.

## Install (development)

Add this directory to your `runtimepath`, e.g. with lazy.nvim:

```lua
{ dir = "~/workspace/ndsh", opts = {} }
```

or manually:

```vim
set runtimepath+=~/workspace/ndsh
```

## Usage

| Command | Action |
|---|---|
| `:NDSHToggle` | Toggle the panel (default map: `<leader>anr`) |
| `:NDSHOpen!` | Open as a full-screen tab (default map: `<leader>anf`) |
| `:NDSHNew [name]` | New session in its own tab (`<leader>ann`) |
| `:NDSHSessions` | Session navigator (`<leader>ans`, telescope or `vim.ui`) |
| `:NDSHRename [name]` | Rename the current session (or `/rename <name>` in the input) |
| `:NDSHOpen` / `:NDSHClose` | Open / close explicitly |
| `:NDSHStop` / `:NDSHRestart` | Stop / restart the runtime |
| `:NDSHConnect` | Connect a provider (stores credentials, switches model) |
| `:NDSHModel` | Select the active model (persists; restarts the runtime) |
| `:NDSHLog` | Show the captured runtime stderr log |
| `:NDSHDemo` | Play a scripted session through the real rendering path |

## Multi-session

One runtime multiplexes any number of conversations. Each session is a
full-tab panel with its own transcript, status, and wire session; switching
is native `gt`/`gT`. The message pane's winbar shows the session name (with
an unread ● when activity arrives while hidden); the input pane's winbar
keeps status, model, working directory, and context usage. Closing a
session's tab detaches it — transcripts persist and `<leader>ans` brings it
back. All sessions share the runtime's provider/model (an SDK limitation;
see docs/upstream-sdk-plan.md). `/rename <name>` in the input renames the
current session locally; other slash commands pass through to the runtime.

Layout adapts: with no file buffer up (empty window, dashboard, scratch) the
panel takes the whole tab like a full-screen TUI session; with code buffers
open it docks right by default (`layout = "right" | "bottom" | "float"`).
`:NDSHOpen!` forces full-screen by opening a dedicated tab, leaving your
splits untouched; closing it tabs back out. When a takeover panel is the
only pane left, closing restores what was there: the replaced content (a
dashboard or any buffer, reopened if it self-wiped), or — from an empty
scratch — Neovim exits like `:q` on the last file window (`restore =
"quit"`, the default); alternatives are `"dashboard"`, `"scratch"`, or a
`fun(win)` hook.

The panel is ordinary windows, so `<C-w>h/j/k/l` navigation and resizing are
native. The chat (input) pane's winbar carries all chrome: agent status and
active model on the left, session working directory and live context usage
right-aligned (`~/proj · 12k/128k · 10%`), fed by `request/context` capacity
events and per-message token usage. The message pane stays decoration-free
and both panes keep normal vim statuslines. Chat buffer locals: `q` closes, `i`
jumps to input, `<Tab>` toggles tool-result folds. Input: `<C-s>` sends
(insert and normal mode), `<CR>` is a plain newline in insert mode and sends
in normal mode. If your global "tab" keys operate on buffers (e.g. barbar),
set `keys.tabnext`/`keys.tabprev` so they switch real tabpages inside the
panel.

## Runtime connection

The runtime connects when the panel opens (`dsh.auto_connect`). `dsh.cmd`
sets the argv explicitly; otherwise an installed `dsh` is used, falling back
to a `~/workspace/deepseek-harness` source checkout via pnpm. Provider and
model default to `deepseek-official` / `deepseek-v4-flash` and are
configurable. Credentials: run `:NDSHConnect` to pick a provider, enter its
API key and model — they are stored owner-only at
`stdpath("data")/ndsh/credentials.json` and injected into the runtime's
environment at spawn (like `opencode auth login`). Environment variables
already present when Neovim launches (e.g. `DEEPSEEK_API_KEY`) also work
without connecting. `:NDSHModel` switches between the configured routes and
any connected providers; the selection persists across restarts. Because the
SDK fixes provider/model at `initialize`, switching restarts the runtime and
begins a new session. Extra routes can be declared via `dsh.models`, e.g.
`{ provider = "anthropic", model = "claude-opus-4-1", label = "Claude Opus" }`.

## Test

```sh
nvim --headless -u NONE -l tests/deps.lua                                     # dependency tripwire
nvim --headless -u NONE --cmd "set rtp+=." -l tests/unit.lua        # protocol/framing units
nvim --headless -u NONE --cmd "set rtp+=." -l tests/smoke.lua       # UI frame
nvim --headless -u NONE --cmd "set rtp+=." -l tests/features.lua    # connect/model flows
nvim --headless -u NONE --cmd "set rtp+=." -l tests/integration.lua # full stack vs tests/fixtures/fake_dsh.py
```

Dependencies are inventoried in [docs/dependencies.md](docs/dependencies.md)
and updated in the same commit that introduces one.
