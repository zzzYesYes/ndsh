--- Chat message area: a readonly markdown buffer behind an append-only
--- writer API. Projection output and (later) live stream chunks both go
--- through these functions; nothing else edits the buffer.
local M = {}

local ICONS = { running = "⠋", ok = "✓", err = "✗" }

---Per-buffer writer state.
---@class NdsChatState
---@field empty boolean no content appended yet
---@field msg_open boolean a begin_message without end_message
---@field tools table<string, {line: integer, name: string, summary: string}>
local states = {}

local function state(buf)
  local s = states[buf]
  assert(s, "ndsh: unknown chat buffer")
  return s
end

local function with_modifiable(buf, fn)
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  local ok, err = pcall(fn)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  if not ok then
    error(err)
  end
end

---Append lines at the end of the buffer, replacing the initial empty line
---on the first write.
local function append_lines(buf, lines)
  if #lines == 0 then
    return
  end
  local s = state(buf)
  with_modifiable(buf, function()
    if s.empty then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      s.empty = false
    else
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
    end
  end)
end

local function highlight_line(buf, lnum, group)
  vim.api.nvim_buf_set_extmark(buf, M._ns, lnum, 0, {
    line_hl_group = group,
  })
end

local function find_window(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return win
    end
  end
  return nil
end

---Fold [first, last] (0-based, inclusive) closed. Requires the chat window's
---foldmethod=manual; silently skipped when the buffer is not displayed.
local function fold_range(buf, first, last)
  if last <= first then
    return
  end
  local win = find_window(buf)
  if not win then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd(("silent! %d,%dfold"):format(first + 1, last + 1))
  end)
end

