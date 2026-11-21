--- Chat input area: a small modifiable nofile buffer. Sending is a keymap
--- that hands the complete buffer text to the session layer and clears it.
local M = {}

---Create the input buffer.
---@param cfg table resolved ndsh config
---@param on_send fun(text: string)
---@return integer buf
function M.create(cfg, on_send)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = buf })

  local function send()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
      return
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    on_send(text)
  end

  for _, key in ipairs(cfg.keys.send) do
    vim.keymap.set({ "i", "n" }, key, send, { buffer = buf, desc = "Send ndsh message" })
  end
  vim.keymap.set("n", "<CR>", send, { buffer = buf, desc = "Send ndsh message" })
  return buf
end

---Update the input window's status winbar.
---@param win integer
---@param text string e.g. "idle" or "running"
function M.set_status(win, text)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value("winbar", " ndsh · " .. text, { win = win })
  end
end

return M
