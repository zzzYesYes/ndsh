--- ndsh plugin entry: setup, the conversation registry, runtime wiring,
--- commands, and local slash commands. Per-conversation window/buffer
--- behavior lives in ndsh.conversation; process/transport in ndsh.runtime.
local config = require("ndsh.config")
local Runtime = require("ndsh.runtime")
local Conversation = require("ndsh.conversation")
local commands = require("ndsh.commands")
local persist = require("ndsh.persist")
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
  --- ASCII spinner, animated while any conversation is running.
  spinner = { idx = 1, timer = nil, frames = { "|", "/", "-", "\\" } },
}

---Advance the spinner for every running conversation; idle conversations
---keep their static winbar. The timer runs only while something runs.
local function update_spinner()
  local any_running = false
  for _, conv in ipairs(state.conversations) do
    if conv.status == "running" then
      any_running = true
      break
    end
  end
  local spinner = state.spinner
  if any_running and not spinner.timer then
    spinner.timer = vim.uv.new_timer()
    spinner.timer:start(0, 120, vim.schedule_wrap(function()
      spinner.idx = spinner.idx % #spinner.frames + 1
      for _, conv in ipairs(state.conversations) do
        if conv.status == "running" then
          conv:refresh_chrome()
        end
      end
    end))
  elseif not any_running and spinner.timer then
    spinner.timer:stop()
    spinner.timer:close()
    spinner.timer = nil
  end
end

local function ensure_setup()
  if not state.cfg then
    M.setup({})
  end
end

---@param conv table
local function touch(conv)
  state.activity_seq = state.activity_seq + 1
  state.activity[conv.id] = state.activity_seq
  conv.last_active = os.time()
end

---Persist the registry (create/rename/delete/activate; not every touch).
local function persist_save()
  if not state.cfg.persist_sessions then
    return
  end
  local entries = {}
  for _, conv in ipairs(state.conversations) do
    entries[#entries + 1] = {
      id = conv.id,
      name = conv.name,
      created = conv.created,
      last_active = conv.last_active or conv.created,
    }
  end
  persist.save(state.cfg, entries)
end

---Create and register a conversation. With `stored`, restores a persisted
---entry as detached: its original wire id is the resume address.
---@param name string|nil
---@param stored table|nil NdsStoredSession
---@return table conv
local function new_conversation(name, stored)
  state.seq = state.seq + 1
  if not stored then
    state.live_seq = (state.live_seq or 0) + 1
  end
  local conv = Conversation.new(state.cfg, {
    id = stored and stored.id or ("ndsh-%d-%d"):format(state.seq, math.random(100000)),
    name = name or (stored and stored.name) or ("chat " .. state.live_seq),
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
    spinner_frame = function()
      return state.spinner.frames[state.spinner.idx]
    end,
    status_changed = function()
      update_spinner()
    end,
  })
  conv.created = stored and stored.created or os.time()
  conv.last_active = stored and stored.last_active or conv.created
  conv.resume_state = stored and "detached" or "live"
  state.conversations[#state.conversations + 1] = conv
  state.by_id[conv.id] = conv
  touch(conv)
  if not stored then
    persist_save()
  end
  return conv
end

---Show a conversation in the single panel, swapping out the visible one.
---@param conv table
local function show_conversation(conv)
  if state.active and state.active ~= conv and state.active:is_open() then
    state.active:hide()
  end
  state.active = conv
  touch(conv)
  conv:open()
  M._ensure_runtime()
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
  -- Restore persisted conversations as detached entries (once per process).
  if state.cfg.persist_sessions and not state.restored then
    state.restored = true
    for _, stored in ipairs(persist.load(state.cfg)) do
      new_conversation(nil, stored)
    end
  end
  local function map(key, fn, desc)
    if key then
      vim.keymap.set("n", key, fn, { desc = desc })
    end
  end
  map(state.cfg.keys.toggle, M.toggle, "Toggle ndsh panel")
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

function M.open()
  ensure_setup()
  show_conversation(active_conversation())
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

function M.focus_input()
  if state.active then
    state.active:focus_input()
  end
end

---Create a conversation and show it in the panel (:NDSHNew).
---@param name string|nil
function M.new_session(name)
  ensure_setup()
  local conv = new_conversation(name)
  show_conversation(conv)
  return conv
end

---Resume a detached conversation's wire session. On rejection the session
---continues fresh under the same name with a new wire id; on success the
---runtime reattaches with the model-side context intact (the transcript
---starts empty — no history read on the wire yet).
---@param conv table
local function resume_conversation(conv)
  M._ensure_runtime()
  conv.resume_state = "resuming"
  state.runtime:resume(conv.id, function(_, err)
    if err then
      state.by_id[conv.id] = nil
      conv.id = ("ndsh-%d-%d"):format(state.seq, math.random(100000))
      state.by_id[conv.id] = conv
      conv.resume_state = "live"
      conv:apply_op({ op = "notice", text = "previous session could not be resumed; starting fresh" })
      persist_save()
      conv:refresh_chrome()
      vim.notify(("ndsh: could not resume %q; starting fresh"):format(conv.name), vim.log.levels.WARN)
      return
    end
    conv.resume_state = "live"
    conv:apply_op({ op = "notice", text = "session resumed — the agent remembers; the transcript starts here" })
    persist_save()
    conv:refresh_chrome()
  end)
end

---Jump to a conversation in the panel (:NDSHSessions selection).
---@param conv table
local function goto_conversation(conv)
  if conv.resume_state == "detached" then
    resume_conversation(conv)
  end
  show_conversation(conv)
  conv:mark_read()
  if conv:is_open() then
    vim.fn.win_gotoid(conv.chat_win)
  end
  persist_save()
end

---Session navigator (:NDSHSessions), most recently active first.
function M.sessions()
  ensure_setup()
  if #state.conversations == 0 then
    vim.notify("ndsh: no sessions yet; :NDSHNew to create one", vim.log.levels.INFO)
    return
  end
  -- Shallow copy for sorting: deepcopied conversations would be distinct
  -- objects and opening one would detach it from the registry.
  local ordered = {}
  for i, conv in ipairs(state.conversations) do
    ordered[i] = conv
  end
  table.sort(ordered, function(a, b)
    return (state.activity[a.id] or 0) > (state.activity[b.id] or 0)
  end)
  sessions_ui.open(ordered, goto_conversation)
end

---Rename the active conversation (:NDSHRename and /rename).
---@param name string|nil prompts when nil
function M.rename(name)
  local conv = active_conversation()
  if name and name ~= "" then
    conv:rename(name)
    touch(conv)
    persist_save()
    return
  end
  vim.ui.input({ prompt = "Session name: ", default = conv.name }, function(text)
    if text and text ~= "" then
      conv:rename(text)
      touch(conv)
      persist_save()
    end
  end)
end

---Delete a conversation (:NDSHDelete): confirm, then remove it from the
---registry, wipe its transcript buffers, and drop its persisted record.
---The wire session keeps running in the runtime until the next restart —
---the SDK has no session/close (see docs/upstream-sdk-plan.md).
---@param target table|nil defaults to the active conversation
function M.delete_session(target)
  ensure_setup()
  local conv = target or state.active
  if not conv then
    vim.notify("ndsh: no session to delete", vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "Delete", "Cancel" }, {
    prompt = ("ndsh: delete session %q? The transcript cannot be recovered."):format(conv.name),
  }, function(choice)
    if choice ~= "Delete" then
      return
    end
    M._delete_conversation(conv)
  end)
