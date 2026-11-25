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
  input_height = 8,
  keys = {
    --- Send from the input buffer (insert and normal mode). Normal-mode
    --- <CR> also sends; insert-mode <CR> is always a plain newline.
    send = { "<C-s>" },
    --- No default keybindings: leader combos are user config. Bind in
    --- setup(), e.g. keys = { toggle = "<leader>ant", sessions =
    --- "<leader>ans", messages = "<leader>anm", resume = "<leader>anr",
    --- model = "<leader>anM", new_session = "<leader>ann" }.
    toggle = nil, ---@type string|nil
    sessions = nil, ---@type string|nil
    messages = nil, ---@type string|nil
    resume = nil, ---@type string|nil
    model = nil, ---@type string|nil
    reasoning = nil, ---@type string|nil
    new_session = nil, ---@type string|nil
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
  --- Path of the credentials/model-selection store; nil uses
  --- stdpath("data")/ndsh/credentials.json. Tests and isolated setups
  --- point this elsewhere.
  store_path = nil, ---@type string|nil
  --- Persist the session registry (sessions.json beside the store) so
  --- conversations resume after nvim restarts.
  persist_sessions = true,
  --- dsh runtime connection.
  dsh = {
    --- Explicit runtime argv; nil resolves an installed `dsh`, then the
    --- managed bootstrap runtime, then the ~/workspace/deepseek-harness
    --- source checkout via pnpm.
    cmd = nil, ---@type string[]|nil
    profile = "sdk",
    --- Connect at plugin load (and when the panel opens); false connects
    --- only on :NDSHRestart.
    auto_connect = true,
    --- Pins for the managed bootstrap runtime (:NDSHInstallRuntime): the
    --- @deepseek-ai/dsh npm version and the Node.js release that runs it.
    --- Bump together when the wire protocol moves.
    version = "0.2.2-rc.5",
    node_version = "26.13.1",
    provider = "deepseek-official",
    model = "deepseek-flash",
    --- Extra routes offered by :NDSHModel, e.g.
    --- { provider = "anthropic", model = "claude-sonnet-4-5", label = "Claude Sonnet" }.
    models = {}, ---@type table[]
    --- Reasoning effort sent at initialize; nil = server default. Switch it
    --- with :NDSHReasoning (restarts the runtime, like the model route).
    reasoning_effort = nil, ---@type string|nil
    --- Effort levels offered by :NDSHReasoning; ids are adapter-owned (the
    --- DeepSeek adapter supports off/low/high/max).
    reasoning_efforts = { "off", "low", "high", "max" },
    max_tokens = nil, ---@type integer|nil
    --- Receive approval/request server prompts for every tool grant.
    approval = true,
    --- Receive user-question/ask server prompts.
    user_questions = true,
    --- Extra environment for the runtime process; stored credentials for
    --- the active provider merge on top at spawn time.
    env = {}, ---@type table<string, string>
  },
  --- Providers offered by :NDSHConnect. `env` lists the variables the
  --- provider authenticates with; `default_model` prefill the model prompt.
  --- `models_url` + `auth` ("bearer" | "anthropic") enable live model
  --- discovery via the provider's catalog endpoint (all three answer with
  --- OpenAI's { data = [ { id } ] } shape).
  providers = {
    { id = "deepseek-official", label = "DeepSeek (official)", env = { "DEEPSEEK_API_KEY" }, default_model = "deepseek-flash", models_url = "https://api.deepseek.com/models", auth = "bearer" },
    { id = "anthropic", label = "Anthropic", env = { "ANTHROPIC_API_KEY" }, default_model = "claude-sonnet-4-5", models_url = "https://api.anthropic.com/v1/models", auth = "anthropic" },
    { id = "openai", label = "OpenAI", env = { "OPENAI_API_KEY" }, default_model = "gpt-5", models_url = "https://api.openai.com/v1/models", auth = "bearer" },
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
