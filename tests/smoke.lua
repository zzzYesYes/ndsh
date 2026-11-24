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
    if vim.api.nvim_get_option_value("filetype", { buf = buf }) == "ndsh" then
      return buf
    end
  end
  return nil
end

local ndsh = require("ndsh")

-- Isolate the test from the user's real data dir: without store_path,
-- setup() restores persisted sessions and the checks below would see them.
local store_path = vim.fn.tempname() .. ".json"

-- No dsh runtime exists in the test environment, so opening the panel
-- triggers the managed-bootstrap offer; decline it without blocking.
vim.ui.select = function(_, _, cb)
  cb(nil)
end

-- 1. Takeover layout: a fresh headless nvim has one empty window.
-- auto_connect off: the frame smoke must not spawn a real runtime.
ndsh.setup({ restore = "scratch", store_path = store_path, dsh = { auto_connect = false } })
ndsh.open()
local wins = vim.api.nvim_tabpage_list_wins(0)
check("takeover: panel is 2 windows", #wins == 2)
check("takeover: panel is open", ndsh.is_open())

local chat_buf = find_chat_buf()
check("chat buffer exists with ndsh filetype", chat_buf ~= nil)

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
    "input window has status winbar",
    vim.api.nvim_get_option_value("winbar", { win = vim.fn.bufwinid(input_buf) }):find("ndsh") ~= nil
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

-- 3b. The message scanner enumerates the rendered transcript, newest
-- first; selecting an entry jumps the chat window to it. Telescope is
-- absent under -u NONE, so this exercises the vim.ui.select fallback.
local scanned = require("ndsh.ui.messages").scan(chat_buf)
check("scanner finds user, assistant and tool entries", #scanned == 3)
if #scanned == 3 then
  check("scanner newest first is the tool call", scanned[1].kind == "tool" and scanned[1].icon == "✓")
  check(
    "scanner assistant entry carries first line",
    scanned[2].kind == "assistant" and scanned[2].text:find("hi. running", 1, true) ~= nil
  )
  check(
    "scanner user entry carries the prompt",
    scanned[3].kind == "user" and scanned[3].text == "hello ndsh"
  )
  check("scanner user ordinal holds the message", scanned[3].ordinal:find("hello ndsh", 1, true) ~= nil)
  local decline = vim.ui.select
  vim.ui.select = function(items, _, cb)
    cb(items[#items]) -- oldest entry: the user prompt
  end
  ndsh.messages()
  vim.ui.select = decline
  check(
    "scanner jump lands on the user header",
    vim.api.nvim_win_get_cursor(vim.fn.bufwinid(chat_buf))[1] == scanned[3].lnum
  )
end

-- 3c. J/K in the message pane jump between transcript blocks; the maps are
-- buffer-local and never leak to the input pane or file buffers.
local chat_win3 = vim.fn.bufwinid(chat_buf)
local input_win3 = vim.fn.bufwinid(input_buf)
local function press(key)
  vim.api.nvim_win_call(chat_win3, function()
    vim.cmd("normal " .. key)
  end)
end
local function cursor_line()
  return vim.api.nvim_win_get_cursor(chat_win3)[1]
end
check(
  "J mapped in the message pane",
  vim.api.nvim_win_call(chat_win3, function()
    return vim.fn.maparg("J", "n") ~= ""
  end)
)
check(
  "J unmapped in the input pane",
  vim.api.nvim_win_call(input_win3, function()
    return vim.fn.maparg("J", "n") == ""
  end)
)
check(
  "K unmapped in the input pane",
  vim.api.nvim_win_call(input_win3, function()
    return vim.fn.maparg("K", "n") == ""
  end)
)
vim.api.nvim_win_set_cursor(chat_win3, { 1, 0 })
press("J")
check("J lands on the assistant header", cursor_line() == 4)
press("J")
check("J lands inside the tool output", cursor_line() == 12)
check(
  "tool output fold opened by the jump",
  vim.api.nvim_win_call(chat_win3, function()
    return vim.fn.foldclosed(12) == -1
  end)
)
press("J")
check("J wraps to the first block", cursor_line() == 1)
press("K")
check("K wraps back to the tool output", cursor_line() == 12)

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
  store_path = store_path,
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
ndsh.setup({ restore = "scratch", store_path = store_path, dsh = { auto_connect = false } })

-- 5. With a code buffer up, the panel docks right (3 windows) instead.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
ndsh.open()
wins = vim.api.nvim_tabpage_list_wins(0)
check("docked: code + panel = 3 windows", #wins == 3)
ndsh.close()
wins = vim.api.nvim_tabpage_list_wins(0)
check("docked close: only code window remains", #wins == 1)

-- 6. A dashboard-style nofile buffer also counts as "no code buffer up",
-- and closing the panel restores it instead of quitting or scratching.
vim.cmd("enew")
local dash = vim.api.nvim_get_current_buf()
vim.api.nvim_set_option_value("buftype", "nofile", { buf = dash })
vim.api.nvim_buf_set_name(dash, "dashboard")
ndsh.open()
wins = vim.api.nvim_tabpage_list_wins(0)
check("dashboard: panel takes over (2 windows)", #wins == 2)
ndsh.close()
wins = vim.api.nvim_tabpage_list_wins(0)
check("dashboard: single window survives", #wins == 1)
check(
  "dashboard: closing restores the replaced buffer",
  vim.api.nvim_win_get_buf(wins[1]) == dash
)

-- 7. Closing one panel window by hand tears the whole panel down.
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

-- 9. A file opened into a panel window is relocated to a new tabpage; the
-- panel keeps its buffers.
vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
ndsh.open()
local foreign = vim.api.nvim_create_buf(true, false)
vim.api.nvim_buf_set_name(foreign, vim.fn.tempname() .. "-foreign.txt")
local chat_win9 = vim.fn.bufwinid(chat_buf)
local tabs_before_relocate = #vim.api.nvim_list_tabpages()
vim.api.nvim_win_set_buf(chat_win9, foreign)
vim.wait(200, function()
  return vim.api.nvim_win_get_buf(chat_win9) == chat_buf
    and #vim.api.nvim_list_tabpages() == tabs_before_relocate + 1
end)
check("panel window keeps its buffer", vim.api.nvim_win_get_buf(chat_win9) == chat_buf)
check("foreign buffer relocated to a new tab", #vim.api.nvim_list_tabpages() == tabs_before_relocate + 1)
check(
  "relocated tab shows the foreign buffer",
  vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(vim.api.nvim_list_tabpages()[#vim.api.nvim_list_tabpages()])[1]) == foreign
)
-- tabnew's listed scratch must not leak into buffer lists.
local stray = 0
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].buflisted and vim.api.nvim_buf_get_name(b) == "" then
    stray = stray + 1
  end
end
check("no stray listed scratch buffer", stray == 0)
vim.cmd("tabclose")

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
ndsh.setup({ restore = "quit", store_path = store_path, dsh = { auto_connect = false } })
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
