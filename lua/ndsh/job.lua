--- Process job for the dsh runtime: spawn, newline-delimited framing, kill.
--- stdout arrives in arbitrary chunks; complete \n-terminated lines are
--- frames, and the trailing partial line is carried to the next chunk.
local M = {}
M.__index = M

---Build a framing feeder. Pure and exported for unit tests.
---@param on_frame fun(line: string) called with each complete non-empty line
---@return fun(data: string[]) feed for jobstart on_stdout data chunks
function M.framer(on_frame)
  local partial = ""
  return function(data)
    if not data or #data == 0 then
      return
    end
    data[1] = partial .. data[1]
    partial = table.remove(data) or ""
    for _, line in ipairs(data) do
      if line ~= "" then
        on_frame(line)
      end
    end
  end
end

---Spawn the runtime process.
---@param cmd string[] argv
---@param opts { on_frame: fun(line: string), on_stderr: fun(line: string)|nil, on_exit: fun(code: integer)|nil }
---@return NdsJob
function M.spawn(cmd, opts)
  local self = setmetatable({ cmd = cmd }, M)
  local feed = M.framer(opts.on_frame)
  local job_id = vim.fn.jobstart(cmd, {
    stdin = "pipe",
    stdout_buffered = false,
    on_stdout = function(_, data)
      feed(data)
    end,
    on_stderr = opts.on_stderr and function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          opts.on_stderr(line)
        end
      end
    end or nil,
    on_exit = function(_, code)
      if opts.on_exit then
        opts.on_exit(code)
      end
    end,
  })
  if job_id <= 0 then
    error(("ndsh: failed to spawn %s"):format(table.concat(cmd, " ")))
  end
  self.job_id = job_id
  return self
end

---Send one frame.
---@param line string
function M:send(line)
  -- The channel may already be closed if the runtime died underneath us.
  pcall(vim.fn.chansend, self.job_id, line .. "\n")
end

function M:kill()
  if self.job_id then
    pcall(vim.fn.jobstop, self.job_id)
    self.job_id = nil
  end
end

return M
