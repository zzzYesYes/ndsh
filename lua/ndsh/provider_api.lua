--- Provider HTTP APIs: model catalogs and account balances. (The SDK has no
--- catalog query yet — docs/upstream-sdk-plan.md item 4.) curl + vim.system
--- + vim.json only, same tool discipline as the bootstrap. Catalog results
--- cache in memory for the nvim session; failures are soft, callers fall
--- back to stored routes and free-text entry.
local M = {}

---@type table<string, string[]|false> provider id -> model ids; false = failed
local cache = {}

---The API key for a provider: stored credentials first, process env second.
---@param provider table cfg.providers entry
---@param env table<string, string>|nil stored credentials env
---@return string|nil
local function key_of(provider, env)
  local name = provider.env and provider.env[1]
  if not name then
    return nil
  end
  return (env or {})[name] or vim.env[name]
end

---@param provider table cfg.providers entry
---@param key string
---@return string[] header args for curl
local function auth_headers(provider, key)
  if provider.auth == "anthropic" then
    return { "-H", "x-api-key: " .. key, "-H", "anthropic-version: 2023-06-01" }
  end
  return { "-H", "Authorization: Bearer " .. key }
end

---@param provider table cfg.providers entry { id, models_url, auth, env }
---@return string[]|nil argv
local function curl_argv(provider, env)
  if not provider.models_url then
    return nil
  end
  local key = key_of(provider, env)
  if not key then
    return nil
  end
  local argv = { "curl", "-sSL", "--max-time", "10", "-w", "\n%{http_code}" }
  vim.list_extend(argv, auth_headers(provider, key))
  argv[#argv + 1] = provider.models_url
  return argv
end

---GET with the trailing status line peeled off. cb receives (body, status);
---status is nil on network failure.
---@param argv string[]
---@param cb fun(body: string|nil, status: integer|nil)
local function run_get(argv, cb)
  vim.system(argv, {}, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return cb(nil, nil)
      end
      local body, code = (res.stdout or ""):match("^([%s%S]*)\n(%d+)$")
      cb(body, tonumber(code))
    end)
  end)
end

---Parse the catalog body. DeepSeek, Anthropic and OpenAI all answer with
---OpenAI's shape: { data = [ { id = ... } ] }.
---@param stdout string
---@return string[]|nil
local function parse(stdout)
  local ok, decoded = pcall(vim.json.decode, stdout)
  if not ok or type(decoded) ~= "table" or type(decoded.data) ~= "table" then
    return nil
  end
  local models = {}
  for _, m in ipairs(decoded.data) do
    if type(m) == "table" and type(m.id) == "string" then
      models[#models + 1] = m.id
    end
  end
  if #models == 0 then
    return nil
  end
  table.sort(models)
  return models
end

---Fetch the provider's model catalog. cb receives (models, status): the
---sorted model id list and HTTP status; models is nil on any failure (no
---url, no key, network — status nil — or non-2xx). Repeat 2xx calls serve
---from the per-session cache.
---@param provider table cfg.providers entry
---@param env table<string, string>|nil stored credentials env
---@param cb fun(models: string[]|nil, status: integer|nil)
function M.fetch(provider, env, cb)
  if cache[provider.id] ~= nil then
    local cached = cache[provider.id]
    return cb(cached or nil, cached and 200 or nil)
  end
  local argv = curl_argv(provider, env)
  if not argv then
    return cb(nil, nil)
  end
  run_get(argv, function(body, status)
    local models = status and status < 300 and body and parse(body) or nil
    if models then
      cache[provider.id] = models
    end
    cb(models, status)
  end)
end

---Account-balance adapters keyed by provider id; parse(decoded_body) returns
---a display string or nil. Balances are provider-specific shapes, so each
---adapter owns its parse. A cfg.providers entry may override with its own
---balance = { url = ..., parse = fn }.
---@type table<string, { url: string, parse: fun(decoded: table): string|nil }>
M.balance_adapters = {
  ["deepseek-official"] = {
    url = "https://api.deepseek.com/user/balance",
    parse = function(decoded)
      local infos = type(decoded) == "table" and decoded.balance_infos
      if type(infos) ~= "table" then
        return nil
      end
      local parts = {}
      for _, info in ipairs(infos) do
        if type(info) == "table" and info.total_balance then
          local s = ("%s %s"):format(info.total_balance, info.currency or "")
          local detail = {}
          if tonumber(info.topped_up_balance) and tonumber(info.topped_up_balance) > 0 then
            detail[#detail + 1] = "topped-up " .. info.topped_up_balance
          end
          if tonumber(info.granted_balance) and tonumber(info.granted_balance) > 0 then
            detail[#detail + 1] = "granted " .. info.granted_balance
          end
          if #detail > 0 then
            s = s .. " (" .. table.concat(detail, ", ") .. ")"
          end
          parts[#parts + 1] = s
        end
      end
      return #parts > 0 and table.concat(parts, " · ") or nil
    end,
  },
  -- No runtime adapter ships for Kimi yet (see TODO.md); the balance API
  -- works the day one lands.
  kimi = {
    url = "https://api.moonshot.ai/v1/users/me/balance",
    parse = function(decoded)
      local d = type(decoded) == "table" and decoded.data
      if type(d) ~= "table" or type(d.available_balance) ~= "number" then
        return nil
      end
      return ("$%.2f (cash $%.2f, voucher $%.2f)"):format(d.available_balance, d.cash_balance or 0, d.voucher_balance or 0)
    end,
  },
}

---Fetch the account balance for a provider. cb receives (text, err): a
---display string, or nil with a reason.
---@param provider table cfg.providers entry
---@param env table<string, string>|nil stored credentials env
---@param cb fun(text: string|nil, err: string|nil)
function M.fetch_balance(provider, env, cb)
  local adapter = provider.balance or M.balance_adapters[provider.id]
  if not adapter or not adapter.url then
    return cb(nil, ("no balance API for %s"):format(provider.label or provider.id))
  end
  local key = key_of(provider, env)
  if not key then
    return cb(nil, ("no API key stored for %s"):format(provider.label or provider.id))
  end
  local argv = { "curl", "-sSL", "--max-time", "10", "-w", "\n%{http_code}" }
  vim.list_extend(argv, auth_headers(provider, key))
  argv[#argv + 1] = adapter.url
  run_get(argv, function(body, status)
    if not status then
      return cb(nil, "network unreachable")
    end
    if status == 401 or status == 403 then
      return cb(nil, "API key rejected (HTTP " .. status .. ")")
    end
    if status >= 300 then
      return cb(nil, "HTTP " .. status)
    end
    local ok, decoded = pcall(vim.json.decode, body or "")
    local text = ok and adapter.parse(decoded) or nil
    cb(text, text == nil and "unparseable response" or nil)
  end)
end

---Drop the cache (tests; a refresh mapping can use it later).
function M._clear_cache()
  cache = {}
end

return M
