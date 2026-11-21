--- Session layer: owns the runtime job, the initialize handshake, the
--- prompt path, and routing of wire notifications/requests to UI callbacks.
local Job = require("ndsh.job")
local Protocol = require("ndsh.protocol")

local M = {}
M.__index = M

---Resolve the runtime argv: explicit dsh.cmd, an installed dsh, or the
---source checkout used for development.
---@param cfg table
---@return string[]|nil cmd, string|nil err
local function resolve_cmd(cfg)
  if cfg.dsh.cmd then
    return cfg.dsh.cmd
  end
  if vim.fn.exepath("dsh") ~= "" then
    return { "dsh", "--profile", cfg.dsh.profile }
  end
  local checkout = vim.fn.expand("~/workspace/deepseek-harness")
  if vim.fn.isdirectory(checkout) == 1 then
    local pnpm = vim.fn.exepath("pnpm")
    if pnpm == "" then
      -- Common standalone install location outside PATH.
      local candidate = vim.fn.expand("~/.local/share/pnpm/bin/pnpm")
      if vim.fn.executable(candidate) == 1 then
        pnpm = candidate
      end
    end
    if pnpm ~= "" then
      return { pnpm, "-C", checkout, "dsh", "--profile", cfg.dsh.profile }
    end
  end
  return nil, "no dsh executable found; set dsh.cmd in setup()"
end

---@class NdsSessionCallbacks
---@field on_event fun(event: table) session-log event for our session
---@field on_status fun(status: string) "running"|"idle"
---@field on_state fun(state: string) "starting"|"ready"|"error"|"stopped"
---@field on_notify fun(msg: string, level: integer)
---@field on_approval fun(params: table, respond: fun(result: any|nil, err: table|nil))
---@field on_user_question fun(params: table, respond: fun(result: any|nil, err: table|nil))

---@param cfg table resolved ndsh config
---@param cb NdsSessionCallbacks
function M.new(cfg, cb)
  return setmetatable({
    cfg = cfg,
    cb = cb,
    state = "stopped",
    session_id = ("ndsh-%d-%d"):format(os.time(), math.random(100000)),
    queue = {}, ---@type string[] prompts sent before ready
    log = {}, ---@type string[] stderr ring buffer for :NDSHLog
    job = nil,
    protocol = nil,
  }, M)
end

local function set_state(self, state)
  self.state = state
  self.cb.on_state(state)
end

function M:_on_exit(code)
  if self.protocol then
    self.protocol:fail_all({ code = -32000, message = "runtime exited (code " .. tostring(code) .. ")" })
  end
  if self.stopping then
    -- Intentional kill from stop(): quiet teardown, not an error.
    self.stopping = false
    set_state(self, "stopped")
    return
  end
  set_state(self, "error")
  self.cb.on_notify("ndsh: runtime exited (code " .. tostring(code) .. "); :NDSHRestart to respawn", vim.log.levels.ERROR)
end

function M:_notification(method, params)
  if method == "session.event" then
    if params and params.sessionId == self.session_id then
      self.cb.on_event(params.event)
    end
  elseif method == "session.status" then
    if params and params.sessionId == self.session_id then
      self.cb.on_status(params.status)
    end
  end
end

function M:_request(method, params, respond)
  if method == "approval/request" then
    self.cb.on_approval(params, respond)
  elseif method == "user-question/ask" then
    self.cb.on_user_question(params, respond)
  else
    respond(nil, { code = -32601, message = "ndsh: unsupported server request " .. method })
  end
end

function M:start()
  if self.state == "starting" or self.state == "ready" then
    return
  end
  local cmd, err = resolve_cmd(self.cfg)
  if not cmd then
    set_state(self, "error")
    self.cb.on_notify("ndsh: " .. err, vim.log.levels.ERROR)
    return
  end
  set_state(self, "starting")
  local ok, job_or_err = pcall(Job.spawn, cmd, {
    on_frame = function(line)
      -- Frames can arrive after stop() tore the protocol down.
      if self.protocol then
        self.protocol:handle_line(line)
      end
    end,
    on_stderr = function(line)
      -- Runtime logs are noisy by nature (boot warnings, provider traces);
      -- keep a ring buffer for :NDSHLog instead of notifying every line.
      self.log[#self.log + 1] = line
      if #self.log > 200 then
        table.remove(self.log, 1)
      end
    end,
    on_exit = function(code)
      self:_on_exit(code)
    end,
  })
  if not ok then
    set_state(self, "error")
    self.cb.on_notify(tostring(job_or_err), vim.log.levels.ERROR)
    return
  end
  self.job = job_or_err
  self.protocol = Protocol.new({
    send = function(line)
      self.job:send(line)
    end,
  }, {
    on_notification = function(method, params)
      self:_notification(method, params)
    end,
    on_request = function(method, params, respond)
      self:_request(method, params, respond)
    end,
  })
  local init = {
    cwd = vim.uv.cwd(),
    provider = self.cfg.dsh.provider,
    model = self.cfg.dsh.model,
    approvalRequests = self.cfg.dsh.approval,
    capabilities = { userQuestions = self.cfg.dsh.user_questions },
  }
  if self.cfg.dsh.reasoning_effort then
    init.reasoningEffort = self.cfg.dsh.reasoning_effort
  end
  if self.cfg.dsh.max_tokens then
    init.maxTokens = self.cfg.dsh.max_tokens
  end
  self.protocol:request("initialize", init, function(_, init_err)
    if init_err then
      set_state(self, "error")
      self.cb.on_notify("ndsh: initialize failed: " .. vim.inspect(init_err), vim.log.levels.ERROR)
      return
    end
    set_state(self, "ready")
    local queue = self.queue
    self.queue = {}
    for _, text in ipairs(queue) do
      self:send(text)
    end
  end)
end

---Queue or send one user prompt.
---@param text string
function M:send(text)
  if self.state == "error" or self.state == "stopped" then
    self.cb.on_notify("ndsh: runtime not running; use :NDSHRestart", vim.log.levels.WARN)
    return
  end
  if self.state ~= "ready" then
    self.queue[#self.queue + 1] = text
    return
  end
  self.protocol:request("session/query", {
    sessionId = self.session_id,
    contentBlocks = { { type = "text", text = text } },
  }, function(_, err)
    if err then
      self.cb.on_notify("ndsh: prompt rejected: " .. vim.inspect(err), vim.log.levels.ERROR)
    end
  end)
end

---Captured stderr lines (ring buffer, newest last).
---@return string[]
function M:logs()
  return self.log
end

function M:stop()
  if self.job then
    self.stopping = true
    self.job:kill()
    self.job = nil
  end
  if self.protocol then
    self.protocol:fail_all({ code = -32000, message = "stopped" })
    self.protocol = nil
  end
  if self.state ~= "stopped" then
    set_state(self, "stopped")
  end
end

function M:restart()
  self:stop()
  self:start()
end

return M
