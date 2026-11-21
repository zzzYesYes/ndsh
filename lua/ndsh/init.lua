--- ndsh plugin entry: setup, panel state, and the event-application path
--- shared by the dev harness and (milestone 2) the live SDK protocol.
local config = require("ndsh.config")
local layout = require("ndsh.ui.layout")
local chat = require("ndsh.ui.chat")
local input = require("ndsh.ui.input")
local projection = require("ndsh.projection")
local Session = require("ndsh.session")
local prompts = require("ndsh.ui.prompts")

local M = {}

local state = {
  cfg = nil, ---@type table|nil
  chat_buf = nil, ---@type integer|nil
  input_buf = nil, ---@type integer|nil
  chat_win = nil, ---@type integer|nil
  input_win = nil, ---@type integer|nil
  takeover = false,
  full_tab = false,
  closing = false, -- guard: our own hides must not retrigger panel teardown
  status = "idle",
  conn = "stopped", -- session connection state: starting|ready|error|stopped
  session = nil, ---@type table|nil NdsSession
}

local function ensure_setup()
  if not state.cfg then
    M.setup({})
  end
end

local function ensure_buffers()
  if not (state.chat_buf and vim.api.nvim_buf_is_valid(state.chat_buf)) then
    state.chat_buf = chat.create(state.cfg.keys)
  end
  if not (state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf)) then
    state.input_buf = input.create(state.cfg, function(text)
      M._on_send(text)
    end)
  end
end

---@param opts table|nil
function M.setup(opts)
  opts = opts or {}
  state.cfg = config.resolve(opts)
  -- The stored route applies only when setup() left provider/model at
  -- defaults; explicit configuration always wins over stored selection.
  local explicit = opts.dsh and (opts.dsh.provider ~= nil or opts.dsh.model ~= nil)
  if not explicit then
    local current = require("ndsh.credentials").current(state.cfg.store_path)
    if current then
      state.cfg.dsh.provider = current.provider
      state.cfg.dsh.model = current.model
    end
  end
  local toggle = state.cfg.keys.toggle
  if toggle then
    vim.keymap.set("n", toggle, function()
      M.toggle()
    end, { desc = "Toggle ndsh panel" })
  end
  local toggle_full = state.cfg.keys.toggle_full
  if toggle_full then
    vim.keymap.set("n", toggle_full, function()
      M.toggle_full()
    end, { desc = "Toggle ndsh panel (full screen)" })
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ndsh_lifecycle", { clear = true }),
    callback = function()
      M.stop_session()
    end,
  })
end

---@return boolean
function M.is_open()
  return state.chat_win ~= nil and vim.api.nvim_win_is_valid(state.chat_win)
end

---Hide panel windows without retriggering the WinClosed teardown.
---@param wins table
local function hide_guarded(wins)
  state.closing = true
  layout.hide(wins)
  -- WinClosed handlers are scheduled, so the guard lifts after they run.
  vim.schedule(function()
    state.closing = false
  end)
end

---Panel windows are reserved: buffer navigation inside them (barbar's
---:BufferNext et al. operates on the current window) must not replace their
---buffers. Snap replaced buffers back; a deleted panel buffer tears the
---panel down and it is rebuilt on the next open.
local function guard_panel_buffers()
  if state.closing or not state.chat_win then
    return
  end
  if not (state.chat_buf and vim.api.nvim_buf_is_valid(state.chat_buf))
    or not (state.input_buf and vim.api.nvim_buf_is_valid(state.input_buf))
  then
    vim.notify("ndsh: a panel buffer was deleted; closing the panel", vim.log.levels.WARN)
    M.close()
    return
  end
  local snapped = false
  if vim.api.nvim_win_is_valid(state.chat_win)
    and vim.api.nvim_win_get_buf(state.chat_win) ~= state.chat_buf
  then
    vim.api.nvim_win_set_buf(state.chat_win, state.chat_buf)
    snapped = true
  end
  if vim.api.nvim_win_is_valid(state.input_win)
    and vim.api.nvim_win_get_buf(state.input_win) ~= state.input_buf
  then
    vim.api.nvim_win_set_buf(state.input_win, state.input_buf)
    snapped = true
  end
  if snapped then
    vim.notify("ndsh: panel windows are reserved; close the panel to reuse them", vim.log.levels.INFO)
  end
end

---The panel is one unit: when the user closes either window by hand (:q,
---<C-w>c, ...), tear the whole panel down. Buffers are kept.
local function watch_windows()
  local group = vim.api.nvim_create_augroup("ndsh_panel", { clear = true })
  for _, win in ipairs({ state.chat_win, state.input_win }) do
    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      callback = function()
        vim.schedule(function()
          if not state.closing then
            M.close()
          end
        end)
      end,
    })
  end
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function()
      vim.schedule(guard_panel_buffers)
    end,
  })
end

