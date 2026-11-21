--- ndsh plugin entry: setup, the conversation registry, runtime wiring,
--- commands, and local slash commands. Per-conversation window/buffer
--- behavior lives in ndsh.conversation; process/transport in ndsh.runtime.
local config = require("ndsh.config")
local Runtime = require("ndsh.runtime")
local Conversation = require("ndsh.conversation")
local commands = require("ndsh.commands")
local prompts = require("ndsh.ui.prompts")
local sessions_ui = require("ndsh.ui.sessions")

local M = {}

local state = {
  cfg = nil, ---@type table|nil
  runtime = nil, ---@type table|nil NdsRuntime
  conn = "stopped", -- runtime connection state: starting|ready|error|stopped
  conversations = {}, ---@type table[] ordered, most recently created last
  by_id = {}, ---@type table<string, table>
  active = nil, ---@type table|nil
  seq = 0,
  activity = {}, ---@type table<string, integer> conv id -> monotonically increasing activity stamp
  activity_seq = 0,
}

local function ensure_setup()
  if not state.cfg then
    M.setup({})
  end
end

---@param conv table
local function touch(conv)
  state.activity_seq = state.activity_seq + 1
  state.activity[conv.id] = state.activity_seq
end

---Create and register a conversation.
---@param name string|nil
---@return table conv
local function new_conversation(name)
  state.seq = state.seq + 1
  local conv = Conversation.new(state.cfg, {
    id = ("ndsh-%d-%d"):format(state.seq, math.random(100000)),
    name = name or ("chat " .. state.seq),
  }, {
    on_send = function(c, text)
      M._on_send(c, text)
    end,
    should_quit = function()
      -- Only the panel is left in the only tab, it is the only registered
      -- conversation, and the takeover replaced nothing worth restoring.
      local only_conv = state.active
      return #state.conversations == 1
        and only_conv.takeover
        and #vim.api.nvim_list_tabpages() == 1
        and not only_conv.prev_contentful
        and state.cfg.restore == "quit"
    end,
    restore = function(survivor, prev_buf)
      if prev_buf and vim.api.nvim_buf_is_valid(prev_buf) then
        vim.api.nvim_win_set_buf(survivor, prev_buf)
      else
        M._restore_hook(survivor)
      end
    end,
    conn_state = function()
      return state.conn
    end,
  })
  state.conversations[#state.conversations + 1] = conv
  state.by_id[conv.id] = conv
  touch(conv)
  return conv
end

---@return table conv the active conversation, creating the first on demand
local function active_conversation()
  if not state.active then
    state.active = new_conversation(nil)
  end
  return state.active
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
  local function map(key, fn, desc)
    if key then
      vim.keymap.set("n", key, fn, { desc = desc })
    end
  end
  map(state.cfg.keys.toggle, M.toggle, "Toggle ndsh panel")
  map(state.cfg.keys.toggle_full, M.toggle_full, "Toggle ndsh panel (full screen)")
  map(state.cfg.keys.sessions, M.sessions, "Navigate ndsh sessions")
  map(state.cfg.keys.new_session, function()
    M.new_session()
  end, "New ndsh session")
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ndsh_lifecycle", { clear = true }),
    callback = function()
      M.stop_session()
    end,
  })
  -- Connect eagerly: the runtime boots in the background at plugin load so
  -- the first prompt never waits for it. Deferred so setup() returns first.
  if state.cfg.dsh.auto_connect then
    vim.schedule(function()
      M._ensure_runtime()
    end)
  end
end

---@return boolean whether the active conversation's panel is open
function M.is_open()
  return state.active ~= nil and state.active:is_open()
end

---@param opts { full: boolean|nil }|nil
function M.open(opts)
  ensure_setup()
  local conv = active_conversation()
  conv:open(opts)
  touch(conv)
  M._ensure_runtime()
end

function M.close()
  if state.active then
    state.active:close()
  end
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
  local conv = active_conversation()
  if not conv:is_open() then
    M.open({ full = true })
    return
  end
  local in_panel_tab = vim.api.nvim_win_get_tabpage(conv.chat_win) == vim.api.nvim_get_current_tabpage()
  if conv.full_tab and in_panel_tab then
    conv:close()
  elseif not conv.full_tab and not conv.takeover then
    -- Docked panel: rebuild as a dedicated full tab.
    conv:close()
    conv:open({ full = true })
    M._ensure_runtime()
  else
    -- Takeover panel is already full-screen: just focus it.
    conv:open({ full = true })
  end
end

function M.focus_input()
  if state.active then
    state.active:focus_input()
  end
end

