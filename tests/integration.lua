--- Headless integration test: drives the full stack (job → protocol →
--- session → projection → buffers) against tests/fixtures/fake_dsh.py.
--- Run from the repo root:
---   nvim --headless -u NONE --cmd "set rtp+=." -l tests/integration.lua
if vim.fn.executable("python3") ~= 1 then
  print("SKIP - python3 not available")
  vim.cmd("quitall!")
end

local failures = 0
local function check(name, cond)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name)
  end
end

-- Auto-answer approvals with the first choice ("Allow once").
vim.ui.select = function(items, _, on_choice)
  on_choice(items[1], 1)
end

local function find_chat_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_get_option_value("filetype", { buf = buf }) == "ndsh" then
      return buf
    end
  end
  return nil
end

local function winbar_text(win)
  return vim.api.nvim_get_option_value("winbar", { win = win })
end

---The winbar carries a context-usage suffix after the status word.
local function has_status(win, status)
  return winbar_text(win):find("^ ndsh · " .. status) ~= nil
end

local ndsh = require("ndsh")
ndsh.setup({
  restore = "scratch",
  dsh = {
    auto_connect = true,
    cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/fake_dsh.py" },
  },
})

ndsh.open()
local chat_buf = find_chat_buf()
check("panel opened with chat buffer", chat_buf ~= nil)

local input_win
local input1_buf
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_buf(win) ~= chat_buf then
    input_win = win
    input1_buf = vim.api.nvim_win_get_buf(win)
  end
end

local ready = vim.wait(10000, function()
  return has_status(input_win, "idle")
end, 50)
check("handshake completes (winbar idle)", ready)

local function chat_text()
  return table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
end

-- 1. Ordinary prompt: scripted events render end to end.
ndsh._on_send("integration hello")
local rendered = vim.wait(10000, function()
  return chat_text():find("FAKE%-OUTRO: integration hello") ~= nil
end, 100)
check("assistant reply rendered from live wire", rendered)
check("user message rendered", chat_text():find("❯ You", 1, true) ~= nil)
check("tool call rendered", chat_text():find("✓ bash · %{\"command\":\"echo hi\"%}") ~= nil)
check("tool output rendered", chat_text():find("  │ fake output line 1", 1, true) ~= nil)

-- Reasoning renders dimmed and folded closed by default.
check("reasoning header rendered", chat_text():find("∴ thinking", 1, true) ~= nil)
check("reasoning content present", chat_text():find("thinking about the right tool", 1, true) ~= nil)
local reasoning_folded = vim.api.nvim_win_call(vim.fn.bufwinid(chat_buf), function()
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)) do
    if line:find("thinking about the right tool", 1, true) then
      return vim.fn.foldclosed(lnum) ~= -1
    end
  end
  return false
end)
check("reasoning content folded closed", reasoning_folded)

-- Chrome: everything except the session name lives on the chat (input)
-- pane winbar — model left, cwd and context usage right. The message pane
-- winbar carries the session name.
check(
  "message pane winbar shows session name",
  winbar_text(vim.fn.bufwinid(chat_buf)):find("chat 1", 1, true) ~= nil
)
local input_winbar = winbar_text(input_win)
check(
  "chat winbar shows model and cwd",
  input_winbar:find("fake%-v1") ~= nil and input_winbar:find(vim.fn.fnamemodify(vim.uv.cwd(), ":~"), 1, true) ~= nil
)
check(
  "chat winbar shows context usage right-aligned",
  input_winbar:find("%= .*12k/128k · 10%%%%") ~= nil
)

local back_idle = vim.wait(5000, function()
  return has_status(input_win, "idle")
end, 50)
check("status returns to idle", back_idle)

-- 2. Approval flow: server request answered, outcome echoed in the result.
ndsh._on_send("please approve this")
local approved = vim.wait(10000, function()
  return chat_text():find("approval outcome: allowed%-once") ~= nil
end, 100)
check("approval request answered and rendered", approved)
-- The turn settles (turn/end, status idle) just after the outcome event;
-- synchronize before the restart so it cannot kill the runtime mid-turn.
local settled = vim.wait(5000, function()
  return has_status(input_win, "idle")
end, 50)
check("approval turn settles to idle", settled)

