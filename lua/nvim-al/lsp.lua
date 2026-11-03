-- EditorServices language server: one client per workspace, the active
-- project follows the current buffer (docs/protocol.md §2).
local settings = require("nvim-al.settings")
local closure = require("nvim-al.closure")
local toolchain = require("nvim-al.toolchain")
local util = require("nvim-al.util")
local workspace = require("nvim-al.workspace")

local M = {}

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
      if type(result) == "table" then
        vim.api.nvim_exec_autocmds("User", {
          pattern = "NvimAlProgress",
          data = { client_id = ctx.client_id, progress = result },
          modeline = false,
        })
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

local function start(ws, bufnr)
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
      load_manifests(client, st, function()
        st.ready = true
        local q = st.queued
        st.queued = nil
        if q then
          M.switch(client, q)
        end
      end)
    end,
    on_exit = function(code, _, client_id)
      states[client_id] = nil
      if code ~= 0 then
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
      return client.name == M.NAME and client.config._nvim_al_key == config._nvim_al_key
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
    local st = states[client.id]
    if st then
      M.switch(client, folder)
    else
      -- on_init has not run yet: queue through a short retry
      local tries = 0
      local function retry()
        tries = tries + 1
        if states[client.id] then
          M.switch(client, folder)
        elseif tries < 200 and not client:is_stopped() then
          vim.defer_fn(retry, 10)
        end
      end
      retry()
    end
  end
  return client
end

--- Stop the client of a workspace and start it again for its buffers.
---@param ws_key string
function M.restart(ws_key)
  for _, client in ipairs(vim.lsp.get_clients({ name = M.NAME, _uninitialized = true })) do
    if client.config._nvim_al_key == ws_key then
      local bufs = vim.tbl_keys(client.attached_buffers)
      client:stop(true)
      vim.wait(3000, function()
        return client:is_stopped()
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
    client:stop(true)
  end
end

return M
