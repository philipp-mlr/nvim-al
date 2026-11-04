-- EditorServices language server: one client per workspace, the active
-- project follows the current buffer (docs/protocol.md §2).
local settings = require("nvim-al.settings")
local closure = require("nvim-al.closure")
local toolchain = require("nvim-al.toolchain")
local util = require("nvim-al.util")
local workspace = require("nvim-al.workspace")

local M = {}

local SEVERITY = { error = 1, warning = 2, info = 3, hint = 4 }

-- Full diagnostics per URI as last published, so opening a file can restore
-- what was filtered while it was closed.
---@type table<string, { result: table, ctx: table, config: table|nil }>
local full_diagnostics = {}

local function min_severity()
  local d = require("nvim-al").config().diagnostics or {}
  return SEVERITY[d.workspace_min_severity or "warning"] or 2
end

local function is_open(uri)
  local b = vim.uri_to_bufnr(uri)
  return vim.api.nvim_buf_is_loaded(b)
end

--- Forward diagnostics to Neovim, keeping only severe ones for closed files.
function M._publish_diagnostics(err, result, ctx, config)
  local handler = vim.lsp.handlers["textDocument/publishDiagnostics"]
  if err or type(result) ~= "table" or type(result.diagnostics) ~= "table" then
    return handler(err, result, ctx, config)
  end
  local min = min_severity()
  if min >= 4 then
    full_diagnostics[result.uri] = nil
    return handler(err, result, ctx, config)
  end
  full_diagnostics[result.uri] = { result = result, ctx = ctx, config = config }
  if is_open(result.uri) then
    return handler(err, result, ctx, config)
  end
  local kept = {}
  for _, d in ipairs(result.diagnostics) do
    if (d.severity or 1) <= min then
      kept[#kept + 1] = d
    end
  end
  return handler(err, vim.tbl_extend("force", result, { diagnostics = kept }), ctx, config)
end

--- A file was opened: show everything the server reported for it.
function M._restore_diagnostics(bufnr)
  local uri = vim.uri_from_bufnr(bufnr)
  local e = full_diagnostics[uri]
  if e and vim.lsp.get_client_by_id(e.ctx.client_id) then
    vim.lsp.handlers["textDocument/publishDiagnostics"](nil, e.result, e.ctx, e.config)
  end
end

vim.api.nvim_create_autocmd("BufReadPost", {
  group = vim.api.nvim_create_augroup("nvim-al.diagnostics", { clear = true }),
  pattern = "*.al",
  callback = function(a)
    M._restore_diagnostics(a.buf)
  end,
})

M.NAME = "nvim-al"

---@class nvim_al.ClientState
---@field ws nvim_al.Workspace
---@field active string|nil path of the active folder
---@field loaded boolean
---@field pending string|nil path of the folder whose al/setActiveWorkspace is in flight
---@field queued nvim_al.Folder|nil latest folder requested while one is pending
---@field ready boolean manifests sent, switching allowed
---@field deps_sent table<string, boolean> "<dep>|<parent>" pairs already configured

---@type table<integer, nvim_al.ClientState>
local states = {}

---@type table<string, boolean> workspace keys whose server exited with an error
local failed = {}

---@type table<string, nvim_al.Folder> folder to activate once a starting client is ready
local initial = {}

---@type table<integer, boolean> client ids nvim-al is stopping on purpose
local stopping = {}

--- Running (not stopping) nvim-al client for a workspace key.
local function client_for_key(key)
  for _, c in ipairs(vim.lsp.get_clients({ name = M.NAME, _uninitialized = true })) do
    if c.config._nvim_al_key == key and not c:is_stopped() then
      return c
    end
  end
end

local function cfg()
  return require("nvim-al").config()
end

local function folder_object(folder)
  return { uri = vim.uri_from_fname(folder.path), name = folder.name, index = folder.index }
end

---@param client_id integer
---@return nvim_al.ClientState|nil
function M.state(client_id)
  return states[client_id]
end

---@param bufnr integer
---@return vim.lsp.Client|nil
function M.client_for(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = M.NAME })[1]
end

