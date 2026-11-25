--- Window management for the ndsh panel.
---
--- The panel is two ordinary windows (chat over input), so native <C-w>
--- navigation, resizing and closing semantics apply unchanged. Windows are
--- hidden on toggle-off and re-shown on toggle-on; buffers persist either way.
local M = {}

---"No code buffer is up" when the tab holds one unmodified window whose
---buffer is not a real file: unnamed scratch, dashboards and other nofile
---buffers all count, and the panel takes over the whole tab like a
---full-screen TUI session.
---@return boolean
local function should_takeover()
  local wins = vim.api.nvim_tabpage_list_wins(0)
  if #wins ~= 1 then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(wins[1])
  if vim.api.nvim_get_option_value("modified", { buf = buf }) then
    return false
  end
  local is_real_file = vim.api.nvim_get_option_value("buftype", { buf = buf }) == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
  return not is_real_file
end

---Whether the current tab satisfies the takeover rule. Used by init.open()
---to decide if full mode needs a fresh tabpage.
---@return boolean
function M.is_takeover_tab()
  return should_takeover()
end

local function set_chat_win_options(win)
  local opts = {
    number = false,
    relativenumber = false,
    signcolumn = "no",
    wrap = true,
    linebreak = true,
    cursorline = false,
    foldmethod = "manual",
    foldenable = true,
    conceallevel = 2,
    winfixwidth = false,
  }
  for k, v in pairs(opts) do
    vim.api.nvim_set_option_value(k, v, { win = win })
  end
end

local function set_input_win_options(win, cfg)
  vim.api.nvim_set_option_value("winfixheight", true, { win = win })
  vim.api.nvim_win_set_height(win, cfg.input_height)
end

---Split the chat column horizontally for the input window.
---@return integer input_win
local function split_input_below(cfg, input_buf)
  vim.cmd(("belowright %dsplit"):format(cfg.input_height))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, input_buf)
  set_input_win_options(win, cfg)
  return win
end

local function show_takeover(cfg, chat_buf, input_buf)
  local chat_win = vim.api.nvim_get_current_win()
  -- Judge the replaced buffer before replacing it: wipe-hidden buffers
  -- (dashboards) are gone the moment they leave the window.
  local prev_buf = vim.api.nvim_win_get_buf(chat_win)
  local prev_contentful = vim.api.nvim_buf_get_name(prev_buf) ~= ""
    or vim.api.nvim_get_option_value("filetype", { buf = prev_buf }) ~= ""
  vim.api.nvim_win_set_buf(chat_win, chat_buf)
  set_chat_win_options(chat_win)
  local input_win = split_input_below(cfg, input_buf)
  return chat_win, input_win, prev_buf, prev_contentful
end

local function show_right(cfg, chat_buf, input_buf)
  vim.cmd("botright vsplit")
  local chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(chat_win, math.floor(vim.o.columns * cfg.width))
  vim.api.nvim_win_set_buf(chat_win, chat_buf)
  set_chat_win_options(chat_win)
  local input_win = split_input_below(cfg, input_buf)
  return chat_win, input_win
end

local function show_bottom(cfg, chat_buf, input_buf)
  local height = math.floor(vim.o.lines * cfg.height)
  vim.cmd(("botright %dsplit"):format(height))
  local chat_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(chat_win, chat_buf)
  set_chat_win_options(chat_win)
  local input_win = split_input_below(cfg, input_buf)
  return chat_win, input_win
end

local function show_float(cfg, chat_buf, input_buf)
  local width = math.floor(vim.o.columns * 0.6)
  local total = math.floor(vim.o.lines * 0.8)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - total) / 2)
  local chat_height = math.max(1, total - cfg.input_height - 2)
  local chat_win = vim.api.nvim_open_win(chat_buf, false, {
    relative = "editor",
    width = width,
    height = chat_height,
    row = row,
    col = col,
    border = "rounded",
    title = " ndsh ",
    title_pos = "left",
  })
  set_chat_win_options(chat_win)
  local input_win = vim.api.nvim_open_win(input_buf, true, {
    relative = "editor",
    width = width,
    height = cfg.input_height,
    row = row + chat_height + 2,
    col = col,
    border = "rounded",
  })
  set_input_win_options(input_win, cfg)
  return chat_win, input_win
end

---Open the panel windows. Chooses full-tab takeover when the tab holds one
---empty window, otherwise the configured dock mode. In takeover mode the
---replaced buffer is returned so close() can restore it.
---@return { chat: integer, input: integer, takeover: boolean, prev_buf: integer|nil, prev_contentful: boolean|nil }
function M.show(cfg, chat_buf, input_buf)
  local takeover = should_takeover()
  local chat_win, input_win
  local prev_buf, prev_contentful = nil, false
  if takeover then
    chat_win, input_win, prev_buf, prev_contentful = show_takeover(cfg, chat_buf, input_buf)
  elseif cfg.layout == "right" then
    chat_win, input_win = show_right(cfg, chat_buf, input_buf)
  elseif cfg.layout == "bottom" then
    chat_win, input_win = show_bottom(cfg, chat_buf, input_buf)
  else
    chat_win, input_win = show_float(cfg, chat_buf, input_buf)
  end
  vim.fn.win_gotoid(input_win)
  return {
    chat = chat_win,
    input = input_win,
    takeover = takeover,
    prev_buf = prev_buf,
    prev_contentful = prev_contentful,
  }
end

---Hide one window, or replace its buffer with an empty scratch when it is
---the tab's last NORMAL window (which cannot be hidden). Floating windows
---(e.g. an open telescope picker) always hide, and do not count toward the
---last-window rule: win_hide rejects the last non-floating window even
---while floats are up (E444).
---@param win integer
local function hide_or_scratch(win)
  if vim.api.nvim_win_get_config(win).relative ~= "" then
    vim.api.nvim_win_hide(win)
    return
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  local normal = 0
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      normal = normal + 1
    end
  end
  if normal <= 1 then
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, scratch)
  else
    vim.api.nvim_win_hide(win)
  end
end

---Hide the panel windows. When a window survives as the tab's last window
---it shows an empty scratch buffer; that survivor is returned so the caller
---can run a restore hook (e.g. show a dashboard) in it.
---@param wins { chat: integer|nil, input: integer|nil }
---@return integer|nil survivor window left showing a scratch buffer
function M.hide(wins)
  local survivor = nil
  if wins.input and vim.api.nvim_win_is_valid(wins.input) then
    hide_or_scratch(wins.input)
    if vim.api.nvim_win_is_valid(wins.input) then
      survivor = wins.input
    end
  end
  if wins.chat and vim.api.nvim_win_is_valid(wins.chat) then
    hide_or_scratch(wins.chat)
    if vim.api.nvim_win_is_valid(wins.chat) then
      survivor = wins.chat
    end
  end
  return survivor
end

return M