---Create a conversation in a new full-tab panel (:NDSHNew).
---@param name string|nil
function M.new_session(name)
  ensure_setup()
  local conv = new_conversation(name)
  state.active = conv
  conv:open({ full = true })
  M._ensure_runtime()
  return conv
end

---Jump to a conversation's tab, opening its panel when detached.
---@param conv table
local function goto_conversation(conv)
  state.active = conv
  touch(conv)
  if not conv:is_open() then
    conv:open({ full = true })
    M._ensure_runtime()
  else
    vim.api.nvim_set_current_tabpage(vim.api.nvim_win_get_tabpage(conv.chat_win))
  end
  conv:mark_read()
end

---Session navigator (:NDSHSessions), most recently active first.
function M.sessions()
  ensure_setup()
  if #state.conversations == 0 then
    vim.notify("ndsh: no sessions yet; :NDSHNew to create one", vim.log.levels.INFO)
    return
  end
  local ordered = vim.deepcopy(state.conversations)
  table.sort(ordered, function(a, b)
    return (state.activity[a.id] or 0) > (state.activity[b.id] or 0)
  end)
  -- Current session sinks to the bottom so alternating two is natural.
  sessions_ui.open(ordered, goto_conversation)
end

---Rename the active conversation (:NDSHRename and /rename).
---@param name string|nil prompts when nil
function M.rename(name)
  local conv = active_conversation()
  if name and name ~= "" then
    conv:rename(name)
    touch(conv)
    return
  end
  vim.ui.input({ prompt = "Session name: ", default = conv.name }, function(text)
    if text and text ~= "" then
      conv:rename(text)
      touch(conv)
    end
  end)
end

---Echo input locally, then send it on the conversation's wire session.
---Accepts (conv, text); a single argument is treated as text on the active
---conversation (test and dev harness path).
---@param conv table|string
---@param text string|nil
function M._on_send(conv, text)
  if text == nil then
    text = conv --[[@as string]]
    conv = active_conversation()
  end
  if commands.run(conv, text) then
    return
  end
  conv:echo_user(text)
  touch(conv)
  if not state.runtime then
    vim.notify("ndsh: runtime not connected; use :NDSHRestart", vim.log.levels.WARN)
    return
  end
  state.runtime:send(conv.id, text)
end

---Feed one session event to a conversation by wire session id.
---@param session_id string
---@param event table
function M._route_event(session_id, event)
  local conv = state.by_id[session_id]
  if conv then
    conv:apply_event(event)
  end
end

---Test/dev hook: apply an event to the active conversation.
---@param event table
function M._apply_event(event)
  active_conversation():apply_event(event)
end

---Create and start the runtime on first use.
function M._ensure_runtime()
  if state.runtime then
    if state.runtime.state == "stopped" then
      state.runtime:start()
    end
    return
  end
  state.runtime = Runtime.new(state.cfg, {
    on_event = function(session_id, event)
      M._route_event(session_id, event)
    end,
    on_status = function(session_id, status)
      local conv = state.by_id[session_id]
      if conv then
        conv:set_status(status)
      end
    end,
    on_state = function(conn)
      state.conn = conn
      for _, conv in ipairs(state.conversations) do
        conv:refresh_chrome()
      end
    end,
    on_notify = function(msg, level)
      vim.notify(msg, level)
    end,
    on_approval = function(params, respond)
      local conv = params.sessionId and state.by_id[params.sessionId] or nil
      prompts.approval(params, respond, conv and conv.name or nil)
    end,
    on_user_question = function(params, respond)
      local conv = params.sessionId and state.by_id[params.sessionId] or nil
      prompts.user_question(params, respond, conv and conv.name or nil)
    end,
  })
  state.runtime:start()
end

function M.stop_session()
  if state.runtime then
    state.runtime:stop()
  end
end

function M.restart_session()
  if state.runtime then
    state.runtime:restart()
  else
    M._ensure_runtime()
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
  local lines = state.runtime and state.runtime:logs() or {}
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

---Restore hook for a closed takeover with nothing contentful to restore.
---@param survivor integer
function M._restore_hook(survivor)
  local restore = state.cfg.restore
  if type(restore) == "function" then
    pcall(restore, survivor)
    return
  end
  if restore ~= "dashboard" then
    return
  end
  local ok, dash = pcall(require, "config.dashboard")
  if ok and type(dash.open) == "function" then
    if pcall(vim.api.nvim_win_call, survivor, dash.open) then
      return
    end
  end
  for _, cmd in ipairs({ "Dashboard", "Alpha" }) do
    if vim.fn.exists(":" .. cmd) == 2 then
      if pcall(vim.api.nvim_win_call, survivor, function()
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

---Run the scripted demo session through the real rendering path.
function M.demo()
  require("ndsh.dev").run()
end

return M
