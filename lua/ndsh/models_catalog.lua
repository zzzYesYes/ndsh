--- Provider model discovery: fetch each provider's model catalog over HTTP
--- (the SDK has no catalog query yet — docs/upstream-sdk-plan.md item 4).
--- curl + vim.system + vim.json only, same tool discipline as the bootstrap.
--- Results cache in memory for the nvim session; failures are soft, callers
--- fall back to stored routes and free-text entry.
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
  local argv = { "curl", "-fsSL", "--max-time", "10" }
  if provider.auth == "anthropic" then
    argv[#argv + 1] = "-H"
    argv[#argv + 1] = "x-api-key: " .. key
    argv[#argv + 1] = "-H"
    argv[#argv + 1] = "anthropic-version: 2023-06-01"
  else
    argv[#argv + 1] = "-H"
    argv[#argv + 1] = "Authorization: Bearer " .. key
  end
  argv[#argv + 1] = provider.models_url
  return argv
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

---Fetch the provider's model catalog. cb receives the sorted model id list,
---or nil on any failure (no url, no key, network, parse). Repeat calls serve
---from the per-session cache.
---@param provider table cfg.providers entry
---@param env table<string, string>|nil stored credentials env
---@param cb fun(models: string[]|nil)
function M.fetch(provider, env, cb)
  if cache[provider.id] ~= nil then
    local cached = cache[provider.id]
    return cb(cached or nil)
  end
  local argv = curl_argv(provider, env)
  if not argv then
    return cb(nil)
  end
  vim.system(argv, {}, function(res)
    vim.schedule(function()
      local models = res.code == 0 and parse(res.stdout or "") or nil
      cache[provider.id] = models or false
      cb(models)
    end)
  end)
end

---Drop the cache (tests; a refresh mapping can use it later).
function M._clear_cache()
  cache = {}
end

return M
