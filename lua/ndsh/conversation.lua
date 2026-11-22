--- One conversation: a wire session id, a display name, its transcript and
--- input buffers, the panel windows showing them, and the per-conversation
--- chrome state (status, route, context usage). Everything window-related is
--- per-conversation; the registry in init.lua owns the set.
local chat = require("ndsh.ui.chat")
local input = require("ndsh.ui.input")
local layout = require("ndsh.ui.layout")
local projection = require("ndsh.projection")

local M = {}
M.__index = M

---Format a token count compactly: 1234 → "1.2k", 1234567 → "1.2M".
local function fmt_tokens(n)
  if n >= 1000000 then
    return ("%.1fM"):format(n / 1000000)
  elseif n >= 10000 then
    return ("%dk"):format(n / 1000)
  elseif n >= 1000 then
    return ("%.1fk"):format(n / 1000)
  end
  return tostring(n)
end

---Connection state to winbar text outside the ready state.
local CONN_LABEL = {
  starting = "connecting…",
  error = "error (:NDSHRestart)",
  stopped = "stopped",
}

---@class NdsConvHooks
---@field on_send fun(conv: table, text: string) send path for typed input
---@field should_quit fun(): boolean close() exits nvim instead of restoring
---@field restore fun(survivor: integer, prev_buf: integer|nil) restore a closed takeover
---@field conn_state fun(): string runtime connection state
---@field spinner_frame fun(): string current animation frame
---@field status_changed fun() called whenever a conversation's status flips

---@param cfg table resolved ndsh config
---@param spec { id: string, name: string }
---@param hooks NdsConvHooks
function M.new(cfg, spec, hooks)
  local conv = setmetatable({
    cfg = cfg,
    hooks = hooks,
    id = spec.id,
    name = spec.name,
    chat_buf = nil, ---@type integer|nil
    input_buf = nil, ---@type integer|nil
    chat_win = nil, ---@type integer|nil
    input_win = nil, ---@type integer|nil
    takeover = false,
    closing = false, -- guard: our own hides must not retrigger panel teardown
    prev_buf = nil, ---@type integer|nil
    prev_contentful = false,
    status = "idle", ---@type "idle"|"running"
    route = nil, ---@type { provider: string, model: string }|nil
    context = { used = nil, window = nil }, ---@type { used: integer|nil, window: integer|nil }
    unread = false,
  }, M)
  conv:ensure_buffers()
  return conv
end

function M:ensure_buffers()
  if not (self.chat_buf and vim.api.nvim_buf_is_valid(self.chat_buf)) then
    self.chat_buf = chat.create(self.cfg.keys, self.id)
  end
  if not (self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf)) then
    self.input_buf = input.create(self.cfg, function(text)
      self.hooks.on_send(self, text)
    end, self.id)
  end
end

---@return boolean
function M:is_open()
  return self.chat_win ~= nil and vim.api.nvim_win_is_valid(self.chat_win)
end

---Hide panel windows without retriggering the WinClosed teardown.
local function hide_guarded(self, wins)
  self.closing = true
  layout.hide(wins)
  -- WinClosed handlers are scheduled, so the guard lifts after they run.
  vim.schedule(function()
    self.closing = false
  end)
end

