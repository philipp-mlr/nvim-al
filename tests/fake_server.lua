-- A fake EditorServices language server for unit tests. Run with `nvim -l`.
-- Records every message it receives (one JSON object per line) to $FAKE_LOG.
-- Behaviour switches (env):
--   FAKE_DELAY_MS   delay before answering al/setActiveWorkspace (default 200)
--   FAKE_EXIT_CODE  exit with this code right after `initialized`
--   FAKE_ASK_LOADED send an al/activeProjectLoaded request after the first switch
local log_path = assert(os.getenv("FAKE_LOG"), "FAKE_LOG not set")
local delay = tonumber(os.getenv("FAKE_DELAY_MS") or "200")
local exit_code = tonumber(os.getenv("FAKE_EXIT_CODE") or "")
local ask_loaded = os.getenv("FAKE_ASK_LOADED") == "1"

local uv = vim.uv
local stdin = uv.new_pipe(false)
local stdout = uv.new_pipe(false)
stdin:open(0)
stdout:open(1)

local function record(msg)
  local f = io.open(log_path, "a")
  f:write(vim.json.encode(msg), "\n")
  f:close()
end

local function send(msg)
  local body = vim.json.encode(msg)
  stdout:write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
end

local capabilities = {
  textDocumentSync = 2,
  hoverProvider = true,
  definitionProvider = false,
  referencesProvider = true,
  documentHighlightProvider = true,
  documentSymbolProvider = true,
  codeActionProvider = true,
  documentFormattingProvider = true,
  documentRangeFormattingProvider = true,
  renameProvider = true,
}

local server_req_id = 1000
local asked = false

local function handle(msg)
  record(msg)
  local m = msg.method
  if m == "initialize" then
    send({ jsonrpc = "2.0", id = msg.id, result = { capabilities = capabilities } })
  elseif m == "initialized" then
    if exit_code then
      vim.defer_fn(function()
        os.exit(exit_code)
      end, 50)
    end
  elseif m == "shutdown" then
    send({ jsonrpc = "2.0", id = msg.id, result = vim.NIL })
  elseif m == "exit" then
    os.exit(0)
  elseif m == "al/setActiveWorkspace" then
    vim.defer_fn(function()
      send({ jsonrpc = "2.0", id = msg.id, result = { success = true } })
      if ask_loaded and not asked then
        asked = true
        server_req_id = server_req_id + 1
        send({ jsonrpc = "2.0", id = server_req_id, method = "al/activeProjectLoaded", params = {} })
      end
    end, delay)
  elseif m == "al/loadManifest" then
    send({
      jsonrpc = "2.0",
      id = msg.id,
      result = { success = true, manifest = msg.params.manifest },
    })
  elseif m == "textDocument/completion" then
    send({
      jsonrpc = "2.0",
      id = msg.id,
      result = {
        isIncomplete = false,
        items = {
          { label = { label = '"No." (PK1)', description = "" }, insertText = '"No."', kind = 5 },
          { label = "Description", kind = 5 },
        },
      },
    })
  elseif msg.id and m then
    send({ jsonrpc = "2.0", id = msg.id, result = { success = true } })
  end
  -- responses from the client (to our requests) are only recorded
end

local buf = ""
stdin:read_start(function(err, chunk)
  assert(not err, err)
  if not chunk then
    os.exit(0)
  end
  buf = buf .. chunk
  while true do
    local header_end = buf:find("\r\n\r\n", 1, true)
    if not header_end then
      return
    end
    local len = tonumber(buf:sub(1, header_end):match("Content%-Length: (%d+)"))
    if #buf < header_end + 3 + len then
      return
    end
    local body = buf:sub(header_end + 4, header_end + 3 + len)
    buf = buf:sub(header_end + 4 + len)
    vim.schedule(function()
      handle(vim.json.decode(body))
    end)
  end
end)

while true do
  vim.wait(1000)
end