end

---@param conv table
function M._delete_conversation(conv)
  if conv:is_open() then
    conv:hide()
  end
  for _, buf in ipairs({ conv.chat_buf, conv.input_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state.by_id[conv.id] = nil
  state.activity[conv.id] = nil
  for i, c in ipairs(state.conversations) do
    if c == conv then
      table.remove(state.conversations, i)
      break
    end
  end
  if state.active == conv then
    state.active = nil
    -- Fall back to the most recently active remaining conversation.
    local best, best_stamp = nil, -1
    for _, c in ipairs(state.conversations) do
      local stamp = state.activity[c.id] or 0
      if stamp > best_stamp then
        best, best_stamp = c, stamp
      end
    end
    if best then
      goto_conversation(best)
    end
  end
  persist_save()
  vim.notify(("ndsh: session %q deleted"):format(conv.name), vim.log.levels.INFO)
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
  -- No runtime resolvable anywhere: offer the managed bootstrap once, then
  -- retry. Declining falls through on the next call and reports the plain
  -- "no dsh executable" error pointing at :NDSHInstallRuntime.
  if not Runtime.resolve_cmd(state.cfg) and not state.bootstrap_offered then
    state.bootstrap_offered = true
    require("ndsh.bootstrap").ensure(state.cfg, function(ok)
      if ok then
        M._ensure_runtime()
      end
    end)
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
      if conn == "stopped" or conn == "error" then
        -- A dead runtime runs nothing: any turn in flight when it stopped
        -- is over, and no session.status will arrive to say so.
        for _, conv in ipairs(state.conversations) do
          conv:set_status("idle")
        end
      else
        for _, conv in ipairs(state.conversations) do
          conv:refresh_chrome()
        end
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

---Install the managed runtime (:NDSHInstallRuntime): a pinned Node.js +
---@deepseek-ai/dsh under stdpath("data")/ndsh/bootstrap, then connect.
function M.install_runtime()
  ensure_setup()
  require("ndsh.bootstrap").install(state.cfg, function(ok, err)
    if ok then
      M.restart_session()
    else
      vim.notify("ndsh: runtime install failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
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
