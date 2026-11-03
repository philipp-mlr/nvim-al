-- Go to definition through al/gotodefinition, and read-only buffers for
-- al-preview:// documents (objects inside symbol packages). docs/protocol.md §2.6
local util = require("nvim-al.util")

local M = {}

local PREVIEW = "al-preview://"

local function lsp()
  return require("nvim-al.lsp")
end

--- The client for a buffer. Preview buffers have no workspace of their own:
--- they use the client that produced them (vim.b.nvim_al_client), so with two
--- workspaces open a preview never talks to the other server.
local function any_client(bufnr)
  local id = vim.b[bufnr].nvim_al_client
  local owner = id and vim.lsp.get_client_by_id(id)
  if owner and not owner:is_stopped() then
    return owner
  end
  return lsp().client_for(bufnr) or vim.lsp.get_clients({ name = lsp().NAME })[1]
end

--- Remember which client a preview buffer belongs to.
local function claim(buf, client_id)
  if client_id then
    vim.b[buf].nvim_al_client = client_id
  end
end

--- Active nvim-dap session of an AL adapter, if any.
local function al_debug_session()
  local ok, dap = pcall(require, "dap")
  if not ok then
    return nil
  end
  local s = dap.session()
  if s and s.config and s.config.type == "al" then
    return s
  end
end

---@type table<integer, fun()[]>
local waiting = {}

local function fill(buf, content)
  local text = (content or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

--- Load the content of an al-preview:// buffer from the language server, or
--- from the debug adapter while an AL debug session runs.
---@param buf integer
---@param uri string
---@param on_done? fun()
function M.load_preview(buf, uri, on_done)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "al"
  vim.bo[buf].modifiable = false -- read-only from the start, not only once content arrives
  if on_done then
    waiting[buf] = waiting[buf] or {}
    table.insert(waiting[buf], on_done)
  end
  if vim.b[buf].nvim_al_loading then
    return -- a load is already in flight; on_done runs when it finishes
  end
  vim.b[buf].nvim_al_loading = true
  local function done(content)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.b[buf].nvim_al_loading = false
    if content then
      fill(buf, content)
    end
    -- attach once the buffer is loaded and filled, so hover works inside previews
    local c = any_client(buf)
    if c and vim.api.nvim_buf_is_loaded(buf) and not vim.lsp.buf_is_attached(buf, c.id) then
      vim.lsp.buf_attach_client(buf, c.id)
    end
    local cbs = waiting[buf] or {}
    waiting[buf] = nil
    for _, cb in ipairs(cbs) do
      cb()
    end
  end
  local session = al_debug_session()
  if session then
    session:request("al/previewDocument", { Uri = uri }, function(err, result)
      done(not err and result and result.content or nil)
    end)
    return
  end
  local client = any_client(buf)
  if not client then
    util.notify("no AL language server running for " .. uri, vim.log.levels.WARN)
    return
  end
  client:request("al/previewDocument", { Uri = uri }, function(err, result)
    if err or not result then
      util.notify("could not load " .. uri, vim.log.levels.WARN)
      return done(nil)
    end
    done(result.content)
  end, buf)
end

--- Open an al-preview:// URI in the current window.
---@param uri string
---@param on_done? fun(buf: integer)
---@return integer bufnr
---@param client_id? integer client that returned the URI
function M.open_preview(uri, on_done, client_id)
  local buf = vim.fn.bufadd(uri)
  vim.b[buf].nvim_al_preview = true
  claim(buf, client_id)
  local loaded = vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_line_count(buf) > 1
  -- Register the callback first: switching to the buffer fires BufReadCmd,
  -- which starts the load (or the load starts here when the plugin is not sourced).
  M.load_preview(buf, uri, function()
    if on_done then
      on_done(buf)
    end
  end)
  vim.api.nvim_set_current_buf(buf)
  if loaded and on_done then
    on_done(buf)
  end
  return buf
end

local function set_cursor(range)
  if not range then
    return
  end
  local line = range.start.line + 1
  local col = range.start.character
  local max = vim.api.nvim_buf_line_count(0)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, max), col })
end

--- A .dal result keeps its last segment literally: join it to the parsed parent.
local function fix_dal(uri)
  if uri:lower():sub(-4) ~= ".dal" then
    return uri
  end
  local slash = uri:match(".*()/")
  local parent, last = uri:sub(1, slash - 1), uri:sub(slash + 1)
  return vim.uri_from_fname(vim.uri_to_fname(parent) .. "/" .. vim.uri_decode(last))
