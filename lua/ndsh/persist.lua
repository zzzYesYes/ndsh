--- Session registry persistence: conversations survive nvim restarts.
--- Stored as sessions.json beside the credentials store (or next to
--- store_path when overridden). Wire resume requires the ORIGINAL session
--- id, so ids are persisted verbatim.
local M = {}

---@param cfg table resolved ndsh config
---@return string
local function store_path(cfg)
  if cfg.store_path then
    return vim.fn.fnamemodify(cfg.store_path, ":h") .. "/sessions.json"
  end
  return vim.fn.stdpath("data") .. "/ndsh/sessions.json"
end

---@class NdsStoredSession
---@field id string wire session id (resume address)
---@field name string display name
---@field created integer epoch seconds
---@field last_active integer epoch seconds

---@param cfg table
---@return NdsStoredSession[]
function M.load(cfg)
  local path = store_path(cfg)
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" or type(decoded.sessions) ~= "table" then
    return {}
  end
  return decoded.sessions
end

---@param cfg table
---@param sessions NdsStoredSession[]
function M.save(cfg, sessions)
  local path = store_path(cfg)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode({ sessions = sessions }) }, path)
  -- Session metadata is not secret, but keep the store owner-only anyway.
  vim.fn.setfperm(path, "rw-------")
end

return M
