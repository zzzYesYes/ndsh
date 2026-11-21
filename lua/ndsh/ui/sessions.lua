--- Session navigator (:NDSHSessions): telescope picker when available,
--- vim.ui.select otherwise. Lists every conversation, most recently active
--- first, with status and unread markers.
local M = {}

local STATUS_ICON = { running = "⠋", idle = "✓" }

---@param conv table
---@return string
local function display(conv)
  local icon = STATUS_ICON[conv.status] or "○"
  local unread = conv.unread and " ●" or ""
  return ("%s %s%s"):format(icon, conv.name, unread)
end

---Open the navigator. Calls on_select(conv) with the chosen conversation.
---@param conversations table[] most-recently-active first
---@param on_select fun(conv: table)
function M.open(conversations, on_select)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.ui.select(conversations, {
      prompt = "ndsh: sessions",
      format_item = display,
    }, function(conv)
      if conv then
        on_select(conv)
      end
    end)
    return
  end
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  pickers.new({}, {
    prompt_title = "ndsh sessions",
    finder = finders.new_table({
      results = conversations,
      entry_maker = function(conv)
        return { value = conv, display = display(conv), ordinal = conv.name }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          on_select(entry.value)
        end
      end)
      return true
    end,
  }):find()
end

return M
