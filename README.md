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
| `:NDSHDemo` | Play a scripted session through the real rendering path |

Layout adapts: with a single empty window the panel takes the whole tab (like
a full-screen TUI session); with code buffers open it docks right by default
(`layout = "right" | "bottom" | "float"`).

The panel is ordinary windows, so `<C-w>h/j/k/l` navigation and resizing are
native. Chat buffer locals: `q` closes, `i` jumps to input, `<Tab>` toggles
tool-result folds. Input: `<C-CR>` (terminals with extended keys) or `<C-s>`
sends, `<CR>` is a newline; in normal mode `<CR>` also sends.

## Test

```sh
nvim --headless -u NONE --cmd "set rtp+=." -l tests/smoke.lua
```