---@param opts { full: boolean|nil }|nil full: open as a full tab even with
---code buffers open (implemented as a new tabpage; closing restores it).
function M.open(opts)
  opts = opts or {}
  ensure_setup()
  ensure_buffers()
  if M.is_open() then
    if opts.full then
      -- Already open: jump to the panel's tabpage instead of rebuilding.
      vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(state.chat_win))
    elseif vim.api.nvim_win_get_tabpage(state.chat_win) ~= vim.api.nvim_get_current_tabpage() then
      -- Open in another tab: move the panel here instead of duplicating it.
      hide_guarded({ chat = state.chat_win, input = state.input_win, takeover = state.takeover })
    else
      return
    end
  end
  if not M.is_open() then
    local wins
    if opts.full then
      -- Full mode always gets a dedicated tabpage so tab switching between
      -- code and panel is always available; closing tabs back out.
      vim.cmd("tabnew")
      wins = layout.show(state.cfg, state.chat_buf, state.input_buf)
      state.full_tab = wins.takeover
    else
      wins = layout.show(state.cfg, state.chat_buf, state.input_buf)
      state.full_tab = false
    end
    state.chat_win = wins.chat
    state.input_win = wins.input
    state.takeover = wins.takeover
    input.set_status(state.input_win, state.status)
    watch_windows()
  end
  M._ensure_session()
end

---Try to show a dashboard in the surviving window after a takeover closes.
---Falls back silently to the scratch buffer already in place.
---@param win integer
local function restore_dashboard(win)
  local ok, dash = pcall(require, "config.dashboard")
  if ok and type(dash.open) == "function" then
    if pcall(vim.api.nvim_win_call, win, dash.open) then
      return
    end
  end
  for _, cmd in ipairs({ "Dashboard", "Alpha" }) do
    if vim.fn.exists(":" .. cmd) == 2 then
      if pcall(vim.api.nvim_win_call, win, function()
        vim.cmd(cmd)
      end) then
        return
      end
    end
  end
  local ok_snacks, snacks = pcall(require, "snacks")
  if ok_snacks and snacks.dashboard and type(snacks.dashboard.open) == "function" then
    pcall(snacks.dashboard.open)
  end
end

function M.close()
  local chat_valid = state.chat_win ~= nil and vim.api.nvim_win_is_valid(state.chat_win)
  local input_valid = state.input_win ~= nil and vim.api.nvim_win_is_valid(state.input_win)
  if not chat_valid and not input_valid then
    state.chat_win, state.input_win = nil, nil
    state.takeover, state.full_tab = false, false
    return
  end
  -- Only the panel is left in the only tab: closing it exits Neovim like
  -- :q on the last file window. Falls through to hide on :quitall failure
  -- (e.g. a modified hidden buffer) and restores a scratch instead.
  local only_pane = state.takeover and #vim.api.nvim_list_tabpages() == 1
  if only_pane and state.cfg.restore == "quit" then
    if pcall(vim.cmd, "quitall") then
      return
    end
  end
  state.closing = true
  local survivor = nil
  if state.full_tab then
    -- Closing the tabpage closes both panel windows with it.
    pcall(vim.cmd, "tabclose")
  else
    survivor = layout.hide({
      chat = chat_valid and state.chat_win or nil,
      input = input_valid and state.input_win or nil,
    })
  end
  state.chat_win = nil
  state.input_win = nil
  state.takeover = false
  state.full_tab = false
  if survivor and vim.api.nvim_win_is_valid(survivor) then
    local restore = state.cfg.restore
    if type(restore) == "function" then
      pcall(restore, survivor)
    elseif restore == "dashboard" then
      restore_dashboard(survivor)
    end
  end
  -- WinClosed handlers are scheduled, so the guard lifts after they run.
  vim.schedule(function()
    state.closing = false
  end)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

---Toggle the full-screen panel: closes it when pressed inside its tab,
---converts a docked panel to full-screen, otherwise opens it or jumps to it.
function M.toggle_full()
  if not M.is_open() then
    M.open({ full = true })
    return
  end
  local in_panel_tab = vim.api.nvim_win_get_tabpage(state.chat_win) == vim.api.nvim_get_current_tabpage()
  if state.full_tab and in_panel_tab then
    M.close()
  elseif not state.full_tab and not state.takeover then
    -- Docked panel: rebuild as a dedicated full tab.
    M.close()
    M.open({ full = true })
  else
    -- Takeover panel is already full-screen: just focus it.
    M.open({ full = true })
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
  elseif op.op == "error" then
    chat.error(buf, op.text)
  elseif op.op == "status" then
    state.status = op.text
    -- Connection state owns the winbar outside "ready".
    if state.conn == "ready" then
      input.set_status(state.input_win, op.text)
    end
  end
end

---Connection state to winbar text outside the ready state.
local CONN_LABEL = {
  starting = "connecting…",
  error = "error (:NDSHRestart)",
  stopped = "stopped",
}

