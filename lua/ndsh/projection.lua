--- Pure projection from session events to writer operations.
--- Kept free of buffer/window access so it is testable and so the live
--- protocol layer and the dev harness share exactly one rendering path.
--- Event shapes follow the dsh SessionEvent envelope: { type, seq, time, data }.
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
        parts[#parts + 1] = block.text or ""
      end
    end
    return table.concat(parts, "\n")
  end
  return ""
end

---One-line summary of a raw arguments JSON string for the tool header.
---@param raw string
---@return string
local function summarize_arguments(raw)
  local line = raw:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #line > 80 then
    return line:sub(1, 79) .. "…"
  end
  return line
end

---Project one session event into ordered writer operations.
---Unknown event types project to nothing.
---@param event table SessionEvent envelope
---@return table[]
function M.project(event)
  local t = event.type
  local d = event.data or {}
  if t == "user/message" then
    -- Synthetic user-role context (agent.inject, skill content, ...) stays
    -- off the transcript; only direct human prompts render as "You".
    if d.source and d.source.kind ~= "user" then
      return {}
    end
    return {
      { op = "begin_message", role = "user" },
      { op = "append", text = text_of(d.content) },
      { op = "end_message" },
    }
  elseif t == "assistant/message" then
    local message = d.message or {}
    return {
      { op = "begin_message", role = "assistant" },
      { op = "append", text = text_of(message.content) },
      { op = "end_message" },
    }
  elseif t == "tool/call" then
    return {
      { op = "tool_begin", id = d.callId, name = d.name, summary = summarize_arguments(d.arguments or "") },
    }
  elseif t == "tool/result" then
    local message = d.message or {}
    return {
      { op = "tool_end", id = message.toolCallId, ok = not message.isError, output = text_of(message.content) },
    }
  elseif t == "turn/start" then
    return { { op = "status", text = "running" } }
  elseif t == "turn/end" then
    return { { op = "status", text = "idle" } }
  end
  return {}
end

return M
