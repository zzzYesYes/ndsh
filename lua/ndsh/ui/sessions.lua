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
---With on_delete given (telescope path only), <C-d> asks the caller to
---delete the highlighted conversation; the done() continuation refreshes
---the list in place.
---@param conversations table[] most-recently-active first
---@param on_select fun(conv: table)
---@param on_delete fun(conv: table, done: fun())|nil
function M.open(conversations, on_select, on_delete)
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
  local results = conversations
  local function make_finder()
    return finders.new_table({
      results = results,
      entry_maker = function(conv)
        return { value = conv, display = display(conv), ordinal = conv.name }
      end,
    })
  end
  pickers
    .new({}, {
      prompt_title = "ndsh sessions",
      finder = make_finder(),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            on_select(entry.value)
          end
        end)
        if on_delete then
          map({ "i", "n" }, "<C-d>", function()
            local entry = action_state.get_selected_entry()
            if not entry then
              return
            end
            on_delete(entry.value, function()
              for i, c in ipairs(results) do
                if c == entry.value then
                  table.remove(results, i)
                  break
                end
              end
              action_state.get_current_picker(prompt_bufnr):refresh(make_finder(), { reset_prompt = false })
            end)
          end)
        end
        return true
      end,
    })
    :find()
end

return M
