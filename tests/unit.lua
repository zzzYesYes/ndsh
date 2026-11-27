--- Unit tests for the transport and protocol layers (no process spawned).
--- Run from the repo root:
---   nvim --headless -u NONE --cmd "set rtp+=." -l tests/unit.lua
local failures = 0
local function check(name, cond)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name)
  end
end

local job = require("ndsh.job")
local Protocol = require("ndsh.protocol")

-- Framing: jobstart delivers line-split lists; the first item continues the
-- previous chunk's partial line and only the last item may be partial.
do
  local frames = {}
  local feed = job.framer(function(line)
    frames[#frames + 1] = line
  end)
  feed({ '{"a":1', '{"b":2}', '{"c"' }) -- 2 complete frames, third partial
  feed({ ':3}', '' }) -- completes the third frame
  check("framing across chunks", vim.deep_equal(frames, { '{"a":1', '{"b":2}', '{"c":3}' }))

  local frames2 = {}
  local feed2 = job.framer(function(line)
    frames2[#frames2 + 1] = line
  end)
  feed2({ "one", "two", "three", "" }) -- empty tail: all complete
  check("framing multiple complete lines", vim.deep_equal(frames2, { "one", "two", "three" }))
end

-- Protocol request/response correlation and error mapping.
do
  local sent = {}
  local proto = Protocol.new({
    send = function(line)
      sent[#sent + 1] = vim.json.decode(line)
    end,
  }, {
    on_notification = function() end,
    on_request = function() end,
  })

  local got_result, got_err
  proto:request("initialize", { cwd = "/x" }, function(result, err)
    got_result, got_err = result, err
  end)
  check("request encodes method and id", sent[1].method == "initialize" and sent[1].id == 1 and sent[1].params.cwd == "/x")
  proto:handle_line(vim.json.encode({ jsonrpc = "2.0", id = 1, result = { serverInfo = { name = "n", version = "v" } } }))
  check("response resolves pending request", got_result and got_result.serverInfo.name == "n" and got_err == nil)

  proto:request("boom", nil, function(result, err)
    got_result, got_err = result, err
  end)
  proto:handle_line(vim.json.encode({ jsonrpc = "2.0", id = 2, error = { code = -32603, message = "bad" } }))
  check("error response rejects pending request", got_err and got_err.code == -32603)

  -- Notification dispatch.
  local notified
  proto.handlers.on_notification = function(method, params)
    notified = { method = method, params = params }
  end
  proto:handle_line(vim.json.encode({ jsonrpc = "2.0", method = "session.status", params = { status = "running" } }))
  check("notification dispatched", notified and notified.method == "session.status" and notified.params.status == "running")

  -- Malformed lines are ignored.
  proto:handle_line("this is not json")
  check("malformed line ignored", true)

  -- Async server request: respond later, answer carries our result.
  sent = {}
  local respond_fn
  proto.handlers.on_request = function(_, _, respond)
    respond_fn = respond
  end
  proto:handle_line(vim.json.encode({ jsonrpc = "2.0", id = "srv-9", method = "approval/request", params = { toolName = "bash" } }))
  check("server request defers response", #sent == 0 and respond_fn ~= nil)
  respond_fn({ outcome = "allowed-once" })
  check("async response encoded", sent[1].id == "srv-9" and sent[1].result.outcome == "allowed-once")

  -- fail_all rejects everything pending.
  local failed = 0
  proto:request("a", nil, function(_, err)
    if err then
      failed = failed + 1
    end
  end)
  proto:request("b", nil, function(_, err)
    if err then
      failed = failed + 1
    end
  end)
  proto:fail_all({ code = -32000, message = "dead" })
  check("fail_all rejects pending requests", failed == 2)
end

-- Projection against real wire shapes.
do
  local projection = require("ndsh.projection")
  local ops = projection.project({
    type = "assistant/message",
    data = { turn = 1, step = 1, message = { content = { { type = "reasoning", text = "hidden" }, { type = "text", text = "shown" } } } },
  })
  check(
    "assistant text extracted, reasoning becomes its own op",
    ops[1].op == "reasoning" and ops[3].op == "append" and ops[3].text == "shown"
  )

  local synthetic = projection.project({
    type = "user/message",
    data = { content = { { type = "text", text = "hello" } }, source = { kind = "user" } },
  })
  check("wire user/message not rendered (echoed locally at send)", #synthetic == 0)

  local failed = projection.project({
    type = "turn/end",
    data = { turn = 1, reason = { kind = "error", error = { message = "model exploded" } } },
  })
  check(
    "failed turn surfaces error op",
    failed[1].op == "status" and failed[2] ~= nil and failed[2].op == "error" and failed[2].text:find("model exploded", 1, true) ~= nil
  )

  local call = projection.project({
    type = "tool/call",
    data = { callId = "c", name = "bash", arguments = '{\n  "command": "ls"\n}' },
  })
  check("tool call summary is one line", call[1].summary == '{ "command": "ls" }')

  local mode = projection.project({ type = "plan/mode", data = { active = true } })
  check("plan/mode projects a mode op", #mode == 1 and mode[1].op == "mode" and mode[1].active == true)

  local with_usage = projection.project({
    type = "assistant/message",
    data = {
      turn = 1,
      step = 1,
      message = { content = { { type = "text", text = "hi" } } },
      usage = { inputTokens = 1000, outputTokens = 10 },
    },
  })
  check(
    "assistant usage projects usage op",
    with_usage[#with_usage].op == "usage" and with_usage[#with_usage].input == 1000
  )

  local route = projection.project({
    type = "request/context",
    data = { provider = "p", model = "m", contextWindow = 128000 },
  })
  check(
    "request/context projects route op",
    route[1].op == "route" and route[1].model == "m" and route[1].window == 128000
  )

  local with_reasoning = projection.project({
    type = "assistant/message",
    data = {
      turn = 1,
      step = 1,
      message = {
        content = {
          { type = "reasoning", text = "let me think" },
          { type = "reasoning", text = "  " },
          { type = "text", text = "answer" },
        },
      },
    },
  })
  check(
    "readable reasoning projects a reasoning op first",
    with_reasoning[1].op == "reasoning"
      and with_reasoning[1].text == "let me think"
      and with_reasoning[2].op == "begin_message"
  )

  local encrypted_only = projection.project({
    type = "assistant/message",
    data = {
      turn = 1,
      step = 1,
      message = { content = { { type = "reasoning", text = "" }, { type = "text", text = "answer" } } },
    },
  })
  check("encrypted/empty reasoning is skipped", encrypted_only[1].op == "begin_message")
end

-- Credential store roundtrip and file permissions.
do
  local credentials = require("ndsh.credentials")
  local path = vim.fn.tempname() .. "/credentials.json"
  credentials.set("deepseek-official", { env = { DEEPSEEK_API_KEY = "sk-test" }, model = "deepseek-v4-flash" }, path)
  credentials.set("anthropic", { env = { ANTHROPIC_API_KEY = "sk-ant" }, model = "claude-sonnet-4-5" }, path)
  local entry = credentials.get("deepseek-official", path)
  check("credentials roundtrip", entry ~= nil and entry.env.DEEPSEEK_API_KEY == "sk-test" and entry.model == "deepseek-v4-flash")
  check(
    "credentials env_for",
    credentials.env_for("anthropic", path).ANTHROPIC_API_KEY == "sk-ant" and next(credentials.env_for("unknown", path)) == nil
  )
  local perms = vim.fn.getfperm(path)
  check("credentials file is owner-only", perms == "rw-------")

  credentials.set_current("anthropic", "claude-sonnet-4-5", path)
  local current = credentials.current(path)
  check(
    "current route roundtrip",
    current ~= nil and current.provider == "anthropic" and current.model == "claude-sonnet-4-5"
  )
  check(
    "set_current syncs provider model",
    credentials.get("anthropic", path).model == "claude-sonnet-4-5"
  )
  check(
    "current ignores credential entries",
    credentials.current(path).provider ~= "deepseek-official"
  )
  vim.fn.delete(vim.fn.fnamemodify(path, ":h"), "rf")
end

-- Local slash command registry.
do
  local commands = require("ndsh.commands")
  check("commands.names includes rename", vim.tbl_contains(commands.names(), "rename"))
  local renamed
  local conv = {
    rename = function(_, name)
      renamed = name
    end,
  }
  check("run handles /rename", commands.run(conv, "/rename work") and renamed == "work")
  check("run passes unknown commands through", not commands.run(conv, "/compact please"))
  check("run passes ordinary text through", not commands.run(conv, "hello /rename"))
  check(
    "wire commands pass through untouched",
    not commands.run(conv, "/compact") and not commands.run(conv, "/goal finish this")
  )
  check(
    "wire_names mirrors the sdk-profile command set",
    table.concat(commands.wire_names(), ",") == "compact,goal,plan"
  )
  -- Completion: silent off-slash, completes after "/".
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "plain text" })
  check("completion silent off slash", commands.complete(1, "") == -2)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "/re" })
  check(
    "completion starts after the slash",
    commands.complete(1, "re") == 0
  )
  local items = commands.complete(0, "re")
  check(
    "completion offers local command",
    #items == 1 and items[1].word == "rename" and items[1].menu == "[local]"
  )
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "/p" })
  local words = {}
  for _, item in ipairs(commands.complete(0, "p")) do
    words[#words + 1] = item.word
  end
  table.sort(words)
  check("completion offers wire commands", table.concat(words, ",") == "plan")
end

-- Spinner: a running conversation shows the animated frame in its winbar.
do
  local config = require("ndsh.config")
  local Conversation = require("ndsh.conversation")
  local cfg = config.resolve({ restore = "scratch" })
  local frames = { "|", "/", "-", "\\" }
  local frame_idx = 1
  local conv = Conversation.new(cfg, { id = "unit-1", name = "unit" }, {
    on_send = function() end,
    should_quit = function() return false end,
    restore = function() end,
    conn_state = function()
      return "ready"
    end,
    spinner_frame = function()
      return frames[frame_idx]
    end,
    status_changed = function() end,
  })
  conv:open()
  conv:set_status("running")
  local winbar = vim.api.nvim_get_option_value("winbar", { win = conv.input_win })
  check("spinner frame shown while running", winbar:find(" ndsh · |", 1, true) ~= nil)
  frame_idx = 2
  conv:refresh_chrome()
  winbar = vim.api.nvim_get_option_value("winbar", { win = conv.input_win })
  check("spinner frame advances", winbar:find(" ndsh · /", 1, true) ~= nil)
  conv:set_status("idle")
  winbar = vim.api.nvim_get_option_value("winbar", { win = conv.input_win })
  check("idle restores word status", winbar:find(" ndsh · idle", 1, true) ~= nil)
  conv:hide()
end

-- Session registry persistence roundtrip.
do
  local persist = require("ndsh.persist")
  local config = require("ndsh.config")
  local dir = vim.fn.tempname()
  local cfg = config.resolve({ store_path = dir .. "/credentials.json" })
  persist.save(cfg, { { id = "wire-1", name = "old chat", created = 100, last_active = 200, cwd = "/proj" } })
  local loaded = persist.load(cfg)
  check(
    "persist roundtrip",
    #loaded == 1
      and loaded[1].id == "wire-1"
      and loaded[1].name == "old chat"
      and loaded[1].last_active == 200
      and loaded[1].cwd == "/proj"
  )
  persist.save_transcript(cfg, "wire-1", { "❯ You", "hello", "", "● ndsh", "hi" })
  local transcript = persist.load_transcript(cfg, "wire-1")
  check(
    "transcript roundtrip",
    transcript ~= nil and #transcript == 5 and transcript[1] == "❯ You" and transcript[5] == "hi"
  )
  persist.delete_transcript(cfg, "wire-1")
  check("transcript deleted", persist.load_transcript(cfg, "wire-1") == nil)
  local empty = persist.load(config.resolve({ store_path = vim.fn.tempname() .. "/c.json" }))
  check("persist empty when file missing", #empty == 0)
  vim.fn.delete(dir, "rf")
end

-- Provider balance adapters parse provider-specific payloads.
do
  local api = require("ndsh.provider_api")
  local ds = api.balance_adapters["deepseek-official"].parse({
    balance_infos = { { currency = "CNY", total_balance = "23.97", granted_balance = "0.00", topped_up_balance = "23.97" } },
  })
  check("deepseek balance adapter", ds == "23.97 CNY (topped-up 23.97)")
  local kimi = api.balance_adapters.moonshotai.parse({
    data = { available_balance = 49.58894, voucher_balance = 46.58893, cash_balance = 3.00001 },
  })
  check("kimi balance adapter", kimi == "$49.59 (cash $3.00, voucher $46.59)")
  check(
    "balance adapters reject junk",
    api.balance_adapters.moonshotai.parse({}) == nil and api.balance_adapters["deepseek-official"].parse({}) == nil
  )
end

-- pi-ai route management: routes.json drives the managed patch block.
do
  local routes = require("ndsh.routes")
  local config = require("ndsh.config")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.env.DSH_HOME = dir
  local cfg = config.resolve({ store_path = dir .. "/credentials.json" })
  local patch_file = dir .. "/profiles/sdk/cordis.patch.yml"

  local kimi_route = {
    id = "moonshotai",
    defaultContextWindow = 262144,
    models = { { id = "kimi-k2-0905-preview" } },
  }
  check("ensure_route writes the managed block", routes.ensure_route(cfg, kimi_route) == true)
  local patch = table.concat(vim.fn.readfile(patch_file), "\n")
  check(
    "patch contains the route",
    patch:find("moonshotai", 1, true) ~= nil and patch:find("ndsh:managed%-routes") ~= nil
  )
  check("ensure_route is idempotent", routes.ensure_route(cfg, kimi_route) == false)

  -- Foreign content survives; the managed block is replaced wholesale.
  local lines = vim.fn.readfile(patch_file)
  table.insert(lines, 1, "# user header")
  vim.fn.writefile(lines, patch_file)
  check("ensure_model appends to a managed route", routes.ensure_model(cfg, "moonshotai", "kimi-k2-thinking") == true)
  patch = table.concat(vim.fn.readfile(patch_file), "\n")
  check("user content preserved", patch:find("# user header", 1, true) ~= nil)
  check("model appended to the route", patch:find("kimi-k2-thinking", 1, true) ~= nil)
  check("is_route", routes.is_route(cfg, "moonshotai") and not routes.is_route(cfg, "openai"))

  vim.env.DSH_HOME = nil
  vim.fn.delete(dir, "rf")
end

if failures > 0 then
  print(("%d check(s) failed"):format(failures))
  vim.cmd("cquit 1")
end
print("all unit checks passed")
vim.cmd("quitall!")
