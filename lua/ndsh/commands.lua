--- Local slash commands: handled by the plugin, never sent to the wire.
--- The registry is the single source of truth for both the send path and
--- the input-pane command highlighting. Unknown slash commands pass through
--- to the runtime's native command routing.
local M = {}

---@type table<string, { run: fun(conv: table, args: string), desc: string }>
local registry = {
  rename = {
    desc = "Rename the current session",
    run = function(conv, args)
      if args == "" then
        vim.notify("ndsh: /rename needs a name", vim.log.levels.WARN)
        return
      end
      conv:rename(args)
      vim.notify(("ndsh: session renamed to %s"):format(args), vim.log.levels.INFO)
    end,
  },
  new = {
    desc = "New session (optional name)",
    run = function(_, args)
      local conv = require("ndsh").new_session(args ~= "" and args or nil)
      -- /new comes from the input pane; land the user in the new one.
      conv:focus_input()
    end,
  },
  usage = {
    desc = "Show the provider account balance",
    run = function()
      require("ndsh").usage()
    end,
  },
}

---Registered LOCAL command names, for the highlight pattern.
---@return string[]
function M.names()
  local names = {}
  for name in pairs(registry) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

---Commands the dsh runtime routes natively in the sdk profile. Verified
---against a live runtime: compact, goal and plan resolve as commands;
---export, feedback and permission are Host/Web-side and fall through as
---plain prompts on this wire. Never intercepted locally. Kept in sync
---manually until the SDK exposes a catalog query.
---@return string[]
function M.wire_names()
  return { "compact", "goal", "plan" }
end

---Completion for the input pane (:h complete-functions). Completes local
---and wire commands after a leading "/", stays silent otherwise.
---@param findstart integer
---@param base string
---@return integer|table[]
function M.complete(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line()
    if not line:find("^/") then
      return -2 -- silent: no completion outside slash command position
    end
    return 0 -- complete from just after the leading slash
  end
  local items = {}
  for _, name in ipairs(M.names()) do
    if name:find("^" .. vim.pesc(base)) then
      items[#items + 1] = { word = name, menu = "[local]" }
    end
  end
  for _, name in ipairs(M.wire_names()) do
    if name:find("^" .. vim.pesc(base)) then
      items[#items + 1] = { word = name, menu = "[dsh]" }
    end
  end
  return items
end

---Try to handle text as a local slash command.
---@param conv table
---@param text string
---@return boolean handled
function M.run(conv, text)
  local cmd, args = text:match("^/(%S+)%s*(.-)%s*$")
  if cmd and registry[cmd] then
    registry[cmd].run(conv, args)
    return true
  end
  return false
end

return M
