--- ndsh plugin entry: setup, panel state, and the event-application path
--- shared by the dev harness and (milestone 2) the live SDK protocol.
local config = require("ndsh.config")
local layout = require("ndsh.ui.layout")
local chat = require("ndsh.ui.chat")
local input = require("ndsh.ui.input")
local projection = require("ndsh.projection")

local M = {}

local state = {
  cfg = nil, ---@type table|nil
  chat_buf = nil, ---@type integer|nil
  input_buf = nil, ---@type integer|nil
  chat_win = nil, ---@type integer|nil
  input_win = nil, ---@type integer|nil
  takeover = false,
  full_tab = false,
  status = "idle",
}

local function ensure_setup()
  if not state.cfg then
    M.setup({})
  end
end

local function ensure_buffers()
  if not (state.chat_buf and vim.api.nvim_buf_is_valid(state.chat_buf)) then
    state.chat_buf = chat.create()
  end
  if not (state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf)) then
    state.input_buf = input.create(state.cfg, function(text)
      M._on_send(text)
    end)
  end
end

---@param opts table|nil
function M.setup(opts)
  state.cfg = config.resolve(opts)
  local toggle = state.cfg.keys.toggle
  if toggle then
    vim.keymap.set("n", toggle, function()
      M.toggle()
    end, { desc = "Toggle ndsh panel" })
  end
end

---@return boolean
function M.is_open()
  return state.chat_win ~= nil and vim.api.nvim_win_is_valid(state.chat_win)
end

---@param opts { full: boolean|nil }|nil full: open as a full tab even with
---code buffers open (implemented as a new tabpage; closing restores it).
function M.open(opts)
  opts = opts or {}
  ensure_setup()
  ensure_buffers()
  if M.is_open() then
    if opts.full then
      M.close()
    elseif vim.api.nvim_win_get_tabpage(state.chat_win) ~= vim.api.nvim_get_current_tabpage() then
      -- Open in another tab: move the panel here instead of duplicating it.
      layout.hide({ chat = state.chat_win, input = state.input_win, takeover = state.takeover })
    else
      return
    end
  end
  local full_tab = false
  if opts.full and not layout.is_takeover_tab() then
    -- Full-screen over existing content would destroy windows; a fresh tab
    -- gives the same area non-destructively and tabs back out on close.
    vim.cmd("tabnew")
    full_tab = true
  end
  local wins = layout.show(state.cfg, state.chat_buf, state.input_buf)
  state.chat_win = wins.chat
  state.input_win = wins.input
  state.takeover = wins.takeover
  state.full_tab = full_tab and wins.takeover
  input.set_status(state.input_win, state.status)
end

function M.close()
  if not M.is_open() and not (state.input_win and vim.api.nvim_win_is_valid(state.input_win)) then
    return
  end
  if state.full_tab then
    -- The chat window is the tab's last window; close the whole tabpage.
    if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
      vim.api.nvim_win_hide(state.input_win)
    end
    pcall(vim.cmd, "tabclose")
  else
    layout.hide({ chat = state.chat_win, input = state.input_win, takeover = state.takeover })
  end
  state.chat_win = nil
  state.input_win = nil
  state.takeover = false
  state.full_tab = false
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.focus_input()
  if state.input_win and vim.api.nvim_win_is_valid(state.input_win) then
    vim.fn.win_gotoid(state.input_win)
    vim.cmd("startinsert")
  end
end

---Apply one projected writer operation.
---@param op table
local function apply_op(op)
  local buf = state.chat_buf
  if op.op == "begin_message" then
    chat.begin_message(buf, op.role)
  elseif op.op == "append" then
    chat.append(buf, op.text)
  elseif op.op == "end_message" then
    chat.end_message(buf)
  elseif op.op == "tool_begin" then
    chat.tool_begin(buf, op.id, op.name, op.summary)
  elseif op.op == "tool_end" then
    chat.tool_end(buf, op.id, op.ok, op.output)
  elseif op.op == "status" then
    state.status = op.text
    input.set_status(state.input_win, op.text)
  end
end

---Feed one session event through projection and apply the resulting ops.
---@param event table
function M._apply_event(event)
  for _, op in ipairs(projection.project(event)) do
    apply_op(op)
  end
  -- Keep the transcript pinned to the newest content while events arrive.
  if M.is_open() then
    local n = vim.api.nvim_buf_line_count(state.chat_buf)
    vim.api.nvim_win_set_cursor(state.chat_win, { n, 0 })
  end
end

---Local echo of user input until milestone 2 wires the SDK send path.
---@param text string
function M._on_send(text)
  M._apply_event({ type = "user/message", content = text })
end

---Run the scripted demo session through the real rendering path.
function M.demo()
  require("ndsh.dev").run()
end

return M
