--- Dependency tripwire: every require() in lua/ndsh must resolve to an
--- ndsh module. Any external module is a dependency and must be declared
--- in docs/dependencies.md first. Run from the repo root:
---   nvim --headless -u NONE -l tests/deps.lua
local failures = 0

local files = vim.fn.globpath("lua/ndsh", "**/*.lua", true, true)
assert(#files > 0, "no lua/ndsh files found; run from the repo root")

for _, file in ipairs(files) do
  for lnum, line in ipairs(vim.fn.readfile(file)) do
    -- require("mod"), require "mod"; comment lines are ignored.
    local stripped = line:gsub("%-%-.*$", "")
    for mod in stripped:gmatch('require%s*%(%s*["\']([^"\']+)["\']') do
      if not mod:find("^ndsh") then
        failures = failures + 1
        print(("FAIL - %s:%d requires external module %q (declare it in docs/dependencies.md)"):format(file, lnum, mod))
      end
    end
    for mod in stripped:gmatch('require%s+["\']([^"\']+)["\']') do
      if not mod:find("^ndsh") then
        failures = failures + 1
        print(("FAIL - %s:%d requires external module %q (declare it in docs/dependencies.md)"):format(file, lnum, mod))
      end
    end
  end
end

if failures > 0 then
  print(("%d undeclared dependency reference(s)"):format(failures))
  vim.cmd("cquit 1")
end
print(("ok   - %d files, no external module dependencies"):format(#files))
vim.cmd("quitall!")