-- 3. Restart races a booting/finished process: the new generation must
-- reach ready and serve prompts; the old process's exit must not poison it.
ndsh.restart_session()
local re_ready = vim.wait(20000, function()
  return has_status(input_win, "idle")
end, 100)
check("restart reaches ready", re_ready)
ndsh._on_send("after restart")
local second = vim.wait(10000, function()
  return chat_text():find("FAKE%-OUTRO: after restart") ~= nil
end, 100)
check("prompt after restart renders", second)

-- 4. Multi-session: a new conversation swaps the panel's contents; the
-- first conversation's transcript persists untouched.
local conv2 = ndsh.new_session()
check("new session keeps a single tab", #vim.api.nvim_list_tabpages() == 1)
local chat2_buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_get_option_value("filetype", { buf = b }) == "ndsh" and b ~= chat_buf then
    chat2_buf = b
  end
end
check("second conversation has its own chat buffer", chat2_buf ~= nil)
check("panel now shows the second conversation", vim.fn.bufwinid(chat2_buf) ~= -1)
check("first conversation's window is hidden", vim.fn.bufwinid(chat_buf) == -1)
local function chat2_text()
  return table.concat(vim.api.nvim_buf_get_lines(chat2_buf, 0, -1, false), "\n")
end
ndsh._on_send(conv2, "second conversation here")
local second_conv = vim.wait(10000, function()
  return chat2_text():find("FAKE%-OUTRO: second conversation here") ~= nil
end, 100)
check("second conversation transcript renders", second_conv)
check(
  "transcripts are isolated",
  chat2_text():find("integration hello", 1, true) == nil
    and chat_text():find("second conversation here", 1, true) == nil
)
check(
  "winbar shows the second session name",
  winbar_text(vim.fn.bufwinid(chat2_buf)):find("chat 2", 1, true) ~= nil
)

-- 5. /rename is local: renames the conversation, hits no wire.
ndsh._on_send(conv2, "/rename second")
check(
  "/rename updates the winbar name",
  winbar_text(vim.fn.bufwinid(chat2_buf)):find("second", 1, true) ~= nil
)
check("/rename never hits the wire", chat2_text():find("FAKE%-OUTRO: /rename") == nil)

-- Slash commands are highlighted live in the input pane.
local input2_buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_get_option_value("filetype", { buf = b }) == "ndshinput"
    and vim.api.nvim_buf_get_name(b):find(conv2.id, 1, true)
  then
    input2_buf = b
  end
end
vim.api.nvim_buf_set_lines(input2_buf, 0, -1, false, { "/rename work" })
local has_match = false
for _, m in ipairs(vim.fn.getmatches(vim.fn.bufwinid(input2_buf))) do
  if m.group == "NDSHSlashCommand" then
    has_match = true
  end
end
check("input pane highlights local slash commands", has_match)

-- 6. The navigator (vim.ui fallback) switches the panel back to chat 1.
vim.ui.select = function(items, _, on_choice)
  for i, item in ipairs(items) do
    if item.name == "chat 1" then
      on_choice(item, i)
      return
    end
  end
  on_choice(nil, nil)
end
ndsh.sessions()
check("navigator swaps back to chat 1", vim.fn.bufwinid(chat_buf) ~= -1)
check("chat 1 transcript survived the swap", chat_text():find("integration hello", 1, true) ~= nil)

-- 7. Graceful stop: no error state, winbar shows stopped.
ndsh.stop_session()
local stopped = vim.wait(5000, function()
  local win = vim.fn.bufwinid(input1_buf)
  return win ~= -1 and has_status(win, "stopped")
end, 50)
check("stop is quiet and shows stopped", stopped)

if failures > 0 then
  print(("%d check(s) failed"):format(failures))
  vim.cmd("cquit 1")
end
print("all integration checks passed")
vim.cmd("quitall!")
