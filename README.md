# ndsh

Neovim chat UI for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh).

`ndsh` is a Lua plugin that will spawn `dsh --profile sdk` and drive it over the
SDK's newline-delimited JSON-RPC protocol, rendering the session in native
Neovim buffers.

Status: milestone 1 (UI frame) done — panel layout, rendering pipeline, and a
scripted demo. The SDK job/protocol layer is milestone 2.

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
| `:NDSHOpen` / `:NDSHClose` | Open / close explicitly |
| `:NDSHOpen!` | Open as a full-screen tab (default map: `<leader>aO`) |
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

## Test

```sh
nvim --headless -u NONE --cmd "set rtp+=." -l tests/smoke.lua
```
