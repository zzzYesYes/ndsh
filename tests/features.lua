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
local last_items
vim.ui.select = function(items, _, on_choice)
  last_items = items
  on_choice(items[select_pick], select_pick)
end
vim.ui.input = function(_, on_submit)
  on_submit(table.remove(input_answers, 1))
end

-- Model discovery is stubbed: no real HTTP in tests. cb gets (models, http
-- status), matching provider_api.fetch.
local catalog = require("ndsh.provider_api")
catalog.fetch = function(provider, _, cb)
  if provider.id == "deepseek-official" then
    cb({ "deepseek-flash", "deepseek-v4-pro" }, 200)
  else
    cb(nil, nil)
  end
end

local credentials = require("ndsh.credentials")
local ndsh = require("ndsh")

local restarted = 0
local orig_restart = ndsh.restart_session
ndsh.restart_session = function()
  restarted = restarted + 1
end
-- API keys are entered via masked input; stub the wrapper.
ndsh._ask_secret = function(_, cb)
  cb(table.remove(input_answers, 1))
end

ndsh.setup({ store_path = store_path, dsh = { auto_connect = false } })

-- 1. Connect flow: pick the first provider (deepseek-official), enter key,
-- pick the discovered default model from the catalog picker.
input_answers = { "sk-validation" }
select_pick = 1
ndsh.connect()

local entry = credentials.get("deepseek-official", store_path)
check("connect stores env and model", entry ~= nil and entry.env.DEEPSEEK_API_KEY == "sk-validation" and entry.model == "deepseek-flash")
local current = credentials.current(store_path)
check("connect records current route", current ~= nil and current.provider == "deepseek-official")
check("connect restarts the runtime", restarted == 1)
check(
  "connect model picker lists discovered models",
  last_items ~= nil and last_items[2] ~= nil and last_items[2].model == "deepseek-v4-pro"
)
check("connect model picker keeps a custom entry", last_items ~= nil and last_items[#last_items].custom == true)

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
local saw_discovered
vim.ui.select = function(items, _, on_choice)
  for i, item in ipairs(items) do
    if item.provider == "deepseek-official" and item.model == "deepseek-v4-pro" then
      saw_discovered = true
    end
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
check("select_model lists discovered models", saw_discovered == true)
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

-- 6. Reasoning effort picker: sets the config, persists with the route,
-- restarts the runtime.
vim.ui.select = function(items, _, on_choice)
  on_choice(items[select_pick], select_pick)
end
select_pick = 3 -- off, low, high, max, auto
ndsh.select_reasoning_effort()
current = credentials.current(store_path)
check("reasoning effort persists with the route", current ~= nil and current.reasoning_effort == "high")
check("effort switch restarts the runtime", restarted == 4)

-- 7. /usage reports the balance via the provider adapter.
local last_notify
vim.notify = function(msg)
  last_notify = msg
end
require("ndsh.provider_api").fetch_balance = function(_, _, cb)
  cb("23.97 CNY (topped-up 23.97)", nil)
end
ndsh.usage()
check("usage reports the balance", last_notify ~= nil and last_notify:find("23.97 CNY", 1, true) ~= nil)

-- 8. A rejected key is re-asked and never stored (connect validates via the
-- catalog fetch before saving).
catalog.fetch = function(_, _, cb)
  cb(nil, 401)
end
input_answers = { "sk-bad" }
ndsh.connect()
local after = credentials.get("deepseek-official", store_path)
check("rejected key leaves the store untouched", after ~= nil and after.env.DEEPSEEK_API_KEY == "sk-validation")

-- 9. Connecting a pi-ai provider writes its route into the sdk profile's
-- patch layer (managed block), so the runtime accepts the provider.
catalog.fetch = function(provider, _, cb)
  if provider.id == "moonshotai" then
    -- The catalog offers a model the preset route does not declare yet.
    cb({ "kimi-k3", "kimi-k2-0905-preview" }, 200)
  elseif provider.id == "deepseek-official" then
    cb({ "deepseek-flash", "deepseek-v4-pro" }, 200)
  else
    cb(nil, nil)
  end
end
vim.env.DSH_HOME = store_dir
local picks = { 2, 2 } -- provider: moonshotai; then kimi-k3 (not the seed default)
vim.ui.select = function(items, _, on_choice)
  local i = table.remove(picks, 1)
  on_choice(items[i], i)
end
input_answers = { "sk-kimi" }
ndsh.connect()
local route_list = require("ndsh.routes").list(require("ndsh.config").resolve({ store_path = store_path }))
check("connect stores the pi-ai route", route_list.moonshotai ~= nil)
local patch = table.concat(vim.fn.readfile(store_dir .. "/profiles/sdk/cordis.patch.yml"), "\n")
check(
  "route lands in the profile patch",
  patch:find("ndsh:managed%-routes") ~= nil and patch:find("moonshotai", 1, true) ~= nil
)
check(
  "catalog model picked at connect is declared on the route",
  route_list.moonshotai ~= nil
    and vim.tbl_contains(
      vim.tbl_map(function(m)
        return m.id
      end, route_list.moonshotai.models),
      "kimi-k3"
    )
)
check("route provider connects and restarts", restarted == 5)
vim.env.DSH_HOME = nil

ndsh.restart_session = orig_restart
vim.fn.delete(store_dir, "rf")

if failures > 0 then
  print(("%d check(s) failed"):format(failures))
  vim.cmd("cquit 1")
end
print("all feature checks passed")
vim.cmd("quitall!")
