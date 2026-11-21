--- JSON-RPC 2.0 client over a line transport, matching the dsh SDK wire:
--- one message per \n-terminated line; malformed lines are ignored.
--- Server-to-client requests are answered asynchronously through respond().
local M = {}
M.__index = M

---@param transport { send: fun(line: string) }
---@param handlers { on_notification: fun(method: string, params: any), on_request: fun(method: string, params: any, respond: fun(result: any|nil, err: table|nil)) }
function M.new(transport, handlers)
  return setmetatable({
    transport = transport,
    handlers = handlers,
    next_id = 0,
    pending = {}, ---@type table<any, fun(result: any, err: table|nil)>
  }, M)
end

local function encode(msg)
  return vim.json.encode(msg)
end

---Handle one incoming frame.
---@param line string
function M:handle_line(line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    return
  end
  if msg.id ~= nil and msg.method ~= nil then
    -- Server-to-client request: the handler answers through respond(),
    -- possibly much later (e.g. after a vim.ui prompt).
    self.handlers.on_request(msg.method, msg.params, function(result, err)
      if err then
        self.transport.send(encode({ jsonrpc = "2.0", id = msg.id, error = err }))
      else
        if result == nil then
          result = vim.empty_dict()
        end
        self.transport.send(encode({ jsonrpc = "2.0", id = msg.id, result = result }))
      end
    end)
  elseif msg.id ~= nil then
    local cb = self.pending[msg.id]
    if not cb then
      return
    end
    self.pending[msg.id] = nil
    if msg.error then
      cb(nil, msg.error)
    else
      cb(msg.result, nil)
    end
  elseif msg.method ~= nil then
    self.handlers.on_notification(msg.method, msg.params)
  end
end

---Send a request.
---@param method string
---@param params table|nil
---@param cb fun(result: any, err: table|nil)
function M:request(method, params, cb)
  self.next_id = self.next_id + 1
  local id = self.next_id
  self.pending[id] = cb
  self.transport.send(encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  }))
end

---Reject every pending request (e.g. the transport died).
---@param err table
function M:fail_all(err)
  local pending = self.pending
  self.pending = {}
  for _, cb in pairs(pending) do
    cb(nil, err)
  end
end

return M
