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
  check("assistant text extracted, reasoning skipped", ops[2].op == "append" and ops[2].text == "shown")

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
  vim.fn.delete(vim.fn.fnamemodify(path, ":h"), "rf")
end

if failures > 0 then
  print(("%d check(s) failed"):format(failures))
  vim.cmd("cquit 1")
end
print("all unit checks passed")
vim.cmd("quitall!")
