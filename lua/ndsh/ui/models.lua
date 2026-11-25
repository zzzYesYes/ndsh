--- Model selector (:NDSHModel): telescope picker when available,
--- vim.ui.select otherwise. Entries come from init.lua: the active route,
--- configured dsh.models, every connected provider's stored model, and one
--- "other model…" entry per connected provider (free-text model name).
local M = {}

---@param item table { provider, model?, label?, current?, custom? }
---@return string
local function display(item)
  if item.custom then
    return item.provider .. " / other model…"
  end
  return (item.label or (item.provider .. " / " .. item.model)) .. (item.current and "  (current)" or "")
end

---Open the selector. Calls on_select(choice) with the chosen entry;
---custom entries are handed back for the caller to prompt a model name.
---@param candidates table[]
---@param on_select fun(choice: table)
function M.open(candidates, on_select)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.ui.select(candidates, {
      prompt = "ndsh: select model",
      format_item = display,
    }, function(choice)
      if choice then
        on_select(choice)
      end
    end)
    return
  end
  local finders = require("telescope.finders")
  local entry_display = require("telescope.pickers.entry_display")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 22 }, -- provider, dimmed
      { remaining = true }, -- model label + current marker
    },
  })
  pickers
    .new({}, {
      prompt_title = "ndsh models",
      finder = finders.new_table({
        results = candidates,
        entry_maker = function(item)
          return {
            value = item,
            ordinal = item.provider .. " " .. (item.custom and "other custom" or item.model),
            display = function()
              return displayer({
                { item.provider, "Comment" },
                item.custom and { "other model…", "Special" } or (item.label or item.model)
                  .. (item.current and "  ●" or ""),
              })
            end,
          }
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
    })
    :find()
end

return M
