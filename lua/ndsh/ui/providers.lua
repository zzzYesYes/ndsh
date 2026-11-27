--- Provider picker (:NDSHConnect): telescope picker when available,
--- vim.ui.select otherwise. Entries are cfg.providers entries handed back
--- untouched on select; a ✓ marks providers with stored credentials.
local M = {}

---@param providers table[] cfg.providers entries
---@param on_select fun(provider: table)
---@param is_connected fun(provider_id: string): boolean
function M.open(providers, on_select, is_connected)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.ui.select(providers, {
      prompt = "ndsh: connect provider",
      format_item = function(p)
        return p.label .. (is_connected(p.id) and "  ✓" or "")
      end,
    }, function(p)
      if p then
        on_select(p)
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
      { width = 24 }, -- label
      { remaining = true }, -- provider id, dimmed
      { width = 2 }, -- connected marker
    },
  })
  pickers
    .new({}, {
      prompt_title = "ndsh connect provider",
      finder = finders.new_table({
        results = providers,
        entry_maker = function(p)
          return {
            value = p,
            ordinal = p.label .. " " .. p.id,
            display = function()
              return displayer({
                p.label,
                { p.id, "Comment" },
                is_connected(p.id) and { "✓", "DiagnosticOk" } or " ",
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
