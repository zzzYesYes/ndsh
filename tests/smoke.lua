--- Headless smoke test for the ndsh frame. Run from the repo root:
---   nvim --headless -u NONE --cmd "set rtp+=." -l tests/smoke.lua
local failures = 0
local function check(name, cond)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name)
  end
end

local function find_chat_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_get_option_value("filetype", { buf = buf }) == "markdown" then
      return buf
    end
  end
  return nil
end

local ndsh = require("ndsh")

-- 1. Takeover layout: a fresh headless nvim has one empty window.
ndsh.setup({})
ndsh.open()
local wins = vim.api.nvim_tabpage_list_wins(0)
check("takeover: panel is 2 windows", #wins == 2)
check("takeover: panel is open", ndsh.is_open())

local chat_buf = find_chat_buf()
check("chat buffer exists with markdown filetype", chat_buf ~= nil)

local input_buf
for _, win in ipairs(wins) do
  local b = vim.api.nvim_win_get_buf(win)
  if b ~= chat_buf then
    input_buf = b
  end
end
check("input buffer exists", input_buf ~= nil)
if input_buf then
  check(
    "input window height is fixed at 6",
    vim.api.nvim_win_get_height(vim.fn.bufwinid(input_buf)) == 6
  )
  check(
    "input window has status winbar",
    vim.api.nvim_get_option_value("winbar", { win = vim.fn.bufwinid(input_buf) }):find("ndsh") ~= nil
  )
end

-- 2. Feed events through the real projection path, synchronously.
ndsh._apply_event({ type = "turn/start" })
ndsh._apply_event({ type = "user/message", content = "hello ndsh" })
ndsh._apply_event({
  type = "assistant/message",
  content = { { type = "text", text = "hi. running a command:\n\n```sh\nls\n```" } },
})
ndsh._apply_event({ type = "tool/call", callId = "c1", name = "bash", summary = "ls -la" })
ndsh._apply_event({ type = "tool/result", callId = "c1", isError = false, output = "a\nb\nc" })
ndsh._apply_event({ type = "turn/end" })

local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
local text = table.concat(lines, "\n")
check("user header rendered", text:find("❯ You", 1, true) ~= nil)
check("user message rendered", text:find("hello ndsh", 1, true) ~= nil)
check("assistant header rendered", text:find("● ndsh", 1, true) ~= nil)
check("assistant markdown rendered", text:find("```sh", 1, true) ~= nil)
check("tool line completed with ✓", text:find("✓ bash · ls %-la") ~= nil)
check("tool output rendered", text:find("  │ a", 1, true) ~= nil)

-- 3. The tool result must be folded closed in the chat window.
local chat_win = vim.fn.bufwinid(chat_buf)
local fold_ok = vim.api.nvim_win_call(chat_win, function()
  for lnum = 1, vim.api.nvim_buf_line_count(chat_buf) do
    if vim.fn.foldclosed(lnum) ~= -1 then
      return true
    end
  end
  return false
end)
check("tool result folded closed", fold_ok)

-- 4. Close in takeover mode restores a single empty window.
ndsh.close()
wins = vim.api.nvim_tabpage_list_wins(0)
check("takeover close: back to 1 window", #wins == 1)
local only_buf = vim.api.nvim_win_get_buf(wins[1])
check(
  "takeover close: remaining window is empty scratch",
  vim.api.nvim_buf_get_name(only_buf) == ""
)

-- 5. With a code buffer up, the panel docks right (3 windows) instead.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
ndsh.open()
wins = vim.api.nvim_tabpage_list_wins(0)
check("docked: code + panel = 3 windows", #wins == 3)
ndsh.close()
wins = vim.api.nvim_tabpage_list_wins(0)
check("docked close: only code window remains", #wins == 1)

if failures > 0 then
  print(("%d check(s) failed"):format(failures))
  vim.cmd("cquit 1")
end
print("all checks passed")
vim.cmd("quitall!")
