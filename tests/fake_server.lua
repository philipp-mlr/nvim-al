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
    local d = tonumber(os.getenv("FAKE_INIT_DELAY_MS") or "0")
    vim.defer_fn(function()
      send({ jsonrpc = "2.0", id = msg.id, result = { capabilities = capabilities } })
    end, d)
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
      if os.getenv("FAKE_LOAD_PROGRESS") == "1" then
        for _, m in ipairs({
          "Loading project 'A' ... \r\n    ",
          "Resolving reference closure ... \r\n",
        }) do
          send({
            jsonrpc = "2.0",
            method = "al/progressNotification",
            params = { owner = 0, percent = 0, message = m, cancel = false },
          })
        end
        send({
          jsonrpc = "2.0",
          method = "al/progressNotification",
          params = { owner = 0, percent = 100, message = "", cancel = false },
        })
      end
      if os.getenv("FAKE_DIAGS_FOR") then
        -- one warning and one hint for a file the editor has not opened
        local function d(sev, code, line)
          return {
            range = {
              start = { line = line, character = 0 },
              ["end"] = { line = line, character = 1 },
            },
            severity = sev,
            code = code,
            message = code,
          }
        end
        send({
          jsonrpc = "2.0",
          method = "textDocument/publishDiagnostics",
          params = {
            uri = os.getenv("FAKE_DIAGS_FOR"),
            diagnostics = { d(2, "AA0001", 0), d(4, "AA0248", 1), d(3, "AA0218", 2) },
          },
        })
      end
      if os.getenv("FAKE_BARE_URI") == "1" then
        -- what EditorServices does for an unresolved ruleset path: no scheme
        send({
          jsonrpc = "2.0",
          method = "textDocument/publishDiagnostics",
          params = { uri = "/x/app/${workspaceFolder}/../ruleset.json", diagnostics = {} },
        })
      end
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
  elseif m == "al/symbolSearch" then
    -- objects by default, members when memberKinds is given (like the real server)
    local f = msg.params.filters or {}
    local path = os.getenv("FAKE_SYMBOL_PATH")
    local symbols
    if f.memberKinds then
      symbols = {
        {
          kind = "Method",
          name = "Hello",
          containerName = "A_app",
          id = ":aaa:Codeunit:A_app.:Method:Hello",
          path = path,
        },
        {
          kind = "Method",
          name = "Insert",
          containerName = "Customer",
          id = ":base:Table:Customer.:Method:Insert",
        },
      }
    else
      symbols = {
        { kind = "Codeunit", name = "A_app", id = ":aaa:Codeunit:A_app", path = path },
        { kind = "Table", name = "Customer", id = ":base:Table:Customer" },
      }
    end
    send({ jsonrpc = "2.0", id = msg.id, result = { symbols = symbols, message = "" } })
  elseif m == "al/getApplicationObject" then
    local p = msg.params
    local result = vim.NIL
    if p.appId == "base" and p.type == "Table" and p.name == "Customer" then
      result = {
        name = "Customer",
        location = {
          uri = "al-preview://allang/base/Table/18/Customer.dal",
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
        },
      }
    end
    send({ jsonrpc = "2.0", id = msg.id, result = result })
  elseif m == "al/gotodefinition" and (os.getenv("FAKE_DEF") or "") == "type" then
    -- a variable use on line 5 -> its declaration on line 3 ("        Customer: Record Customer;"),
    -- the type name on line 3 -> the table
    local tdp = msg.params.textDocumentPositionParams
    local pos = tdp.position
    local result = vim.NIL
    if pos.line == 5 then
      result = {
        uri = tdp.textDocument.uri,
        range = { start = { line = 3, character = 8 }, ["end"] = { line = 3, character = 16 } },
      }
    elseif pos.line == 7 then
      result = {
        uri = tdp.textDocument.uri,
        range = { start = { line = 4, character = 8 }, ["end"] = { line = 4, character = 13 } },
      }
    elseif pos.line == 3 and pos.character >= 25 then
      result = {
        uri = "al-preview://allang/app/Table/18/Customer.al",
        range = { start = { line = 2, character = 4 }, ["end"] = { line = 2, character = 9 } },
      }
    end
    send({ jsonrpc = "2.0", id = msg.id, result = result })
  elseif m == "al/gotodefinition" then
    local mode = os.getenv("FAKE_DEF") or "file"
    local target = os.getenv("FAKE_DEF_TARGET")
    local range = { start = { line = 2, character = 4 }, ["end"] = { line = 2, character = 9 } }
    local result = vim.NIL
    if mode == "file" then
      result = { uri = vim.uri_from_fname(target), range = range }
    elseif mode == "preview" then
      result = { uri = "al-preview://allang/Base Application/Table/18/Customer.al", range = range }
    elseif mode == "preview_dal" then
      result = { uri = "al-preview://allang/app/Table/18/Customer.dal", range = range }
    elseif mode == "dal" then
      result = { uri = vim.uri_from_fname(vim.fs.dirname(target)) .. "/Thing.dal", range = range }
    end
    send({ jsonrpc = "2.0", id = msg.id, result = result })
  elseif m == "al/previewDocument" then
    send({
      jsonrpc = "2.0",
      id = msg.id,
      result = {
        content = "table 18 Customer\r\n{\r\n    // preview of " .. msg.params.Uri .. "\r\n}\r\n",
      },
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
