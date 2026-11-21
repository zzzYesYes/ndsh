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
-- auto_connect off: the frame smoke must not spawn a real runtime.
ndsh.setup({ restore = "scratch", dsh = { auto_connect = false } })
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
    vim.api.nvim_win_get_height(vim.fn.bufwinid(input_buf)) == 8
  )
  check(
    "input window has a statusline",
    vim.api.nvim_get_option_value("statusline", { win = vim.fn.bufwinid(input_buf) }):find("ndsh") ~= nil
  )
end

-- 2. Feed events through the real projection path, synchronously. The user
-- prompt takes the local echo path (wire user/message is not rendered).
ndsh._apply_event({ type = "turn/start", data = { turn = 1 } })
ndsh._on_send("hello ndsh")
ndsh._apply_event({
  type = "assistant/message",
  data = {
    turn = 1,
    step = 1,
    message = { content = { { type = "text", text = "hi. running a command:\n\n```sh\nls\n```" } } },
  },
})
ndsh._apply_event({
  type = "tool/call",
  data = { turn = 1, step = 1, callId = "c1", name = "bash", arguments = '{"command":"ls -la"}' },
})
ndsh._apply_event({
  type = "tool/result",
  data = {
    turn = 1,
    step = 1,
    message = { toolCallId = "c1", content = { { type = "text", text = "a\nb\nc" } }, isError = false },
  },
})
ndsh._apply_event({ type = "turn/end", data = { turn = 1, reason = "complete" } })

local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
local text = table.concat(lines, "\n")
check("user header rendered", text:find("❯ You", 1, true) ~= nil)
check("user message rendered", text:find("hello ndsh", 1, true) ~= nil)
check("assistant header rendered", text:find("● ndsh", 1, true) ~= nil)
check("assistant markdown rendered", text:find("```sh", 1, true) ~= nil)
check("tool line completed with ✓", text:find('✓ bash · %{"command":"ls %-la"%}') ~= nil)
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

