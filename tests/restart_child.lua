--- Child fixture for tests/restart.lua; not run directly. Driven twice with
--- a shared sandboxed XDG_DATA_HOME:
---   nvim --headless -u NONE --cmd "set rtp+=." -l tests/restart_child.lua create
---   nvim --headless -u NONE --cmd "set rtp+=." -l tests/restart_child.lua check
local phase = _G.arg and _G.arg[1]
local ndsh = require("ndsh")
local failed = false
local function check(name, cond)
  print((cond and "ok   - " or "FAIL - ") .. name)
  if not cond then
    failed = true
  end
end

-- The sandbox has no dsh runtime; decline the bootstrap offer.
vim.ui.select = function(_, _, cb)
  cb(nil)
end
ndsh.setup({ restore = "scratch", dsh = { auto_connect = false } })

if phase == "create" then
  ndsh.new_session("restart-test")
  ndsh._apply_event({ type = "turn/start", data = { turn = 1 } })
  ndsh._on_send("hello restart")
  ndsh._apply_event({
    type = "assistant/message",
    data = { turn = 1, step = 1, message = { content = { { type = "text", text = "persisted answer" } } } },
  })
  ndsh._apply_event({ type = "turn/end", data = { turn = 1, reason = "complete" } })
  -- VimLeavePre persists the transcript on the way out.
  vim.schedule(function()
    vim.cmd("quitall!")
  end)
  return
end

-- phase == "check": the first process's session must be back.
local entries = require("ndsh.persist").load(require("ndsh.config").resolve({}))
check("registry persisted across restart", #entries == 1 and entries[1].name == "restart-test")
check("registry records the session cwd", entries[1] ~= nil and entries[1].cwd == vim.uv.cwd())

ndsh.resume_last()
vim.schedule(function()
  check("resume_last opened the panel", ndsh.is_open())
  local chat_buf
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_get_option_value("filetype", { buf = buf }) == "ndsh" then
      chat_buf = buf
    end
  end
  local text = chat_buf and table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n") or ""
  check("transcript restored", text:find("persisted answer", 1, true) ~= nil)
  check("user echo restored", text:find("hello restart", 1, true) ~= nil)
  -- No runtime resolvable in the sandbox: fresh-start notice, not a hang.
  check("fresh-start notice instead of a stuck resume", text:find("starting fresh", 1, true) ~= nil)
  vim.cmd(failed and "cquit 1" or "quitall!")
end)
