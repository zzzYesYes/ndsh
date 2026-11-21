--- Credential store for :NDSHConnect. Persists per-provider entries at
--- stdpath("data")/ndsh/credentials.json with owner-only permissions; the
--- session layer merges the stored env into the runtime process at spawn.
--- Every function takes an optional explicit path for tests.
local M = {}

---@return string
local function default_path()
  return vim.fn.stdpath("data") .. "/ndsh/credentials.json"
end

---@param path string|nil
---@return table<string, { env: table<string, string>, model: string|nil }>
function M.load(path)
  path = path or default_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

---@param store table
---@param path string|nil
function M.save(store, path)
  path = path or default_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(store) }, path)
  -- Credentials are secrets; keep the file owner-only.
  vim.fn.setfperm(path, "rw-------")
end

---@param provider string
---@param path string|nil
---@return { env: table<string, string>, model: string|nil }|nil
function M.get(provider, path)
  return M.load(path)[provider]
end

---@param provider string
---@param entry { env: table<string, string>, model: string|nil }
---@param path string|nil
function M.set(provider, entry, path)
  local store = M.load(path)
  store[provider] = entry
  M.save(store, path)
end

---Environment dict the runtime should inherit for a provider, or empty.
---@param provider string
---@param path string|nil
---@return table<string, string>
function M.env_for(provider, path)
  local entry = M.get(provider, path)
  return entry and entry.env or {}
end

---The last explicitly selected route, or nil. Stored under a reserved key
---separate from credential entries.
---@param path string|nil
---@return { provider: string, model: string }|nil
function M.current(path)
  local current = M.load(path)._current
  if type(current) == "table" and current.provider and current.model then
    return { provider = current.provider, model = current.model }
  end
  return nil
end

---Persist the selected route and keep the provider's model in sync.
---@param provider string
---@param model string
---@param path string|nil
function M.set_current(provider, model, path)
  local store = M.load(path)
  store._current = { provider = provider, model = model }
  local entry = store[provider]
  if type(entry) == "table" then
    entry.model = model
  end
  M.save(store, path)
end

return M
