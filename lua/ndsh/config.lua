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
    --- Global full-screen panel toggle; nil to define your own.
    toggle_full = "<leader>aO",
    --- Optional buffer-local tab navigation inside panel windows. Useful
    --- when your global "tab" keys operate on buffers (e.g. barbar): they
    --- are meaningless inside the reserved panel windows, so bind them to
    --- real tabpage movement here. Nil leaves the global mapping alone.
    tabnext = nil, ---@type string|nil
    tabprev = nil, ---@type string|nil
  },
  --- What happens when a full-tab takeover panel closes while it is the
  --- only pane left: "quit" (exit Neovim, like :q on the last file window),
  --- "dashboard" (try config.dashboard, :Dashboard, :Alpha, snacks.dashboard),
  --- "scratch" (empty buffer), or fun(win: integer) for a custom restore.
  restore = "quit",
  --- dsh runtime connection.
  dsh = {
    --- Explicit runtime argv; nil resolves an installed `dsh`, then the
    --- ~/workspace/deepseek-harness source checkout via pnpm.
    cmd = nil, ---@type string[]|nil
    profile = "sdk",
    --- Connect when the panel opens; false connects only on :NDSHRestart.
    auto_connect = true,
    provider = "deepseek-official",
    model = "deepseek-v4-flash",
    reasoning_effort = nil, ---@type string|nil
    max_tokens = nil, ---@type integer|nil
    --- Receive approval/request server prompts for every tool grant.
    approval = true,
    --- Receive user-question/ask server prompts.
    user_questions = true,
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
  assert(
    cfg.restore == "quit"
      or cfg.restore == "dashboard"
      or cfg.restore == "scratch"
      or type(cfg.restore) == "function",
    "ndsh: restore must be 'quit', 'dashboard', 'scratch' or a function"
  )
  return cfg
end

return M
