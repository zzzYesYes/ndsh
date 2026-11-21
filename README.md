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
| `:NDSHToggle` | Toggle the panel (default map: `<leader>ao`) |
| `:NDSHOpen!` | Open as a full-screen tab (default map: `<leader>aO`) |
| `:NDSHOpen` / `:NDSHClose` | Open / close explicitly |
| `:NDSHStop` / `:NDSHRestart` | Stop / restart the runtime |
| `:NDSHLog` | Show the captured runtime stderr log |
| `:NDSHDemo` | Play a scripted session through the real rendering path |

Layout adapts: with no file buffer up (empty window, dashboard, scratch) the
panel takes the whole tab like a full-screen TUI session; with code buffers
open it docks right by default (`layout = "right" | "bottom" | "float"`).
`:NDSHOpen!` forces full-screen by opening a dedicated tab, leaving your
splits untouched; closing it tabs back out. When the takeover panel is the
only pane left, closing it exits Neovim like `:q` on the last file window
(`restore = "quit"`, the default); alternatives are `"dashboard"` (show your
dashboard plugin), `"scratch"` (empty buffer), or a `fun(win)` hook.

The panel is ordinary windows, so `<C-w>h/j/k/l` navigation and resizing are
native. Chat buffer locals: `q` closes, `i` jumps to input, `<Tab>` toggles
tool-result folds. Input: `<C-s>` sends (insert and normal mode), `<CR>` is a
plain newline in insert mode and sends in normal mode. If your global "tab"
keys operate on buffers (e.g. barbar), set `keys.tabnext`/`keys.tabprev` so
they switch real tabpages inside the panel.

## Runtime connection

The runtime connects when the panel opens (`dsh.auto_connect`). `dsh.cmd`
sets the argv explicitly; otherwise an installed `dsh` is used, falling back
to a `~/workspace/deepseek-harness` source checkout via pnpm. Provider and
model default to `deepseek-official` / `deepseek-v4-flash` and are
configurable. The runtime needs its provider credentials (e.g.
`DEEPSEEK_API_KEY` or `deepseek-harness/.env`) in the environment Neovim was
launched from.

## Test

```sh
nvim --headless -u NONE --cmd "set rtp+=." -l tests/unit.lua        # protocol/framing units
nvim --headless -u NONE --cmd "set rtp+=." -l tests/smoke.lua       # UI frame
nvim --headless -u NONE --cmd "set rtp+=." -l tests/integration.lua # full stack vs tests/fixtures/fake_dsh.py
```