---Create and start the runtime session on first use.
function M._ensure_session()
  if state.session or not state.cfg.dsh.auto_connect then
    if state.session and state.session.state == "stopped" then
      state.session:start()
    end
    return
  end
  state.session = Session.new(state.cfg, {
    on_event = function(event)
      M._apply_event(event)
    end,
    on_status = function(status)
      apply_op({ op = "status", text = status })
    end,
    on_state = function(conn)
      state.conn = conn
      input.set_status(state.input_win, conn == "ready" and state.status or CONN_LABEL[conn] or conn)
    end,
    on_notify = function(msg, level)
      vim.notify(msg, level)
    end,
    on_approval = prompts.approval,
    on_user_question = prompts.user_question,
  })
  state.session:start()
end

function M.stop_session()
  if state.session then
    state.session:stop()
  end
end

function M.restart_session()
  if state.session then
    state.session:restart()
  else
    state.session = nil
    M._ensure_session()
  end
end

---Interactive provider connection (:NDSHConnect): pick a provider, enter
---its credentials and model, persist them, then restart the runtime.
function M.connect()
  ensure_setup()
  local providers = state.cfg.providers
  vim.ui.select(providers, {
    prompt = "ndsh: connect provider",
    format_item = function(item)
      return item.label
    end,
  }, function(provider)
    if not provider then
      return
    end
    local env = {}
    local function ask_model()
      vim.ui.input({ prompt = "Model: ", default = provider.default_model or "" }, function(model)
        if not model or model == "" then
          return
        end
        local credentials = require("ndsh.credentials")
        credentials.set(provider.id, { env = env, model = model }, state.cfg.store_path)
        credentials.set_current(provider.id, model, state.cfg.store_path)
        state.cfg.dsh.provider = provider.id
        state.cfg.dsh.model = model
        M.restart_session()
        vim.notify(("ndsh: connected %s (%s)"):format(provider.label, model), vim.log.levels.INFO)
      end)
    end
    local function ask_key(i)
      if i > #provider.env then
        ask_model()
        return
      end
      local name = provider.env[i]
      vim.ui.input({ prompt = ("API key (%s), empty to skip: "):format(name) }, function(secret)
        if secret == nil then
          return -- aborted: leave the store and runtime untouched
        end
        if secret ~= "" then
          env[name] = secret
        end
        ask_key(i + 1)
      end)
    end
    ask_key(1)
  end)
end

---Model picker (:NDSHModel): candidates are the active route, configured
---dsh.models entries, and every connected provider's stored model. The
---selection persists and the runtime restarts on the new route (the SDK
---fixes provider/model at initialize, so switching means a new session).
function M.select_model()
  ensure_setup()
  local credentials = require("ndsh.credentials")
  local store = credentials.load(state.cfg.store_path)
  local candidates, seen = {}, {}
  local function add(provider, model, label)
    if not provider or not model then
      return
    end
    local key = provider .. "\0" .. model
    if seen[key] then
      return
    end
    seen[key] = true
    candidates[#candidates + 1] = {
      provider = provider,
      model = model,
      label = label or (provider .. " / " .. model),
    }
  end
  add(state.cfg.dsh.provider, state.cfg.dsh.model)
  for _, m in ipairs(state.cfg.dsh.models) do
    add(m.provider, m.model, m.label)
  end
  for provider, entry in pairs(store) do
    if provider ~= "_current" and type(entry) == "table" then
      add(provider, entry.model)
    end
  end
  vim.ui.select(candidates, {
    prompt = "ndsh: select model",
    format_item = function(item)
      local active = item.provider == state.cfg.dsh.provider and item.model == state.cfg.dsh.model
      return item.label .. (active and "  (current)" or "")
    end,
  }, function(choice)
    if not choice then
      return
    end
    credentials.set_current(choice.provider, choice.model, state.cfg.store_path)
    state.cfg.dsh.provider = choice.provider
    state.cfg.dsh.model = choice.model
    M.restart_session()
    vim.notify(("ndsh: switched to %s (new session)"):format(choice.label), vim.log.levels.INFO)
  end)
end

---Show the runtime's captured stderr log in a scratch split.
function M.show_logs()
  local lines = state.session and state.session:logs() or {}
  if #lines == 0 then
    lines = { "(no runtime logs)" }
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
  vim.cmd("botright 15split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_hide(win)
    end
  end, { buffer = buf, desc = "Close ndsh log" })
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

---Echo user input locally, then send it to the runtime. The wire only
---commits user/message when a step admits the input, so the echo is the
---only reliable "You" line; wire user/message events are not rendered.
---@param text string
function M._on_send(text)
  apply_op({ op = "begin_message", role = "user" })
  apply_op({ op = "append", text = text })
  apply_op({ op = "end_message" })
  if not state.session then
    vim.notify("ndsh: runtime not connected; use :NDSHRestart", vim.log.levels.WARN)
    return
  end
  state.session:send(text)
end

---Run the scripted demo session through the real rendering path.
function M.demo()
  require("ndsh.dev").run()
end

return M
