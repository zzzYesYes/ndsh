--- ndsh configuration: defaults and validation.
local M = {}

M.defaults = {
  --- Panel dock: "right" | "bottom" | "float".
  --- Overridden by the adaptive takeover rule: a single empty window
  --- always gets a full-tab layout regardless of this value.
  layout = "right",
  --- Chat column width as a fraction of &columns (right layout).
  width = 0.4,
  --- Panel height as a fraction of &lines (bottom layout).
  height = 0.3,
  --- Input window height in rows.
  input_height = 6,
  keys = {
    --- Send from the input buffer (insert and normal mode). Normal-mode
    --- <CR> also sends; insert-mode <CR> is always a plain newline.
    send = { "<C-s>" },
    --- Global toggle mapping in normal mode; nil to define your own.
    toggle = "<leader>ao",
  },
}

local function is_list(v)
  return type(v) == "table" and (v[1] ~= nil or next(v) == nil)
end

---Merge user options over defaults and validate.
---@param opts table|nil
---@return table
function M.resolve(opts)
  opts = opts or {}
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  assert(
    cfg.layout == "right" or cfg.layout == "bottom" or cfg.layout == "float",
    ("ndsh: layout must be 'right', 'bottom' or 'float', got %q"):format(tostring(cfg.layout))
  )
  assert(type(cfg.width) == "number" and cfg.width > 0 and cfg.width < 1, "ndsh: width must be in (0, 1)")
  assert(type(cfg.height) == "number" and cfg.height > 0 and cfg.height < 1, "ndsh: height must be in (0, 1)")
  assert(type(cfg.input_height) == "number" and cfg.input_height >= 1, "ndsh: input_height must be >= 1")
  assert(is_list(cfg.keys.send), "ndsh: keys.send must be a list of key strings")
  return cfg
end

return M
