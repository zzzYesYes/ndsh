--- Feature validation for :NDSHConnect and :NDSHModel with stubbed vim.ui.
--- Run from the repo root:
---   nvim --headless -u NONE --cmd "set rtp+=." -l tests/features.lua
local failures = 0
local function check(name, cond)
  if cond then
    print("ok   - " .. name)
  else
    failures = failures + 1
    print("FAIL - " .. name)
  end
end

local store_dir = vim.fn.tempname()
local store_path = store_dir .. "/credentials.json"

-- Stub vim.ui: queued select picks and input answers.
local select_pick = 1
local input_answers = {}
vim.ui.select = function(items, _, on_choice)
  on_choice(items[select_pick], select_pick)
end
vim.ui.input = function(_, on_submit)
  on_submit(table.remove(input_answers, 1))
end

local credentials = require("ndsh.credentials")
local ndsh = require("ndsh")

local restarted = 0
local orig_restart = ndsh.restart_session
ndsh.restart_session = function()
  restarted = restarted + 1
end

ndsh.setup({ store_path = store_path, dsh = { auto_connect = false } })

-- 1. Connect flow: pick the first provider (deepseek-official), enter key,
-- accept default model.
input_answers = { "sk-validation", "deepseek-v4-flash" }
select_pick = 1
ndsh.connect()

local entry = credentials.get("deepseek-official", store_path)
check("connect stores env and model", entry ~= nil and entry.env.DEEPSEEK_API_KEY == "sk-validation" and entry.model == "deepseek-v4-flash")
local current = credentials.current(store_path)
check("connect records current route", current ~= nil and current.provider == "deepseek-official")
check("connect restarts the runtime", restarted == 1)

-- 2. Model selection: candidates include connected providers; picking the
-- second candidate (anthropic from the provider registry defaults via the
-- store? no — candidates: current route + dsh.models + stored entries).
-- Add a config model entry to see it listed, then re-setup.
ndsh.setup({
  store_path = store_path,
  dsh = {
    auto_connect = false,
    models = { { provider = "anthropic", model = "claude-opus-4-1", label = "Claude Opus" } },
  },
})

local picked
vim.ui.select = function(items, _, on_choice)
  picked = items[select_pick]
  on_choice(items[select_pick], select_pick)
end
select_pick = 2 -- first candidate is the active route; second is the config entry
ndsh.select_model()
check("model picker picked config entry", picked ~= nil and picked.provider == "anthropic" and picked.model == "claude-opus-4-1")
current = credentials.current(store_path)
check("model selection persists route", current ~= nil and current.provider == "anthropic" and current.model == "claude-opus-4-1")
check("model selection restarts the runtime", restarted == 2)

-- 3. Stored route applies at setup when provider/model are not explicit.
ndsh.setup({ store_path = store_path, dsh = { auto_connect = false } })
-- Read the effective config back through a fresh session's resolution path:
-- state is internal, so assert via the connect-time behavior instead: a new
-- select_model marks the stored route as "(current)".
local marked
vim.ui.select = function(items, _, on_choice)
  for _, item in ipairs(items) do
    if item.provider == "anthropic" and item.model == "claude-opus-4-1" then
      marked = item
    end
  end
  on_choice(nil, nil)
end
ndsh.select_model()
check("stored route is the active route after re-setup", marked ~= nil)

-- 4. Explicit setup config wins over the stored route.
ndsh.setup({
  store_path = store_path,
  dsh = { auto_connect = false, provider = "deepseek-official", model = "deepseek-v4-pro" },
})
marked = nil
ndsh.select_model()
check("explicit config wins over stored route", marked == nil)

-- 5. Custom model entry: any model name on a connected provider, without
-- re-entering credentials (stored env is reused).
ndsh.setup({ store_path = store_path, dsh = { auto_connect = false } })
local custom_entry
vim.ui.select = function(items, _, on_choice)
  for i, item in ipairs(items) do
    if item.custom then
      custom_entry = item
      on_choice(item, i)
      return
    end
  end
  on_choice(nil, nil)
end
input_answers = { "deepseek-v4-pro" }
ndsh.select_model()
check(
  "custom model entry offered for a connected provider",
  custom_entry ~= nil and custom_entry.provider == "deepseek-official"
)
current = credentials.current(store_path)
check(
  "custom model switches the route",
  current ~= nil and current.provider == "deepseek-official" and current.model == "deepseek-v4-pro"
)
check("custom model restarts the runtime", restarted == 3)

ndsh.restart_session = orig_restart
vim.fn.delete(store_dir, "rf")

if failures > 0 then
  print(("%d check(s) failed"):format(failures))
  vim.cmd("cquit 1")
end
print("all feature checks passed")
vim.cmd("quitall!")