---Panel windows are reserved: opening a file while focused in one (e.g. a
---picker's :edit) must not displace the panel. The incoming buffer is
---relocated to a fresh tabpage and the panel buffer is restored, so the
---file still opens — just never inside the panel. A deleted panel buffer
---tears the panel down and it is rebuilt on the next open.
local function guard_panel_buffers(self)
  if self.closing or not self.chat_win then
    return
  end
  if not (self.chat_buf and vim.api.nvim_buf_is_valid(self.chat_buf))
    or not (self.input_buf and vim.api.nvim_buf_is_valid(self.input_buf))
  then
    vim.notify("ndsh: a panel buffer was deleted; closing the panel", vim.log.levels.WARN)
    self:close()
    return
  end
  local relocated = {}
  if vim.api.nvim_win_is_valid(self.chat_win)
    and vim.api.nvim_win_get_buf(self.chat_win) ~= self.chat_buf
  then
    relocated[#relocated + 1] = vim.api.nvim_win_get_buf(self.chat_win)
    vim.api.nvim_win_set_buf(self.chat_win, self.chat_buf)
  end
  if vim.api.nvim_win_is_valid(self.input_win)
    and vim.api.nvim_win_get_buf(self.input_win) ~= self.input_buf
  then
    relocated[#relocated + 1] = vim.api.nvim_win_get_buf(self.input_win)
    vim.api.nvim_win_set_buf(self.input_win, self.input_buf)
  end
  for _, buf in ipairs(relocated) do
    if vim.api.nvim_buf_is_valid(buf) then
      -- Third-party autocmds fire when the buffer enters the new tab's
      -- window; their errors must not abort the relocation loop. tabnew's
      -- fresh listed scratch buffer is deleted so it cannot leak into
      -- buffer lists (barbar would show it as "buffer N").
      local ok = pcall(function()
        vim.cmd("tabnew")
        local scratch = vim.api.nvim_get_current_buf()
        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
        vim.api.nvim_buf_delete(scratch, { force = true })
      end)
      if ok then
        vim.notify("ndsh: opened in a new tab (panel windows are reserved)", vim.log.levels.INFO)
      end
    end
  end
end

---The panel is one unit: when the user closes either window by hand (:q,
---<C-w>c, ...), tear the whole panel down. Buffers are kept.
function M:watch_windows()
  local group = vim.api.nvim_create_augroup("ndsh_panel_" .. self.id:gsub("%W", "_"), { clear = true })
  for _, win in ipairs({ self.chat_win, self.input_win }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      callback = function()
        vim.schedule(function()
          if not self.closing then
            self:close()
          end
        end)
      end,
    })
  end
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      vim.schedule(function()
        guard_panel_buffers(self)
      end)
    end,
  })
  -- Repaint chrome whenever a panel window is entered: external plugins
  -- that redraw window decorations cannot permanently clobber it.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if not self.closing then
        self:refresh_chrome()
        self:mark_read()
      end
    end,
  })
end

---Open the panel windows in the current tab (docked or takeover layout).
function M:open()
  self:ensure_buffers()
  if self:is_open() then
    if vim.api.nvim_win_get_tabpage(self.chat_win) ~= vim.api.nvim_get_current_tabpage() then
      -- Open in another tab: move the panel here instead of duplicating it.
      hide_guarded(self, { chat = self.chat_win, input = self.input_win })
    else
      return
    end
  end
  if not self:is_open() then
    local wins = layout.show(self.cfg, self.chat_buf, self.input_buf)
    self.chat_win = wins.chat
    self.input_win = wins.input
    self.takeover = wins.takeover
    self.prev_buf = wins.prev_buf
    self.prev_contentful = wins.prev_contentful or false
    self:refresh_chrome()
    local commands = require("ndsh.commands")
    input.highlight_commands(self.input_win, commands.names(), commands.wire_names())
    self:watch_windows()
  end
  self:mark_read()
end

---Hide the panel windows, keeping buffers and registration. Unlike
---close(), no restore semantics: used when swapping visible conversations.
function M:hide()
  if not self:is_open() then
    return
  end
  hide_guarded(self, { chat = self.chat_win, input = self.input_win })
  self.chat_win = nil
  self.input_win = nil
  self.takeover = false
  self.prev_buf = nil
  self.prev_contentful = false
end

function M:close()
  local chat_valid = self.chat_win ~= nil and vim.api.nvim_win_is_valid(self.chat_win)
  local input_valid = self.input_win ~= nil and vim.api.nvim_win_is_valid(self.input_win)
  if not chat_valid and not input_valid then
    self.chat_win, self.input_win = nil, nil
    self.takeover = false
    self.prev_buf, self.prev_contentful = nil, false
    return
  end
  -- Only the panel is left in the only tab and the registry has nothing
  -- else: closing exits Neovim like :q on the last file window, unless the
  -- takeover replaced content worth restoring.
  if self.hooks.should_quit() then
    if pcall(vim.cmd, "quitall") then
      return
    end
  end
  self.closing = true
  local survivor = layout.hide({
    chat = chat_valid and self.chat_win or nil,
    input = input_valid and self.input_win or nil,
  })
  self.chat_win = nil
  self.input_win = nil
  self.takeover = false
  if survivor and vim.api.nvim_win_is_valid(survivor) then
    self.hooks.restore(survivor, self.prev_contentful and self.prev_buf or nil)
  end
  self.prev_buf = nil
  self.prev_contentful = false
  -- WinClosed handlers are scheduled, so the guard lifts after they run.
  vim.schedule(function()
    self.closing = false
  end)
