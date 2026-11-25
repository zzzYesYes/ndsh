# ndsh

Neovim chat UI for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh).

`ndsh` spawns `dsh --profile sdk` and drives it over the SDK's
newline-delimited JSON-RPC protocol, rendering the session in native Neovim
buffers. Approvals and user questions are answered through `vim.ui`.

Status: milestone 2 done — panel frame plus a live SDK backend verified
against a scripted fixture runtime and a real `dsh` process.

## Install

With lazy.nvim:

```lua
{
  "zzzYesYes/ndsh",
  dependencies = { "nvim-telescope/telescope.nvim" }, -- optional, better session picker
  opts = {},
}
```

On first run with no `dsh` available, ndsh offers to bootstrap a managed
runtime itself: a pinned Node.js plus `@deepseek-ai/dsh` downloaded into
`stdpath("data")/ndsh/bootstrap` (needs only `curl`, `tar`, and
`sha256sum`; see `:NDSHInstallRuntime`). No manual installs required.

For development, point at a local checkout instead:

```lua
{ dir = "~/workspace/ndsh", opts = {} }
```

or manually:

```vim
set runtimepath+=~/workspace/ndsh
```

## Usage

Full key reference lives in the vim help: `:helptags doc` then `:help ndsh`
(it documents the stable panel-local keys; leader mappings are user config
and intentionally not pinned down there).

| Command | Action |
|---|---|
| `:NDSHToggle` | Toggle the panel (default map: `<leader>ant`) |
| `:NDSHNew [name]` | New session in the panel (`<leader>ann`) |
| `:NDSHResume` | Resume the most recently active session (`<leader>anr`) |
| `:NDSHSessions` | Session navigator (`<leader>ans`, telescope or `vim.ui`) |
| `:NDSHMessages` | Scan transcript messages and jump to one (`<leader>anm`, or `s` in the chat pane) |
| `:NDSHRename [name]` | Rename the current session (or `/rename <name>` in the input) |
| `:NDSHDelete` | Delete the current session (with confirmation) |
| `:NDSHOpen` / `:NDSHClose` | Open / close explicitly |
| `:NDSHStop` / `:NDSHRestart` | Stop / restart the runtime |
| `:NDSHInstallRuntime` | Install the managed runtime (pinned Node.js + `@deepseek-ai/dsh`) |
| `:NDSHConnect` | Connect a provider (stores credentials; pick from the live model catalog) |
| `:NDSHModel` | Select the active model (telescope picker; persists; restarts the runtime). Includes an "other model…" entry per connected provider for any model name without re-entering credentials |
| `:NDSHLog` | Show the captured runtime stderr log |
| `:NDSHDemo` | Play a scripted session through the real rendering path |

## Multi-session

One runtime multiplexes any number of conversations. The right-docked panel
shows one session at a time; `:NDSHNew` and the navigator swap its contents,
and each session keeps its own transcript, status, and wire session in the
background. The message pane's winbar shows the session name (with an
unread ● when activity arrives while hidden); the input pane's winbar keeps
status, model, working directory, and context usage. Closing the panel
detaches the session — transcripts persist and `<leader>ans` brings it back.
All sessions share the runtime's provider/model (an SDK limitation; see
docs/upstream-sdk-plan.md). `/rename <name>` in the input renames the
current session locally; other slash commands pass through to the runtime.

## Persistence and resume

The registry persists to `sessions.json` beside the store, so sessions
survive nvim restarts (`persist_sessions = true` by default), and each
session's rendered transcript is saved to `transcripts/<id>.md` beside it
(on exit and at every turn end). Restored sessions appear in the navigator
as detached entries; `<leader>anr` (`:NDSHResume`) jumps straight back into
the most recently active one. Activating a restored session reloads its
transcript and calls `session/resume` on the wire — the agent continues
with its full context (no history read on the wire yet; see
docs/upstream-sdk-plan.md). Wire sessions are stored per working directory
by dsh, so a session restored from a different cwd starts fresh (its
transcript stays) with a notice, as does one whose wire session is gone.

`:NDSHDelete` removes the active session after confirmation — registry,
transcript buffers, and store record. The wire session keeps running in
the runtime until its next restart; the SDK has no session/close yet.

Layout adapts: with no file buffer up (empty window, dashboard, scratch) the
panel takes the whole tab like a full-screen TUI session; with code buffers
open it docks right by default (`layout = "right" | "bottom" | "float"`).
When a takeover panel is the only pane left, closing restores what was
there: the replaced content (a dashboard or any buffer, reopened if it
self-wiped), or — from an empty scratch — Neovim exits like `:q` on the
last file window (`restore = "quit"`, the default); alternatives are
`"dashboard"`, `"scratch"`, or a `fun(win)` hook.

The panel is ordinary windows, so `<C-w>h/j/k/l` navigation and resizing are
native. The chat (input) pane's winbar carries all chrome: agent status and
active model on the left; right-aligned the plan/build mode (colored,
following `/plan` toggles via `plan/mode` events, persisted per session),
session working directory, and live context usage
(`plan · ~/proj · 12k/128k · 10%`), fed by `request/context` capacity
events and per-message token usage. The message pane stays decoration-free
and both panes keep normal vim statuslines. Chat buffer locals: `q` closes, `i`
jumps to input, `<Tab>` toggles tool-result folds, `J`/`K` jump between message
blocks (tool outputs unfold), `s` opens the message scanner. Input: `<C-s>` sends
(insert and normal mode), `<CR>` is a plain newline in insert mode and sends
in normal mode. If your global "tab" keys operate on buffers (e.g. barbar),
set `keys.tabnext`/`keys.tabprev` so they switch real tabpages inside the
panel.

## Runtime connection

The runtime connects when the panel opens (`dsh.auto_connect`). `dsh.cmd`
sets the argv explicitly; otherwise an installed `dsh` is used, then the
managed bootstrap runtime, then a `~/workspace/deepseek-harness` source
checkout via pnpm. With nothing resolvable, first use offers to download a
pinned Node.js (`dsh.node_version`) and `@deepseek-ai/dsh` (`dsh.version`)
into `stdpath("data")/ndsh/bootstrap`; `:NDSHInstallRuntime` repeats or
repairs that install. Provider and
model default to `deepseek-official` / `deepseek-v4-flash` and are
configurable. Credentials: run `:NDSHConnect` to pick a provider, enter its
API key, then choose a model from the provider's live catalog (fetched over
HTTP when the provider supports it; free text otherwise). They are stored
owner-only at
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
nvim --headless -u NONE --cmd "set rtp+=." -l tests/restart.lua     # persistence across two processes
nvim --headless -u NONE --cmd "set rtp+=." -l tests/integration.lua # full stack vs tests/fixtures/fake_dsh.py
```

Dependencies are inventoried in [docs/dependencies.md](docs/dependencies.md)
and updated in the same commit that introduces one.
