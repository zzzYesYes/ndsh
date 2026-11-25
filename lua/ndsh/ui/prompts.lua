--- Interactive prompts for server-to-client requests: tool approvals and
--- structured user questions, rendered through vim.ui so any UI plugin
--- (dressing, telescope, builtin) can present them.
local M = {}

---Pretty-print a raw arguments JSON string as indented one-line `key:
---value` rows (long values truncated); nil when undecodable.
---@param raw string
---@return string|nil
local function format_arguments(raw)
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  local keys = vim.tbl_keys(decoded)
  table.sort(keys)
  local lines = {}
  for _, k in ipairs(keys) do
    local v = decoded[k]
    if type(v) ~= "string" then
      v = vim.json.encode(v)
    end
    v = v:gsub("\n", "\\n")
    if #v > 120 then
      v = v:sub(1, 119) .. "…"
    end
    lines[#lines + 1] = ("  %s: %s"):format(k, v)
  end
  if #lines == 0 then
    return nil
  end
  return table.concat(lines, "\n")
end

--- approval/request: one-shot allow/reject/cancel for one tool operation.
--- When the tool/call event arrived first, `call` carries its arguments.
---@param params { toolName: string, reason: string|nil, callId: string|nil }
---@param respond fun(result: any|nil, err: table|nil)
---@param conv_name string|nil session the approval belongs to
---@param call { name: string, summary: string, arguments: string|nil }|nil
function M.approval(params, respond, conv_name, call)
  local choices = {
    { label = "Allow once", outcome = "allowed-once" },
    { label = "Reject", outcome = "rejected" },
    { label = "Cancel turn", outcome = "cancelled" },
  }
  local prompt = ("ndsh%s: allow %s?"):format(
    conv_name and (" [" .. conv_name .. "]") or "",
    params.toolName or "tool"
  )
  if params.reason then
    prompt = prompt .. "\n" .. params.reason
  end
  if call and call.arguments then
    local args = format_arguments(call.arguments)
    if args then
      prompt = prompt .. "\n" .. args
    end
  end
  vim.ui.select(choices, {
    prompt = prompt,
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if choice then
      respond({ outcome = choice.outcome })
    else
      -- Dismissal is never an approval; cancel the pending operation.
      respond({ outcome = "cancelled" })
    end
  end)
end

---Ask one question, then continue the batch.
---@param q table AskUserQuestionItem
---@param prefix string prompt prefix (session attribution)
---@param done fun(answer: table|nil) nil when dismissed
local function ask_one(q, prefix, done)
  local prompt = prefix .. (q.header and (q.header .. " — ") or "") .. (q.question or "")
  if q.detail then
    prompt = prompt .. "\n" .. q.detail
  end
  if q.options and #q.options > 0 then
    local labels = {}
    for _, opt in ipairs(q.options) do
      labels[#labels + 1] = opt.label or tostring(opt)
    end
    vim.ui.select(labels, { prompt = prompt }, function(_, idx)
      if idx then
        done({ id = q.id, selected = { labels[idx] } })
      else
        done(nil)
      end
    end)
  else
    vim.ui.input({ prompt = prompt .. " " }, function(text)
      if text and text ~= "" then
        done({ id = q.id, selected = {}, custom = text })
      elseif text == "" then
        done({ id = q.id, selected = {} })
      else
        done(nil)
      end
    end)
  end
end

--- user-question/ask: answer every question in order, or cancel the batch.
---@param params { questions: table[] }
---@param respond fun(result: any|nil, err: table|nil)
---@param conv_name string|nil session the questions belong to
function M.user_question(params, respond, conv_name)
  local answers = {}
  local questions = params.questions or {}
  local prefix = conv_name and ("[" .. conv_name .. "] ") or ""
  local i = 0
  local function step()
    i = i + 1
    if i > #questions then
      respond({ answers = answers })
      return
    end
    ask_one(questions[i], prefix, function(answer)
      if answer == nil then
        respond({ cancelled = true })
        return
      end
      answers[#answers + 1] = answer
      step()
    end)
  end
  step()
end

return M
