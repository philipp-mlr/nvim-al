-- workspace/symbol and textDocument/typeDefinition for the AL server, which
-- answers neither: symbols come from al/symbolSearch (VS Code's symbol search
-- tool), dependency objects are located with al/getApplicationObject, and type
-- definition is two go-to-definition hops (variable -> declaration -> type).
local M = {}

local SK = vim.lsp.protocol.SymbolKind
local KIND = {
  Method = SK.Method,
  Field = SK.Field,
  Key = SK.Key,
  Action = SK.Event,
  Table = SK.Struct,
  TableExtension = SK.Struct,
  Enum = SK.Enum,
  EnumExtension = SK.Enum,
  Interface = SK.Interface,
}

-- object types a variable can be declared with: `X: Record "Name" temporary;`
local OBJECT_TYPES = {
  record = true,
  codeunit = true,
  page = true,
  report = true,
  query = true,
  xmlport = true,
  enum = true,
  interface = true,
  testpage = true,
  testrequestpage = true,
}

local function lines_of(fname)
  local b = vim.fn.bufnr(fname)
  if b > 0 and vim.api.nvim_buf_is_loaded(b) then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local ok, l = pcall(vim.fn.readfile, fname)
  return ok and l or {}
end

local function name_pattern(name)
  return '"?' .. vim.pesc(name) .. '"?'
end

--- 0-based line of a symbol in a source file (object header, procedure, field).
local function find_line(lines, sym)
  local n = name_pattern(sym.name)
  local pats
  if sym.kind == "Method" then
    pats = { "^%s*[%w%s]*procedure%s+" .. n .. "%s*%(" }
  elseif sym.kind == "Field" then
    pats = { "^%s*field%s*%(%s*%d+%s*;%s*" .. n .. "%s*;" }
  else
    pats = { "^%s*" .. sym.kind:lower() .. "%s+%d*%s*" .. n }
  end
  for i, l in ipairs(lines) do
    local low = l:lower()
    for _, p in ipairs(pats) do
      if low:find(p:lower()) then
        return i - 1
      end
    end
  end
  return 0
end

local MEMBER = { Method = true, Field = true, Key = true, Action = true }

--- App, object kind and object name of a symbol, from its al/symbolSearch id
--- ":<appId>:<Kind>:<Object>[.:<MemberKind>:<Member>]" (the name part is
--- escaped, so members take the object name from containerName).
local function owner_of(sym)
  local app, kind = (sym.id or ""):match("^:([^:]+):([^:]+):")
  if not app then
    return nil
  end
  return app, kind, MEMBER[sym.kind] and sym.containerName or sym.name
end

local function display(sym)
  if MEMBER[sym.kind] then
    return (sym.containerName or "?") .. "." .. sym.name
  end
  return sym.kind .. " " .. sym.name
end

local function range_at(line)
  return { start = { line = line, character = 0 }, ["end"] = { line = line, character = 0 } }
end

--- workspace/symbol through al/symbolSearch. Objects always; members (methods,
--- fields) too when the query is not empty.
---@param client vim.lsp.Client
---@param request fun(self, method, params, handler, bufnr) the unpatched client.request
function M.workspace_symbol(client, request, params, handler, bufnr)
  local query = params and params.query or ""
  local searches = { { query = query, filters = { limit = 200 } } }
  if query ~= "" then
    searches[2] = { query = query, filters = { memberKinds = { "Method", "Field" }, limit = 200 } }
  end
  local found, pending, first_err = {}, #searches, nil
  local ctx = { method = "workspace/symbol", client_id = client.id, bufnr = bufnr }

  local function finish()
    local out, unresolved = {}, {}
    for _, s in ipairs(found) do
      local item = {
        name = display(s),
        kind = KIND[s.kind] or SK.Class,
        containerName = s.namespace,
      }
      if s.path then
        local line = find_line(lines_of(s.path), s)
        item.location = { uri = vim.uri_from_fname(s.path), range = range_at(line) }
        out[#out + 1] = item
      else
        local app, kind, object = owner_of(s)
        if app then
          local key = app .. "|" .. kind .. "|" .. object
          unresolved[key] = unresolved[key]
            or { app = app, kind = kind, object = object, items = {} }
          table.insert(unresolved[key].items, item)
          out[#out + 1] = item
        end
      end
    end
    local left = vim.tbl_count(unresolved)
    local function done()
      out = vim.tbl_filter(function(i)
        return i.location ~= nil
      end, out)
      if handler then
        handler(first_err, out, ctx)
      end
    end
    if left == 0 then
      return done()
    end
    for _, u in pairs(unresolved) do
      request(
        client,
        "al/getApplicationObject",
        { appId = u.app, type = u.kind, name = u.object },
        function(_, res)
          if type(res) == "table" and type(res.location) == "table" then
            for _, item in ipairs(u.items) do
              item.location = { uri = res.location.uri, range = res.location.range or range_at(0) }
            end
          end
          left = left - 1
          if left == 0 then
            done()
          end
        end,
        bufnr
      )
    end
  end

  local ok, id
  for _, s in ipairs(searches) do
    ok, id = request(client, "al/symbolSearch", s, function(err, res)
      if err then
        first_err = first_err or err
      elseif type(res) == "table" and type(res.symbols) == "table" then
        vim.list_extend(found, res.symbols)
      end
      pending = pending - 1
      if pending == 0 then
        finish()
      end
    end, bufnr)
  end
  return ok, id
end

--- 0-based column of the object type name in a declaration line, or nil:
--- `    Customer: Record Customer temporary;` -> column of `Customer` after Record.
function M.type_column(line)
  local s = line:find(":", 1, true)
  if not s then
    return nil
  end
  local _, kw_end, kw = line:find("^%s*(%a+)%s+", s + 1)
  if not kw or not OBJECT_TYPES[kw:lower()] then
    return nil
  end
  local name_start = line:find('[%w"]', kw_end + 1)
  if not name_start then
    return nil
  end
  -- inside a quoted name, past the quote
  if line:sub(name_start, name_start) == '"' then
    name_start = name_start + 1
  end
  return name_start - 1
end

--- textDocument/typeDefinition: definition of the symbol at the cursor (its
--- declaration), then definition of the type named in that declaration.
---@param jump fun(uri: string, position: table, cb: fun(err, loc, ctx, config)) al/gotodefinition
function M.type_definition(params, jump, cb)
  jump(params.textDocument.uri, params.position, function(err, loc, ctx, config)
    if err or not loc or not loc.uri:match("^file:") then
      return cb(err, nil, ctx, config)
    end
    local line = lines_of(vim.uri_to_fname(loc.uri))[loc.range.start.line + 1] or ""
    local col = M.type_column(line)
    if not col then
      return cb(nil, nil, ctx, config)
    end
    jump(loc.uri, { line = loc.range.start.line, character = col }, cb)
  end)
end

return M
