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
}

---Registered command names, for the highlight pattern.
---@return string[]
function M.names()
  local names = {}
  for name in pairs(registry) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
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
