--- Restart persistence: the registry and transcript survive a process
--- restart, and resume_last reactivates the stored session. Drives two child
--- nvim processes sharing a sandboxed XDG_DATA_HOME (tests/restart_child.lua).
--- Run from the repo root:
---   nvim --headless -u NONE --cmd "set rtp+=." -l tests/restart.lua
local failures = 0
local function check(name, cond)
  print((cond and "ok   - " or "FAIL - ") .. name)
  if not cond then
    failures = failures + 1
  end
end

local sandbox = vim.fn.tempname()
vim.fn.mkdir(sandbox, "p")
local child = vim.fn.getcwd() .. "/tests/restart_child.lua"

local function run_child(phase)
  return vim.system({
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "--cmd",
    "set rtp+=" .. vim.fn.getcwd(),
    "-l",
    child,
    phase,
  }, { env = { XDG_DATA_HOME = sandbox }, text = true }):wait(60000)
end

local create = run_child("create")
check("create boot exits cleanly", create.code == 0)
check("registry written", vim.fn.filereadable(sandbox .. "/nvim/ndsh/sessions.json") == 1)
check("transcript written", #vim.fn.glob(sandbox .. "/nvim/ndsh/transcripts/*.md", false, true) == 1)

local reopen = run_child("check")
-- Prints from scheduled callbacks land on the child's stderr.
local child_log = (reopen.stdout or "") .. "\n" .. (reopen.stderr or "")
for _, line in ipairs(vim.split(vim.trim(child_log), "\n")) do
  print("  child: " .. line)
end
check("check boot exits cleanly", reopen.code == 0)
check("child checks passed", child_log:find("FAIL", 1, true) == nil)

if failures > 0 then
  print(("%d check(s) failed"):format(failures))
  vim.cmd("cquit 1")
end
print("all restart checks passed")
vim.cmd("quitall!")