end

function M:focus_input()
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    vim.fn.win_gotoid(self.input_win)
    vim.cmd("startinsert")
  end
end

---Refresh the conversation's winbars. Everything except the name lives on
---the chat (input) pane: status and model left; working directory and
---context usage right. The message pane winbar carries the session name
---with an unread marker.
function M:refresh_chrome()
  if self.chat_win and vim.api.nvim_win_is_valid(self.chat_win) then
    vim.api.nvim_set_option_value(
      "winbar",
      " " .. self.name .. (self.unread and "  ●" or ""),
      { win = self.chat_win }
    )
  end
  if self.input_win and vim.api.nvim_win_is_valid(self.input_win) then
    local conn = self.hooks.conn_state()
    local status = conn == "ready" and self.status or (CONN_LABEL[conn] or conn)
    if status == "running" then
      -- Animated frame cycles while the session works.
      status = self.hooks.spinner_frame()
    end
    local model = self.route and self.route.model or self.cfg.dsh.model
    local right_parts = {}
    local cwd = vim.uv.cwd()
    cwd = cwd and vim.fn.fnamemodify(cwd, ":~") or ""
    if cwd ~= "" then
      right_parts[#right_parts + 1] = cwd
    end
    if self.context.used then
      local ctx = fmt_tokens(self.context.used)
      if self.context.window then
        -- winbar is statusline syntax: a literal % must be doubled.
        ctx = ctx .. ("/%s · %d%%%%"):format(
          fmt_tokens(self.context.window),
          math.floor(self.context.used / self.context.window * 100 + 0.5)
        )
      end
      right_parts[#right_parts + 1] = ctx
    end
    local right = table.concat(right_parts, " · ")
    input.set_status(
      self.input_win,
      ("%s · %s%s"):format(status, model, right ~= "" and "%= " .. right .. " " or "")
    )
  end
end

function M:mark_unread()
  if not self:is_open() then
    self.unread = true
  end
  self:refresh_chrome()
end

function M:mark_read()
  if self.unread then
    self.unread = false
    self:refresh_chrome()
  end
end

function M:set_status(status)
  self.status = status
  self:refresh_chrome()
  self.hooks.status_changed()
end

function M:rename(name)
  self.name = name
  self:refresh_chrome()
end

---Apply one projected writer operation.
---@param op table
function M:apply_op(op)
  local buf = self.chat_buf
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
  elseif op.op == "reasoning" then
    chat.reasoning(buf, op.text)
  elseif op.op == "error" then
    chat.error(buf, op.text)
  elseif op.op == "notice" then
    chat.notice(buf, op.text)
  elseif op.op == "status" then
    self:set_status(op.text)
  elseif op.op == "usage" then
    self.context.used = op.input
    self:refresh_chrome()
  elseif op.op == "route" then
    self.route = { provider = op.provider, model = op.model }
    self.context.window = op.window or self.context.window
    self:refresh_chrome()
  end
end

---Feed one session event through projection and apply the resulting ops.
---@param event table
function M:apply_event(event)
  for _, op in ipairs(projection.project(event)) do
    self:apply_op(op)
  end
  if self:is_open() then
    -- Keep the transcript pinned to the newest content while events arrive.
    local n = vim.api.nvim_buf_line_count(self.chat_buf)
    vim.api.nvim_win_set_cursor(self.chat_win, { n, 0 })
  else
    self:mark_unread()
  end
end

---Echo user input locally, so the "You" line never depends on admission.
---@param text string
function M:echo_user(text)
  self:apply_op({ op = "begin_message", role = "user" })
  self:apply_op({ op = "append", text = text })
  self:apply_op({ op = "end_message" })
end

return M