-- 4. Close in takeover mode with restore="scratch" leaves an empty window.
ndsh.close()
wins = vim.api.nvim_tabpage_list_wins(0)
check("takeover close: back to 1 window", #wins == 1)
local only_buf = vim.api.nvim_win_get_buf(wins[1])
check(
  "takeover close: remaining window is empty scratch",
  vim.api.nvim_buf_get_name(only_buf) == ""
)

-- 4b. A custom restore hook runs in the surviving window.
ndsh.setup({
  restore = function(win)
    vim.api.nvim_buf_set_name(vim.api.nvim_win_get_buf(win), "restored-marker")
  end,
  dsh = { auto_connect = false },
})
ndsh.open()
ndsh.close()
wins = vim.api.nvim_tabpage_list_wins(0)
check("restore hook: single window survives", #wins == 1)
check(
  "restore hook: ran in surviving window",
  vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(wins[1])):find("restored%-marker$") ~= nil
)
vim.cmd("bwipeout!")
ndsh.setup({ restore = "scratch", dsh = { auto_connect = false } })

-- 5. With a code buffer up, the panel docks right (3 windows) instead.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
ndsh.open()
wins = vim.api.nvim_tabpage_list_wins(0)
check("docked: code + panel = 3 windows", #wins == 3)
ndsh.close()
wins = vim.api.nvim_tabpage_list_wins(0)
check("docked close: only code window remains", #wins == 1)

-- 6. A dashboard-style nofile buffer also counts as "no code buffer up".
vim.cmd("enew")
local dash = vim.api.nvim_get_current_buf()
vim.api.nvim_set_option_value("buftype", "nofile", { buf = dash })
vim.api.nvim_buf_set_name(dash, "dashboard")
ndsh.open()
wins = vim.api.nvim_tabpage_list_wins(0)
check("dashboard: panel takes over (2 windows)", #wins == 2)
ndsh.close()

-- 7. Explicit full mode always opens a dedicated tab, even from a
-- dashboard-style single window, so gt/gT always has somewhere to go.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
local tabs_before = #vim.api.nvim_list_tabpages()
ndsh.open({ full = true })
wins = vim.api.nvim_tabpage_list_wins(0)
check("full: panel is a full tab (2 windows)", #wins == 2)
check("full: opened a new tabpage", #vim.api.nvim_list_tabpages() == tabs_before + 1)
ndsh.close()
check(
  "full close: tabpage restored",
  #vim.api.nvim_list_tabpages() == tabs_before and #vim.api.nvim_tabpage_list_wins(0) == 1
)
vim.cmd("enew")
vim.api.nvim_set_option_value("buftype", "nofile", { buf = 0 })
tabs_before = #vim.api.nvim_list_tabpages()
ndsh.open({ full = true })
check("full from dashboard: still a dedicated tab", #vim.api.nvim_list_tabpages() == tabs_before + 1)
ndsh.close()
check("full from dashboard close: tab restored", #vim.api.nvim_list_tabpages() == tabs_before)

-- 7b. toggle_full: docked converts to full; pressed inside the full tab it
-- closes back out.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
ndsh.open()
check("toggle_full setup: docked 3 windows", #vim.api.nvim_tabpage_list_wins(0) == 3)
ndsh.toggle_full()
check("toggle_full: docked converts to full tab", #vim.api.nvim_list_tabpages() == 2 and #vim.api.nvim_tabpage_list_wins(0) == 2)
ndsh.toggle_full()
check("toggle_full: pressed inside closes back out", #vim.api.nvim_list_tabpages() == 1)

-- 8. Closing one panel window by hand tears the whole panel down.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
ndsh.open()
local chat_win = vim.fn.bufwinid(chat_buf)
local input_win_id = vim.fn.bufwinid(input_buf)
vim.api.nvim_win_close(chat_win, true)
vim.wait(100, function()
  return not vim.api.nvim_win_is_valid(input_win_id)
end)
check("manual :q on chat closes input too", not vim.api.nvim_win_is_valid(input_win_id))
check("panel reports closed", not ndsh.is_open())
local wins_after = #vim.api.nvim_tabpage_list_wins(0)
ndsh.open()
check("reopen after manual close: clean 3 windows", #vim.api.nvim_tabpage_list_wins(0) == 3)
ndsh.close()
check("final close: back to code window", #vim.api.nvim_tabpage_list_wins(0) == wins_after)

-- 9. Buffer navigation inside a panel window snaps the panel buffer back.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
ndsh.open()
local foreign = vim.api.nvim_create_buf(true, false)
local chat_win9 = vim.fn.bufwinid(chat_buf)
vim.api.nvim_win_set_buf(chat_win9, foreign)
vim.wait(200, function()
  return vim.api.nvim_win_get_buf(chat_win9) == chat_buf
end)
check("panel window snaps its buffer back", vim.api.nvim_win_get_buf(chat_win9) == chat_buf)

-- 10. Deleting a panel buffer tears the panel down; reopen rebuilds it.
vim.api.nvim_buf_delete(input_buf, { force = true })
vim.wait(200, function()
  return not ndsh.is_open()
end)
check("deleting a panel buffer closes the panel", not ndsh.is_open())
ndsh.open()
check("reopen rebuilds panel buffers", ndsh.is_open() and #vim.api.nvim_tabpage_list_wins(0) == 3)
ndsh.close()

-- 11. restore = "quit" (the default) exits Neovim when the closing panel
-- is the only pane left. Runs last: a successful close ends the process.
vim.cmd("enew")
ndsh.setup({ restore = "quit", dsh = { auto_connect = false } })
ndsh.open()
check("quit mode: panel takes over", ndsh.is_open())

if failures > 0 then
  print(("%d check(s) failed"):format(failures))
  vim.cmd("cquit 1")
end
print("all checks passed")
ndsh.close() -- should exit Neovim here
print("FAIL - quit mode did not exit Neovim")
vim.cmd("cquit 1")
