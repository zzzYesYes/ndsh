--- Interactive prompts for server-to-client requests: tool approvals and
--- structured user questions, rendered through vim.ui so any UI plugin
--- (dressing, telescope, builtin) can present them.
local M = {}

--- approval/request: one-shot allow/reject/cancel for one tool operation.
---@param params { toolName: string, reason: string|nil }
---@param respond fun(result: any|nil, err: table|nil)
function M.approval(params, respond)
  local choices = {
    { label = "Allow once", outcome = "allowed-once" },
    { label = "Reject", outcome = "rejected" },
    { label = "Cancel turn", outcome = "cancelled" },
  }
  local prompt = ("ndsh: allow %s?"):format(params.toolName or "tool")
  if params.reason then
    prompt = prompt .. "\n" .. params.reason
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
---@param done fun(answer: table|nil) nil when dismissed
local function ask_one(q, done)
  local prompt = (q.header and (q.header .. " — ") or "") .. (q.question or "")
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
function M.user_question(params, respond)
  local answers = {}
  local questions = params.questions or {}
  local i = 0
  local function step()
    i = i + 1
    if i > #questions then
      respond({ answers = answers })
      return
    end
    ask_one(questions[i], function(answer)
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