end

---@param uri string
---@return boolean
function M.is_preview(uri)
  return uri:sub(1, #PREVIEW) == PREVIEW
end

--- Load an al-preview:// buffer (without showing it), then call on_done.
---@param uri string
---@param on_done fun(buf: integer)
---@param client_id? integer client that returned the URI
function M.preload(uri, on_done, client_id)
  local buf = vim.fn.bufadd(uri)
  vim.b[buf].nvim_al_preview = true
  claim(buf, client_id)
  if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_line_count(buf) > 1 then
    return on_done(buf)
  end
  -- register first: bufload fires BufReadCmd, which may start the load itself
  M.load_preview(buf, uri, function()
    on_done(buf)
  end)
  vim.fn.bufload(buf)
end

--- Normalise a URI returned by al/gotodefinition (preview URIs unchanged).
---@param uri string
---@return string
function M.fix_uri(uri)
  if uri:sub(1, #PREVIEW) == PREVIEW then
    return uri
  end
  return fix_dal(uri)
end

--- Go to the definition of the symbol under the cursor.
---@param bufnr? integer
function M.jump(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local client = any_client(bufnr)
  if not client then
    return util.notify("no AL language server for this buffer", vim.log.levels.WARN)
  end
  local params = {
    browserInfo = { browser = "SystemDefault", incognito = false },
    environmentInfo = { env = vim.NIL },
    textDocumentPositionParams = vim.lsp.util.make_position_params(0, client.offset_encoding),
  }
  client:request("al/gotodefinition", params, function(err, result)
    if err or type(result) ~= "table" or not result.uri then
      vim.notify("No definition found")
      return
    end
    vim.cmd("normal! m'")
    local uri = result.uri
    if uri:sub(1, #PREVIEW) == PREVIEW then
      M.open_preview(uri, function()
        set_cursor(result.range)
      end, client.id)
      return
    end
    uri = fix_dal(uri)
    vim.lsp.util.show_document({ uri = uri, range = result.range }, client.offset_encoding, {
      focus = true,
    })
  end, bufnr)
end

--- tagfunc: <C-]> (and :tag under the cursor) use al/gotodefinition.
--- Synchronous so Neovim gets a real tag entry and pushes the tag stack;
--- preview targets are loaded first so the tag can point into them.
function M.tagfunc(_, flags)
  if not flags:find("c", 1, true) then
    return vim.NIL -- not a cursor lookup: let Neovim use tags files
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local client = any_client(bufnr)
  if not client then
    return vim.NIL
  end
  local params = {
    browserInfo = { browser = "SystemDefault", incognito = false },
    environmentInfo = { env = vim.NIL },
    textDocumentPositionParams = vim.lsp.util.make_position_params(0, client.offset_encoding),
  }
  local res = client:request_sync("al/gotodefinition", params, 10000, bufnr)
  local r = res and res.result
  if type(r) ~= "table" or not r.uri then
    return vim.NIL
  end
  local uri = M.fix_uri(r.uri)
  local filename
  if M.is_preview(uri) then
    local done = false
    M.preload(uri, function()
      done = true
    end, client.id)
    vim.wait(10000, function()
      return done
    end, 20)
    filename = uri
  else
    filename = vim.uri_to_fname(uri)
  end
  local line = r.range and r.range.start.line + 1 or 1
  local col = r.range and r.range.start.character + 1 or 1
  local word = vim.fn.expand("<cword>")
  return {
    {
      name = word ~= "" and word or "definition",
      filename = filename,
      cmd = ("call cursor(%d, %d)"):format(line, col),
    },
  }
end

--- Buffer-local setup on attach: gd and tagfunc, unless the user mapped gd.
---@param bufnr integer
function M.on_attach(bufnr)
  local existing = vim.fn.maparg("gd", "n", false, true)
  if vim.tbl_isempty(existing) then
    vim.keymap.set("n", "gd", function()
      M.jump(bufnr)
    end, { buffer = bufnr, desc = "AL: go to definition" })
  end
  vim.bo[bufnr].tagfunc = "v:lua.require'nvim-al.definition'.tagfunc"
end

return M
