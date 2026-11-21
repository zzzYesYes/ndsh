--- Pure projection from session events to writer operations.
--- Kept free of buffer/window access so it is testable and so the live
--- protocol layer and the dev harness share exactly one rendering path.
local M = {}

---Extract display text from string or content-block content.
---@param content string|table[]
---@return string
local function text_of(content)
  if type(content) == "string" then
    return content
  end
  if type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if block.type == "text" then
        parts[#parts + 1] = block.text
      end
    end
    return table.concat(parts, "\n")
  end
  return ""
end

---@class NdsOp
---@field op string
local _op

---Project one session event into ordered writer operations.
---Unknown event types project to nothing.
---@param event table
---@return table[]
function M.project(event)
  local t = event.type
  if t == "user/message" then
    return {
      { op = "begin_message", role = "user" },
      { op = "append", text = text_of(event.content) },
      { op = "end_message" },
    }
  elseif t == "assistant/message" then
    return {
      { op = "begin_message", role = "assistant" },
      { op = "append", text = text_of(event.content) },
      { op = "end_message" },
    }
  elseif t == "tool/call" then
    return {
      { op = "tool_begin", id = event.callId, name = event.name, summary = event.summary or "" },
    }
  elseif t == "tool/result" then
    return {
      { op = "tool_end", id = event.callId, ok = not event.isError, output = event.output or "" },
    }
  elseif t == "turn/start" then
    return { { op = "status", text = "running" } }
  elseif t == "turn/end" then
    return { { op = "status", text = "idle" } }
  end
  return {}
end

return M
