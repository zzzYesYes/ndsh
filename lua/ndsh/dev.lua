--- Dev harness: feeds a scripted session through the real projection and
--- writer path so rendering can be iterated on without a live dsh runtime.
local M = {}

local ASSISTANT_INTRO = table.concat({
  "I'll list the directory contents and show you what's here.",
  "",
  "Let me run a quick `ls`:",
}, "\n")

local ASSISTANT_OUTRO = table.concat({
  "The workspace contains two entries:",
  "",
  "- `deepseek-harness/` — the dsh monorepo",
  "- `ndsh/` — this plugin",
  "",
  "Here's a Lua snippet while we're at it:",
  "",
  "```lua",
  "local ndsh = require('ndsh')",
  "ndsh.toggle()",
  "```",
}, "\n")

local LS_OUTPUT = table.concat({
  "total 8",
  "drwxr-xr-x  8 zzz zzz 260 Nov 21 10:00 deepseek-harness",
  "drwxr-xr-x  4 zzz zzz 120 Nov 21 10:01 ndsh",
}, "\n")

local READ_OUTPUT = table.concat({
  "  1  local M = {}",
  "  2",
  "  3  function M.greet()",
  "  4    print('hello from ndsh')",
  "  5  end",
  "  6",
  "  7  return M",
}, "\n")

---Scripted event timeline. Each entry is { delay_ms, event }.
local script = {
  { 100, { type = "turn/start" } },
  {
    300,
    { type = "user/message", content = "what's in my workspace? also show me a lua snippet." },
  },
  {
    700,
    {
      type = "assistant/message",
      content = { { type = "text", text = ASSISTANT_INTRO } },
    },
  },
  {
    500,
    { type = "tool/call", callId = "call_1", name = "bash", summary = "ls -la ~/workspace" },
  },
  {
    1200,
    { type = "tool/result", callId = "call_1", isError = false, output = LS_OUTPUT },
  },
  {
    600,
    { type = "tool/call", callId = "call_2", name = "read_file", summary = "ndsh/lua/hello.lua" },
  },
  {
    900,
    { type = "tool/result", callId = "call_2", isError = false, output = READ_OUTPUT },
  },
  {
    800,
    {
      type = "assistant/message",
      content = { { type = "text", text = ASSISTANT_OUTRO } },
    },
  },
  { 200, { type = "turn/end" } },
}

---Play the demo timeline against the live panel.
function M.run()
  local ndsh = require("ndsh")
  ndsh.open()
  local elapsed = 0
  for _, step in ipairs(script) do
    elapsed = elapsed + step[1]
    local event = step[2]
    vim.defer_fn(function()
      ndsh._apply_event(event)
    end, elapsed)
  end
  vim.defer_fn(function()
    vim.notify("ndsh demo complete", vim.log.levels.INFO)
  end, elapsed + 100)
end

return M