--- Language server options from settings (protocol §2.1).
local function server_args(ws)
  local args = { "/sessionId:" .. vim.fn.sha256(ws.key .. tostring(vim.uv.hrtime())):sub(1, 32) }
  local s = settings.resolve(ws, ws.folders[1], cfg())
  local function opt(key, name)
    local v = s[key]
    if v ~= nil and v ~= vim.NIL then
      args[#args + 1] = ("/%s:%s"):format(name, tostring(v))
    end
  end
  args[#args + 1] = "/disableTelemetry"
  opt("al.editorServicesLogLevel", "logLevel")
  opt("al.inlayhints.parameterNames.enabled", "inlayHintsParameterNames")
  opt("al.inlayhints.functionReturnTypes.enabled", "inlayHintsFunctionReturnTypes")
  opt("al.semanticFolding.enabled", "semanticFolding")
  opt("al.extendGoToSymbolInWorkspace.enabled", "extendGoToSymbolInWorkspace")
  opt("al.extendGoToSymbolInWorkspace.ResultLimit", "extendGoToSymbolInWorkspaceResultLimit")
  opt(
    "al.extendGoToSymbolInWorkspace.IncludeSymbolFiles",
    "extendGoToSymbolInWorkspaceIncludeSymbolFiles"
  )
  return args
end

--- Configure every project reference of the active folder, walking the
--- reference graph depth-first; each dependency's parent is the project that
--- references it directly (as VS Code's loadProjectReferences does).
local function send_dependencies(client, st, active_folder)
  local visited = {}
  local function walk(parent)
    if visited[parent.path] then
      return
    end
    visited[parent.path] = true
    for _, dep in ipairs(closure.references(st.ws, parent)) do
      local key = dep.path .. "|" .. parent.path
      if not st.deps_sent[key] then
        st.deps_sent[key] = true
        client:notify("workspace/didChangeConfiguration", {
          settings = settings.payload(st.ws, dep, cfg(), { active = false, parent = parent.path }),
        })
      end
      walk(dep)
    end
  end
  walk(active_folder)
end

--- After a project becomes active again, the server works on its own copy of
--- that project's files and ignores a didOpen that raced the switch (verified
--- on 30.0). A full-text didChange after the switch is picked up, so send one
--- for every open buffer of the folder.
local function resync_buffers(client, folder)
  for b in pairs(client.attached_buffers) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and util.is_inside(name, folder.path) then
        local version = (vim.lsp.util.buf_versions[b] or 0) + 1
        vim.lsp.util.buf_versions[b] = version
        local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        if vim.bo[b].eol then
          text = text .. "\n"
        end
        client:notify("textDocument/didChange", {
          textDocument = { uri = vim.uri_from_bufnr(b), version = version },
          contentChanges = { { text = text } },
        })
      end
    end
  end
end

--- Make `folder` the active project (protocol §2.4 steps 4 and 5).
---@param client vim.lsp.Client
---@param folder nvim_al.Folder
---@param opts? { force?: boolean }
function M.switch(client, folder, opts)
  opts = opts or {}
  local st = states[client.id]
  if not st or not folder then
    return
  end
  if not st.ready or st.pending then
    st.queued = folder
    st.queued_force = st.queued_force or opts.force
    return
  end
  if folder.path == st.active and not opts.force then
    return
  end
  if opts.force then
    st.deps_sent = {}
  end
  st.pending = folder.path
  client:request("al/setActiveWorkspace", {
    currentWorkspaceFolderPath = folder_object(folder),
    settings = settings.payload(st.ws, folder, cfg(), { active = true }),
  }, function(err, result)
    st.pending = nil
    if not err and result and result.success then
      st.active = folder.path
      send_dependencies(client, st, folder)
      resync_buffers(client, folder)
    else
      util.notify(
        ("could not activate %s: %s"):format(folder.name, vim.inspect(err or result)),
        vim.log.levels.WARN
      )
    end
    local q, qf = st.queued, st.queued_force
    st.queued, st.queued_force = nil, nil
    if q then
      M.switch(client, q, { force = qf })
    end
  end)
end

local function load_manifests(client, st, done)
  local remaining = 0
  for _, f in ipairs(st.ws.folders) do
    if f.manifest then
      remaining = remaining + 1
    end
  end
  if remaining == 0 then
    return done()
  end
  for _, f in ipairs(st.ws.folders) do
    if f.manifest then
      client:request(
        "al/loadManifest",
        { projectFolder = f.path, manifest = f.manifest.raw },
        function()
          remaining = remaining - 1
          if remaining == 0 then
            done()
          end
        end
      )
    end
  end
end

local function handlers(client_state_of)
  return {
    ["al/activeProjectLoaded"] = function(_, _, ctx)
      local st = client_state_of(ctx.client_id)
      if st then
        st.loaded = true
      end
      return vim.NIL
    end,
    ["al/progressNotification"] = function(_, result, ctx)
      if type(result) ~= "table" then
        return
      end
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NvimAlProgress",
        data = { client_id = ctx.client_id, progress = result },
        modeline = false,
      })
      local st = client_state_of(ctx.client_id)
      if not st or result.owner ~= 0 then -- 0 = workspace loading (VS Code: OpenWorkspace)
        return
      end
      local feedback = require("nvim-al.feedback")
      local name = st.active and vim.fs.basename(st.active) or "AL"
      local folder = st.active and workspace.folder_for(st.ws, st.active)
      name = folder and folder.name or name
      if result.percent == 100 or result.cancel then
        if st.loading then
          st.loading:finish(
            not result.cancel,
            result.cancel and "loading cancelled" or "workspace loaded"
          )
          st.loading = nil
        end
        st.loaded = true
        return
      end
      local msg = vim.trim((result.message or ""):gsub("%s+", " "))
      local project = msg:match("^Loading project '([^']+)'")
      local phase = project and ("loading project '" .. project .. "'")
        or (msg:match("^Resolving reference closure") and "resolving references")
        or nil
      -- a running build/publish owns the message: show the reload as its phase
      local build = require("nvim-al.build")._active
      if build and build.client_id == ctx.client_id then
        if phase then
          build.progress:phase(phase)
        end
        return
      end
      if not st.loading then
        st.loading = feedback.progress("AL", name, phase or "loading workspace")
      elseif phase then
        st.loading:phase(phase)
      end
    end,
    ["al/symbolsMissing"] = function()
      util.notify_once(
        "symbolsMissing",
        "symbols are missing; run :AL symbols or check al.packageCachePath",
        vim.log.levels.WARN
      )
    end,
    ["al/manifestMissing"] = function()
      util.notify_once("manifestMissing", "app.json is missing for a project", vim.log.levels.WARN)
    end,
    -- EditorServices sometimes publishes plain paths instead of URIs (e.g. for a
    -- ruleset path with an unresolved ''${workspaceFolder}''); Neovim raises on those.
    ["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
      if type(result) == "table" and type(result.uri) == "string" then
        local uri = result.uri
        if not uri:match("^%a[%w+.-]*:") then
          if uri:find("${", 1, true) then
            return -- a settings path the server could not resolve: nothing to show
          end
          result.uri = vim.uri_from_fname(uri)
        end
      end
      return M._publish_diagnostics(err, result, ctx, config)
    end,
    ["window/logMessage"] = function(err, result, ctx, config)
      require("nvim-al.build").server_log(err, result, ctx)
      local default = vim.lsp.handlers["window/logMessage"]
      if default then
        return default(err, result, ctx, config)
      end
    end,
    ["al/projectsLoadedNotification"] = function() end,
    ["al/refreshExplorerObjects"] = function() end,
    ["al/updateTests"] = function() end,
  }
end

--- EditorServices sends completion labels as { label, description } objects;
--- the LSP spec (and every completion engine) needs a string.
local function flatten_labels(result)
  local items = type(result) == "table" and (result.items or result) or nil
  if type(items) ~= "table" then
    return
  end
  for _, item in ipairs(items) do
    if type(item) == "table" and type(item.label) == "table" then
      local desc = item.label.description
      item.label = item.label.label or ""
      if desc and desc ~= "" and not item.detail then
        item.detail = desc
      end
    end
  end
end

--- Wrap client.request so every caller (vim.lsp.completion, nvim-cmp, blink, request_sync)
--- receives string labels.
local function patch_completion(client)
  local orig = client.request
  client.request = function(self, method, params, handler, bufnr)
    if method == "textDocument/completion" or method == "completionItem/resolve" then
      local h = handler
      handler = function(err, result, ctx, config)
        if not err then
          if method == "completionItem/resolve" then
            flatten_labels({ result })
          else
            flatten_labels(result)
          end
        end
        if h then
          return h(err, result, ctx, config)
        end
        local default = vim.lsp.handlers[method]
        if default then
          return default(err, result, ctx, config)
        end
      end
    end
    return orig(self, method, params, handler, bufnr)
  end
end

--- Route textDocument/definition to al/gotodefinition (the server answers the
--- standard request with null), so vim.lsp.buf.definition(), LspAttach `gd`
--- mappings and pickers all work. Results become standard Locations; .dal file
--- results are fixed up, al-preview:// URIs open through BufReadCmd.
local function patch_definition(client)
  client.server_capabilities.definitionProvider = true
  local orig = client.request
  client.request = function(self, method, params, handler, bufnr)
    if method ~= "textDocument/definition" then
      return orig(self, method, params, handler, bufnr)
    end
    local body = {
      browserInfo = { browser = "SystemDefault", incognito = false },
      environmentInfo = { env = vim.NIL },
      textDocumentPositionParams = {
        textDocument = params.textDocument,
        position = params.position,
      },
    }
    local h = handler or vim.lsp.handlers[method]
    return orig(self, "al/gotodefinition", body, function(err, result, ctx, config)
      local loc = nil
      local definition = require("nvim-al.definition")
      if not err and type(result) == "table" and result.uri then
        loc = { uri = definition.fix_uri(result.uri), range = result.range }
      end
      ctx = vim.tbl_extend("force", ctx or {}, { method = method })
      if not h then
        return
      end
      if loc and definition.is_preview(loc.uri) then
        -- load the preview content first: the standard handler sets the cursor
        -- right after opening, which fails on a still-empty buffer
        return definition.preload(loc.uri, function()
          h(err, loc, ctx, config)
        end, self.id)
      end
      return h(err, loc, ctx, config)
    end, bufnr)
  end
end

local function start(ws, bufnr)
  local existing = client_for_key(ws.key)
  if existing then
    if not vim.lsp.buf_is_attached(bufnr, existing.id) then
      vim.lsp.buf_attach_client(bufnr, existing.id)
    end
    return existing
  end
  if failed[ws.key] then
    return nil -- crashed before: wait for :AL restart instead of respawning
  end
  local c = cfg()
  local cmd, err
  if c._host_cmd then
    cmd = vim.deepcopy(c._host_cmd)
  else
    local ok, rerr = toolchain.check_runtime(c)
    if not ok then
      cmd, err = nil, rerr
    else
      cmd, err = toolchain.host_cmd(c, server_args(ws))
    end
  end
  if not cmd then
    -- scheduled: an ERROR notify raises inside FileType autocmds otherwise
    vim.schedule(function()
      util.notify_once("toolchain:" .. tostring(err), err, vim.log.levels.ERROR)
    end)
    return nil
  end

  local folders = vim.tbl_map(function(f)
    return { uri = vim.uri_from_fname(f.path), name = f.name }
  end, ws.folders)

  local id = vim.lsp.start({
    name = M.NAME,
    cmd = cmd,
    cmd_cwd = ws.folders[1].path,
    root_dir = ws.folders[1].path,
    workspace_folders = folders,
    handlers = handlers(function(cid)
      return states[cid]
    end),
    -- Neovim answers server->client requests without a handler with MethodNotFound,
    -- which the server accepts as an answer (protocol §2.9).
    _nvim_al_key = ws.key,
    on_attach = function(_, b)
      require("nvim-al.definition").on_attach(b)
    end,
    on_init = function(client)
      local st = {
        ws = ws,
        active = nil,
        loaded = false,
        pending = nil,
        ready = false,
        deps_sent = {},
      }
      states[client.id] = st
      patch_completion(client)
      patch_definition(client)
      load_manifests(client, st, function()
        st.ready = true
        local q = st.queued or initial[ws.key]
        st.queued = nil
        initial[ws.key] = nil
        if q then
          M.switch(client, q)
        end
      end)
    end,
    on_exit = function(code, _, client_id)
      states[client_id] = nil
      initial[ws.key] = nil
      local intended = stopping[client_id]
      stopping[client_id] = nil
      if code ~= 0 and not intended then
        failed[ws.key] = true
        vim.schedule(function()
          util.notify(
            ("language server exited with code %d; :AL restart to try again"):format(code),
            vim.log.levels.ERROR
          )
        end)
      end
    end,
  }, {
    bufnr = bufnr,
    reuse_client = function(client, config)
      return client.name == M.NAME
        and not client:is_stopped()
        and client.config._nvim_al_key == config._nvim_al_key
    end,
  })
  return id and vim.lsp.get_client_by_id(id) or nil
end

--- Attach `bufnr` to the client of its workspace (starting it if needed) and
--- make its folder the active project.
---@param bufnr integer
---@return vim.lsp.Client|nil
function M.attach(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  name = util.normalize(vim.uv.fs_realpath(name) or name)
  local ws = workspace.resolve(name, { workspace_file = cfg().hooks.workspace_file })
  if not ws then
    util.notify_once("noapp:" .. name, "no app.json found for " .. name, vim.log.levels.WARN)
    return nil
  end
  local client = start(ws, bufnr)
  if not client then
    return nil
  end
  local folder = workspace.folder_for(ws, name)
  if folder then
    if states[client.id] then
      M.switch(client, folder)
    else
      -- on_init has not run yet: it activates this (latest) folder when ready
      initial[ws.key] = folder
    end
  end
  return client
end

--- Stop the client of a workspace and start it again for its buffers.
--- Also clears a previous crash so the server may start again.
---@param ws_key string
function M.restart(ws_key)
  failed[ws_key] = nil
  for _, client in ipairs(vim.lsp.get_clients({ name = M.NAME, _uninitialized = true })) do
    if client.config._nvim_al_key == ws_key then
      local bufs = vim.tbl_keys(client.attached_buffers)
      local id = client.id
      stopping[id] = true
      client:stop(true)
      -- is_stopped() is true at once; wait until the client is really gone
      vim.wait(5000, function()
        return vim.lsp.get_client_by_id(id) == nil
      end, 20)
      workspace.invalidate(ws_key)
      for _, b in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(b) then
          M.attach(b)
        end
      end
    end
  end
end

--- :AL restart for a buffer: restart its running client, or start one again
--- after a crash.
---@param bufnr integer
function M.restart_buffer(bufnr)
  local client = M.client_for(bufnr)
  if client then
    return M.restart(client.config._nvim_al_key)
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  name = util.normalize(vim.uv.fs_realpath(name) or name)
  local ws = workspace.resolve(name, { workspace_file = cfg().hooks.workspace_file })
  if ws then
    failed[ws.key] = nil
  end
  M.attach(bufnr)
end

--- Tell the server about folders added to or removed from the workspace file
--- (al/didChangeWorkspaceFolders, then al/loadManifest for new folders).
local function sync_folders(client, old, fresh)
  local before, after = {}, {}
  for _, f in ipairs(old.folders) do
    before[f.path] = f
  end
  for _, f in ipairs(fresh.folders) do
    after[f.path] = f
  end
  local added, removed = {}, {}
  for _, f in ipairs(fresh.folders) do
    if not before[f.path] then
      added[#added + 1] = f
    end
  end
  for _, f in ipairs(old.folders) do
    if not after[f.path] then
      removed[#removed + 1] = f
    end
  end
  if #added == 0 and #removed == 0 then
    return
  end
  local function objs(list)
    return vim.tbl_map(folder_object, list)
  end
  client:request(
    "al/didChangeWorkspaceFolders",
    { added = objs(added), removed = objs(removed) },
    function() end
  )
  for _, f in ipairs(added) do
    if f.manifest then
      client:request(
        "al/loadManifest",
        { projectFolder = f.path, manifest = f.manifest.raw },
        function() end
      )
    end
  end
  for _, f in ipairs(removed) do
    for b in pairs(client.attached_buffers) do
      local name = vim.api.nvim_buf_get_name(b)
      if util.is_inside(name, f.path) then
        vim.diagnostic.reset(nil, b)
      end
    end
  end
end

--- React to saved project files (app.json, workspace file, .vscode/settings.json).
---@param path string
function M.on_project_file_written(path)
  path = util.normalize(path)
  workspace.invalidate(path)
  for _, client in ipairs(vim.lsp.get_clients({ name = M.NAME, _uninitialized = true })) do
    local st = states[client.id]
    if st then
      local fresh = workspace.resolve(st.ws.folders[1].path, {
        workspace_file = cfg().hooks.workspace_file,
      })
      if fresh and fresh.key == st.ws.key then
        sync_folders(client, st.ws, fresh)
        st.ws = fresh
        if vim.fs.basename(path) == "app.json" then
          local f = workspace.folder_for(fresh, path)
          if f and f.manifest then
            client:request(
              "al/loadManifest",
              { projectFolder = f.path, manifest = f.manifest.raw },
              function() end
            )
          end
        end
        local active = st.active and workspace.folder_for(fresh, st.active)
        if active then
          M.switch(client, active, { force = true })
        end
      end
    end
  end
end

--- Stop all nvim-al clients (VimLeavePre).
function M.stop_all()
  for _, client in ipairs(vim.lsp.get_clients({ name = M.NAME, _uninitialized = true })) do
    stopping[client.id] = true
    client:stop(true)
  end
end

return M
