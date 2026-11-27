--- pi-ai provider routes, managed by ndsh. The runtime's pi-ai adapter
--- mounts dormant (zero routes) until the sdk profile's patch layer
--- configures one; this module owns a marked block in
--- ~/.dsh/profiles/sdk/cordis.patch.yml, regenerated from routes.json beside
--- the credentials store. Content outside the marker block is untouched.
local M = {}

local MARK_BEGIN = "# ndsh:managed-routes begin"
local MARK_END = "# ndsh:managed-routes end"

---@param cfg table
---@return string
local function store_dir(cfg)
  if cfg.store_path then
    return vim.fn.fnamemodify(cfg.store_path, ":h")
  end
  return vim.fn.stdpath("data") .. "/ndsh"
end

---@return string
local function patch_path()
  local home = vim.env.DSH_HOME or vim.fn.expand("~/.dsh")
  return home .. "/profiles/sdk/cordis.patch.yml"
end

---@class NdsRoute
---@field id string pi-ai provider route id (e.g. "moonshotai")
---@field defaultContextWindow integer|nil
---@field defaultMaxTokens integer|nil
---@field defaultInput string[]|nil
---@field models table[] { id, contextWindow?, maxTokens?, input? }

---The route store: route id -> NdsRoute.
---@param cfg table
---@return table<string, NdsRoute>
function M.list(cfg)
  local path = store_dir(cfg) .. "/routes.json"
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return (ok and type(decoded) == "table") and decoded or {}
end

---@param cfg table
---@param routes table<string, NdsRoute>
local function save_store(cfg, routes)
  local path = store_dir(cfg) .. "/routes.json"
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(routes) }, path)
  vim.fn.setfperm(path, "rw-------")
end

---@param s string
---@return string
local function yaml_string(s)
  return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

---@param indent string
---@param key string
---@param value string|number
---@return string
local function yaml_field(indent, key, value)
  return indent .. key .. ": " .. (type(value) == "number" and tostring(value) or yaml_string(value))
end

---@param list string[]
---@return string
local function yaml_inline_list(list)
  local parts = {}
  for _, v in ipairs(list) do
    parts[#parts + 1] = yaml_string(v)
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

---@param model table
---@return string[]
local function emit_model(model)
  local lines = { "          - id: " .. yaml_string(model.id) }
  for _, key in ipairs({ "name", "contextWindow", "maxTokens" }) do
    if model[key] ~= nil then
      lines[#lines + 1] = yaml_field("            ", key, model[key])
    end
  end
  if type(model.input) == "table" then
    lines[#lines + 1] = "            input: " .. yaml_inline_list(model.input)
  end
  return lines
end

---@param route NdsRoute
---@return string[]
local function emit_route(route)
  local lines = { "      " .. route.id .. ":" }
  for _, key in ipairs({ "defaultContextWindow", "defaultMaxTokens" }) do
    if route[key] ~= nil then
      lines[#lines + 1] = yaml_field("        ", key, route[key])
    end
  end
  if type(route.defaultInput) == "table" then
    lines[#lines + 1] = "        defaultInput: " .. yaml_inline_list(route.defaultInput)
  end
  lines[#lines + 1] = "        models:"
  for _, model in ipairs(route.models or {}) do
    vim.list_extend(lines, emit_model(model))
  end
  return lines
end

---Render the managed block for a route store.
---@param routes table<string, NdsRoute>
---@return string[]
local function render_block(routes)
  local lines = { MARK_BEGIN, "- id: llm-pi-ai", "  config:", "    providers:" }
  local ids = vim.tbl_keys(routes)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local route = routes[id]
    route.id = route.id or id
    vim.list_extend(lines, emit_route(route))
  end
  lines[#lines + 1] = MARK_END
  return lines
end

---Rewrite the managed block in the profile patch from the store.
---@param cfg table
---@return boolean changed
local function sync(cfg)
  local path = patch_path()
  local routes = M.list(cfg)
  local lines = vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  -- Drop the previous managed block (inclusive markers).
  local kept, in_block = {}, false
  for _, line in ipairs(lines) do
    if line == MARK_BEGIN then
      in_block = true
    elseif line == MARK_END then
      in_block = false
    elseif not in_block then
      kept[#kept + 1] = line
    end
  end
  -- A bare "[]" placeholder is replaced once real entries exist.
  local body = {}
  for _, line in ipairs(kept) do
    if line ~= "[]" then
      body[#body + 1] = line
    end
  end
  if next(routes) then
    vim.list_extend(body, render_block(routes))
  end
  if #body == 0 then
    body = { "[]" }
  end
  local new_content = table.concat(body, "\n") .. "\n"
  local old_content = #lines > 0 and (table.concat(lines, "\n") .. "\n") or ""
  if new_content == old_content then
    return false
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(body, path)
  return true
end

---Add a route to the store when missing and sync the patch file. Existing
---routes are kept as-is (user edits preserved).
---@param cfg table
---@param route NdsRoute
---@return boolean changed true when the patch file changed
function M.ensure_route(cfg, route)
  local routes = M.list(cfg)
  if routes[route.id] then
    return false
  end
  routes[route.id] = route
  save_store(cfg, routes)
  return sync(cfg)
end

---Append a model to a managed route when missing (e.g. a discovered model
---picked in :NDSHModel).
---@param cfg table
---@param route_id string
---@param model_id string
---@return boolean changed
function M.ensure_model(cfg, route_id, model_id)
  local routes = M.list(cfg)
  local route = routes[route_id]
  if not route then
    return false
  end
  route.models = route.models or {}
  for _, m in ipairs(route.models) do
    if m.id == model_id then
      return false
    end
  end
  route.models[#route.models + 1] = { id = model_id }
  save_store(cfg, routes)
  return sync(cfg)
end

---Whether a provider id is a managed pi-ai route.
---@param cfg table
---@param provider string
---@return boolean
function M.is_route(cfg, provider)
  return M.list(cfg)[provider] ~= nil
end

---Sync the patch file with the store (boot-time repair).
---@param cfg table
function M.sync(cfg)
  return sync(cfg)
end

return M