---Create the chat buffer and its buffer-local conveniences.
---@param keys table|nil cfg.keys for optional tab navigation maps
---@param suffix string unique name suffix (conversation id)
---@return integer buf
function M.create(keys, suffix)
  M._ns = M._ns or vim.api.nvim_create_namespace("ndsh")
  vim.api.nvim_set_hl(0, "NDSHUserHeader", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "NDSHAssistantHeader", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NDSHToolRunning", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "NDSHToolOk", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "NDSHToolErr", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "NDSHThinking", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "NDSHModePlan", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "NDSHModeBuild", { link = "Comment", default = true })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  -- Own filetype so statusline plugins can be disabled for panel windows;
  -- markdown treesitter highlighting is attached explicitly (soft dep).
  vim.api.nvim_set_option_value("filetype", "ndsh", { buf = buf })
  -- Named (uniquely per conversation), so :edit in the pane cannot reuse
  -- this buffer for a file.
  vim.api.nvim_buf_set_name(buf, "ndsh://chat/" .. suffix)
  pcall(vim.treesitter.start, buf, "markdown")
  states[buf] = { empty = true, msg_open = false, tools = {} }

  vim.keymap.set("n", "q", function()
    require("ndsh").close()
  end, { buffer = buf, desc = "Close ndsh panel" })
  vim.keymap.set("n", "i", function()
    require("ndsh").focus_input()
  end, { buffer = buf, desc = "Jump to ndsh input" })
  vim.keymap.set("n", "<Tab>", "za", { buffer = buf, desc = "Toggle fold" })
  vim.keymap.set("n", "s", function()
    require("ndsh").messages()
  end, { buffer = buf, desc = "Scan ndsh messages" })
  require("ndsh.ui.input")._map_tab_nav(buf, keys or {})
  return buf
end

---@param buf integer
---@param role "user"|"assistant"
function M.begin_message(buf, role)
  local s = state(buf)
  assert(not s.msg_open, "ndsh: nested begin_message")
  s.msg_open = true
  if role == "user" then
    local lnum = s.empty and 0 or vim.api.nvim_buf_line_count(buf)
    append_lines(buf, { "❯ You" })
    highlight_line(buf, lnum, "NDSHUserHeader")
  else
    local lnum = s.empty and 0 or vim.api.nvim_buf_line_count(buf)
    append_lines(buf, { "● ndsh" })
    highlight_line(buf, lnum, "NDSHAssistantHeader")
  end
end

---@param buf integer
---@param text string
function M.append(buf, text)
  assert(state(buf).msg_open, "ndsh: append outside message")
  append_lines(buf, vim.split(text, "\n", { plain = true }))
end

---@param buf integer
function M.end_message(buf)
  local s = state(buf)
  assert(s.msg_open, "ndsh: end_message without begin_message")
  s.msg_open = false
  append_lines(buf, { "" })
end

---Start a collapsible tool block: status line now, result under a fold later.
---@param buf integer
---@param id string
---@param name string
---@param summary string
function M.tool_begin(buf, id, name, summary)
  local s = state(buf)
  local lnum = s.empty and 0 or vim.api.nvim_buf_line_count(buf)
  local label = ("%s %s · %s"):format(ICONS.running, name, summary)
  append_lines(buf, { label })
  s.tools[id] = { line = lnum, name = name, summary = summary }
  highlight_line(buf, lnum, "NDSHToolRunning")
end

---Finish a tool block: update the status line and fold the result output.
---@param buf integer
---@param id string
---@param ok boolean
---@param output string
function M.tool_end(buf, id, ok, output)
  local s = state(buf)
  local rec = s.tools[id]
  if not rec then
    return
  end
  s.tools[id] = nil
  local icon = ok and ICONS.ok or ICONS.err
  with_modifiable(buf, function()
    vim.api.nvim_buf_set_lines(buf, rec.line, rec.line + 1, false, {
      ("%s %s · %s"):format(icon, rec.name, rec.summary),
    })
  end)
  highlight_line(buf, rec.line, ok and "NDSHToolOk" or "NDSHToolErr")
  if output == "" then
    return
  end
  local first = vim.api.nvim_buf_line_count(buf)
  local lines = {}
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    lines[#lines + 1] = "  │ " .. line
  end
  lines[#lines + 1] = ""
  append_lines(buf, lines)
  fold_range(buf, first, first + #lines - 2)
end

---Render a reasoning block: dimmed "thinking" header with the content
---folded closed by default, expanded inline with za/<Tab>.
---@param buf integer
---@param text string readable reasoning text
function M.reasoning(buf, text)
  local s = state(buf)
  local header_lnum = s.empty and 0 or vim.api.nvim_buf_line_count(buf)
  append_lines(buf, { "∴ thinking" })
  highlight_line(buf, header_lnum, "NDSHThinking")
  local first = vim.api.nvim_buf_line_count(buf)
  local lines = vim.split(text, "\n", { plain = true })
  lines[#lines + 1] = ""
  append_lines(buf, lines)
  for lnum = first, first + #lines - 2 do
    highlight_line(buf, lnum, "NDSHThinking")
  end
  -- The trailing separator line folds with the content so even a
  -- single-line reasoning collapses to just its header.
  fold_range(buf, first, first + #lines - 1)
end

---Render a dim one-line notice in the transcript (e.g. "session resumed").
---@param buf integer
---@param text string
function M.notice(buf, text)
  local s = state(buf)
  local lnum = s.empty and 0 or vim.api.nvim_buf_line_count(buf)
  append_lines(buf, { "─ " .. text .. " ─", "" })
  highlight_line(buf, lnum, "NDSHAssistantHeader")
end

---Restore a persisted transcript into an empty chat buffer (the registry
---restore path). Raw lines plus header/tool highlighting; writer state is
---marked non-empty so live events append after the restored content.
---@param buf integer
---@param lines string[]
function M.restore(buf, lines)
  local s = state(buf)
  if not s.empty then
    return
  end
  append_lines(buf, lines)
  for i, line in ipairs(lines) do
    local hl
    if line == "❯ You" then
      hl = "NDSHUserHeader"
    elseif line == "● ndsh" or line:match("^─ .+ ─$") then
      hl = "NDSHAssistantHeader"
    elseif line == "∴ thinking" then
      hl = "NDSHThinking"
    else
      -- Tool icons are 3-byte UTF-8; byte slice, not a pattern class.
      local icon = line:sub(1, 3)
      if icon == "✓" then
        hl = "NDSHToolOk"
      elseif icon == "✗" then
        hl = "NDSHToolErr"
      elseif icon == "⠋" then
        hl = "NDSHToolRunning"
      end
    end
    if hl then
      highlight_line(buf, i - 1, hl)
    end
  end
end

---Render an error block in the transcript (e.g. a failed turn's reason).
---@param buf integer
---@param text string
function M.error(buf, text)
  local s = state(buf)
  local first = s.empty and 0 or vim.api.nvim_buf_line_count(buf)
  local lines = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    lines[#lines + 1] = "✗ " .. line
  end
  lines[#lines + 1] = ""
  append_lines(buf, lines)
  for lnum = first, first + #lines - 2 do
    highlight_line(buf, lnum, "NDSHToolErr")
  end
end

return M
