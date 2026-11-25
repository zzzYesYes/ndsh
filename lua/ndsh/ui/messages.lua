--- Message scanner (:NDSHMessages): telescope picker over the active
--- conversation's transcript when available, vim.ui.select otherwise.
--- Entries are the transcript's header blocks — user prompts, assistant
--- messages, tool calls — fuzzy-matchable by full message text; selecting
--- one jumps the chat pane to it.
local M = {}

local HEADERS = {
  ["❯ You"] = { kind = "user", icon = "❯", hl = "NDSHUserHeader" },
  ["● ndsh"] = { kind = "assistant", icon = "●", hl = "NDSHAssistantHeader" },
}

local TOOL_HL = { ["✓"] = "NDSHToolOk", ["✗"] = "NDSHToolErr", ["⠋"] = "NDSHToolRunning" }

---Fuzzy search stays useful on long answers without unbounded ordinals.
local ORDINAL_CAP = 4000

---Lines that close the current entry without starting one: reasoning,
---notices, error blocks. Tool headers match before this is consulted, so
---the ✗ prefix of an error block is not read as a failed tool.
---@param line string
---@return boolean
local function is_boundary(line)
  return line == "∴ thinking" or line:match("^─ .+ ─$") ~= nil or line:match("^✗ ") ~= nil
end

---Scan a transcript buffer into picker entries, newest first. The buffer is
---append-only and written solely by ndsh.ui.chat, so its headers are a
---reliable block structure; no write-path bookkeeping is needed.
---@param buf integer
---@return table[] entries { kind, icon, hl, lnum (1-based), text, ordinal }
function M.scan(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local entries = {}
  local cur = nil ---@type table|nil
  local function close()
    if not cur then
      return
    end
    while #cur.body > 0 and cur.body[#cur.body] == "" do
      cur.body[#cur.body] = nil
    end
    if cur.kind == "tool" then
      -- The folded output is noise for matching; the summary line carries it.
      cur.ordinal = cur.text
    else
      cur.text = cur.text or "(empty)"
      cur.ordinal = (cur.header .. "\n" .. table.concat(cur.body, "\n")):sub(1, ORDINAL_CAP)
    end
    cur.body = nil
    cur.header = nil
    entries[#entries + 1] = cur
    cur = nil
  end
  for i, line in ipairs(lines) do
    local spec = HEADERS[line]
    local summary
    if not spec then
      -- Tool icons are all 3-byte UTF-8; a plain byte slice avoids Lua
      -- pattern classes, which operate on bytes and split the characters.
      -- The " · " separator distinguishes tool lines from ✗ error blocks.
      local icon = line:sub(1, 3)
      if TOOL_HL[icon] and line:sub(4, 4) == " " then
        summary = line:sub(5)
        if summary:find(" · ", 1, true) then
          spec = { kind = "tool", icon = icon, hl = TOOL_HL[icon] }
        else
          summary = nil
        end
      end
    end
    if spec then
      close()
      cur = {
        kind = spec.kind,
        icon = spec.icon,
        hl = spec.hl,
        lnum = i,
        header = line,
        text = summary,
        body = {},
      }
    elseif is_boundary(line) then
      close()
    elseif cur then
      cur.body[#cur.body + 1] = line
      if not cur.text and line:match("%S") then
        cur.text = line
      end
    end
  end
  close()
  -- Newest first: scanning usually targets recent messages.
  local reversed = {}
  for i = #entries, 1, -1 do
    reversed[#reversed + 1] = entries[i]
  end
  return reversed
end

---Jump to the next/previous transcript block relative to the cursor in the
---window showing buf, one way only — no wrap at the ends. Forward lands a
---tool block on its first folded output line (opened with zv); backward
---always lands on block headers, so backing out of an output never stalls.
---@param buf integer chat buffer
---@param dir integer 1 forward, -1 backward
---@param count integer blocks to move
function M.goto_block(buf, dir, count)
  local scanned = M.scan(buf) -- newest first; navigation needs buffer order
  local entries = {}
  for i = #scanned, 1, -1 do
    entries[#entries + 1] = scanned[i]
  end
  if #entries == 0 then
    vim.notify("ndsh: no messages yet", vim.log.levels.INFO)
    return
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end
  local function step(line)
    if dir == 1 then
      for _, e in ipairs(entries) do
        if e.lnum > line then
          return e
        end
      end
      return nil
    end
    for i = #entries, 1, -1 do
      if entries[i].lnum < line then
        return entries[i]
      end
    end
    return nil
  end
  -- Forward lands a tool block on its first folded output line (fold
  -- opened); backward always lands on the block header, so K from inside an
  -- output backs out to its header instead of stalling on the same line.
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local entry = step(cur)
  for _ = 2, count do
    if not entry then
      break
    end
    entry = step(entry.lnum)
  end
  if not entry then
    return
  end
  local target = entry.lnum
  if dir == 1 and entry.kind == "tool" then
    local next_line = vim.api.nvim_buf_get_lines(buf, target, target + 1, false)[1]
    if next_line and next_line:sub(1, 6) == "  │ " then
      target = target + 1
    end
  end
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zvzz")
  end)
end

---Open the message picker for a conversation. Calls on_select(entry) with
---the chosen entry.
---@param conv table
---@param on_select fun(entry: table)
function M.open(conv, on_select)
  local buf = conv.chat_buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    vim.notify("ndsh: no transcript for this session", vim.log.levels.INFO)
    return
  end
  local entries = M.scan(buf)
  if #entries == 0 then
    vim.notify("ndsh: no messages yet", vim.log.levels.INFO)
    return
  end
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    vim.ui.select(entries, {
      prompt = "ndsh: messages",
      format_item = function(e)
        return ("%s %s"):format(e.icon, e.text)
      end,
    }, function(e)
      if e then
        on_select(e)
      end
    end)
    return
  end
  local finders = require("telescope.finders")
  local previewers = require("telescope.previewers")
  local entry_display = require("telescope.pickers.entry_display")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local displayer = entry_display.create({
    separator = " ",
    items = {
      { width = 1 }, -- kind icon, highlighted per role
      { remaining = true },
    },
  })
  local ns = vim.api.nvim_create_namespace("ndsh_messages_preview")
  pickers
    .new({}, {
      prompt_title = ("ndsh messages — %s"):format(conv.name),
      finder = finders.new_table({
        results = entries,
        entry_maker = function(e)
          return {
            value = e,
            ordinal = e.ordinal,
            display = function()
              return displayer({
                { e.icon, e.hl },
                e.text,
              })
            end,
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewers.new_buffer_previewer({
        title = "transcript",
        define_preview = function(self, entry)
          local pbuf = self.state.bufnr
          local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
          local lnum = math.min(entry.value.lnum, #lines)
          vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
          vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
          vim.api.nvim_buf_add_highlight(pbuf, ns, "Visual", lnum - 1, 0, -1)
          pcall(vim.treesitter.start, pbuf, "markdown")
          -- Telescope installs a fresh preview buffer and swaps it into the
          -- preview window on a later tick. Moving the cursor now would aim
          -- at whatever buffer the window still shows — often a one-line
          -- scratch buffer — and fail with "Invalid cursor line". Land the
          -- jump once the swap has happened; a newer selection (which
          -- schedules its own swap and jump) or a closed picker is skipped.
          vim.schedule(function()
            local win = self.state.winid
            if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(pbuf)) then
              return
            end
            if vim.api.nvim_win_get_buf(win) ~= pbuf then
              return
            end
            pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
          end)
        end,
      }),
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
