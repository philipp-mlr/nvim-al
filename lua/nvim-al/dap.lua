-- Debugging with nvim-dap: the AL debug adapter is EditorServices.Host started
-- with /startDebugging (docs/protocol.md §3). Loaded only when nvim-dap exists.
local credentials = require("nvim-al.credentials")
local launch = require("nvim-al.launch")
local toolchain = require("nvim-al.toolchain")
local util = require("nvim-al.util")
local workspace = require("nvim-al.workspace")

local M = {}

local KEY = "nvim-al"
local done = false

---@type table<integer, boolean> adapter process ids started by nvim-al
local pids = {}

local function cfg()
  return require("nvim-al").config()
end

--- Workspace and folder of a buffer, or nil.
local function locate(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  name = util.normalize(vim.uv.fs_realpath(name) or name)
  local ws = workspace.resolve(name, { workspace_file = cfg().hooks.workspace_file })
  if not ws then
    return nil
  end
  return ws, workspace.folder_for(ws, name) or ws.folders[1]
end

--- A resolved nvim-dap configuration for a target.
local function to_dap_config(target, folder)
  local c = vim.deepcopy(target.raw)
  c.type = "al"
  c.name = target.name
  c.__nvim_al_folder = folder.path
  return c
end

--- Configurations for the current buffer's project (nvim-dap provider).
---@param bufnr integer
---@return table[]
function M.configurations(bufnr)
  local ws, folder = locate(bufnr)
  if not ws then
    return {}
  end
  local out = {}
  for _, raw in ipairs(launch.configurations(ws, folder, cfg())) do
    local t, err = launch.resolve(raw, ws, folder)
    if t then
      out[#out + 1] = to_dap_config(t, folder)
    else
      util.notify_once(
        "dapcfg:" .. folder.path .. ":" .. (raw.name or ""),
        err:gsub("^nvim%-al: ", ""),
        vim.log.levels.WARN
      )
    end
  end
  return out
end

local function save_project_buffers(folder_path)
  require("nvim-al.build")._save_project_buffers({ path = folder_path })
end

--- nvim-dap adapter function: start the AL debug adapter for config.__nvim_al_folder.
local function adapter(callback, config)
  local folder = config.__nvim_al_folder
  if not folder then
    local _, f = locate(vim.api.nvim_get_current_buf())
    folder = f and f.path
  end
  if not folder then
    return util.notify("no AL project for this debug configuration", vim.log.levels.ERROR)
  end
  local cmd, err =
    toolchain.host_cmd(cfg(), { "/startDebugging", "/disableTelemetry", "/projectRoot:" .. folder })
  if not cmd then
    return util.notify(err, vim.log.levels.ERROR)
  end
  local target = {
    name = config.name,
    server = config.server,
    port = config.port,
    serverInstance = config.serverInstance,
    tenant = config.tenant,
    authentication = config.authentication,
  }
  credentials.env(target, function(extra)
    if not extra then
      return util.notify("debugging cancelled (no credentials)", vim.log.levels.WARN)
    end
    if config.request == "launch" then
      save_project_buffers(folder)
    end
    -- nvim-dap hands options.env to uv.spawn unchanged, which wants "KEY=VALUE"
    -- strings; a map is silently ignored (the adapter then has no credentials).
    local env = {}
    for k, v in pairs(vim.tbl_extend("force", vim.fn.environ(), extra)) do
      env[#env + 1] = k .. "=" .. v
    end
    table.sort(env)
    callback({
      type = "executable",
      command = cmd[1],
      args = vim.list_slice(cmd, 2),
      -- The adapter uses its working directory as package cache root when
      -- al.packageCachePath is not passed: it must be the project folder.
      options = { cwd = folder, env = env, detached = false },
    })
  end)
end

local function server_key(c)
  return table.concat({ c.server or "", tostring(c.port or ""), c.serverInstance or "" }, "|")
end

--- Only one adapter per environment: an older armed one takes the next break.
local function check_single(config)
  local dap = require("dap")
  for _, s in pairs(dap.sessions() or {}) do
    if s.config and s.config.type == "al" and server_key(s.config) == server_key(config) then
      local choice
      vim.ui.select({ "Stop the other session", "Cancel" }, {
        prompt = "An AL debug session for this environment is already running",
      }, function(c)
        choice = c
      end)
      if choice == "Stop the other session" then
        s:close()
        return true
      end
      return false
    end
  end
  return true
end

--- The AL adapter omits `command` in some responses (attach, launch, …).
--- nvim-dap looks listeners up by `decoded.command` and fails on nil. Put it
--- back: from requests sent through this wrapper, or else (for the attach/launch
--- request sent before the session reached us) from the request arguments
--- nvim-dap still holds for that seq, whose `request` field names it.
---@param session table nvim-dap Session
function M._fix_responses(session)
  if session._nvim_al_fixed then
    return
  end
  session._nvim_al_fixed = true
  local commands = {}
  local request = session.request
  session.request = function(self, command, arguments, on_result)
    commands[self.seq] = command
    return request(self, command, arguments, on_result)
  end
  local handle_body = session.handle_body
  session.handle_body = function(self, body)
    if type(body) == "string" and body:find('"response"', 1, true) then
      local ok, decoded = pcall(vim.json.decode, body)
      if
        ok
        and decoded.type == "response"
        and (decoded.command == nil or decoded.command == vim.NIL)
      then
        local seq = decoded.request_seq
        local args = (self.message_requests or {})[seq]
        decoded.command = commands[seq] or (type(args) == "table" and args.request) or "unknown"
        commands[seq] = nil
        body = vim.json.encode(decoded)
      end
    end
    return handle_body(self, body)
  end
end

--- Register the adapter, configuration provider and AL event handlers. Idempotent.
function M.setup()
  if done then
    return true
  end
  local ok, dap = pcall(require, "dap")
  if not ok then
    return false
  end
  done = true
  dap.adapters.al = adapter
  dap.providers.configs[KEY] = M.configurations

  -- configurations from nvim-dap's own launch.json loader (or user tables)
  dap.listeners.on_config[KEY] = function(config)
    if config.type ~= "al" or config.isResolved then
      return config
    end
    local ws, folder = locate(vim.api.nvim_get_current_buf())
    if not ws then
      return config
    end
    local t, err = launch.resolve(config, ws, folder)
    if not t then
      util.notify(err:gsub("^nvim%-al: ", ""), vim.log.levels.ERROR)
      return config
    end
    return to_dap_config(t, folder)
  end

  -- patch each AL session before its first message
  dap.listeners.on_session[KEY] = function(_, new)
    if new and new.config and new.config.type == "al" then
      M._fix_responses(new)
    end
  end

  dap.listeners.before.launch[KEY] = function(session)
    return session.config.type ~= "al" or check_single(session.config)
  end
  dap.listeners.before.attach[KEY] = dap.listeners.before.launch[KEY]

  dap.listeners.after["event_al/openUri"][KEY] = function(_, body)
    if body and body.uri then
      vim.ui.open(body.uri)
    end
  end
  dap.listeners.after["event_al/deviceLogin"][KEY] = function(_, body)
    if body then
      util.notify(body.message or ("device code: " .. tostring(body.token)), vim.log.levels.WARN)
      if body.uri then
        vim.ui.open(body.uri)
      end
    end
  end
  dap.listeners.after["event_window/logMessage"][KEY] = function(_, body)
    if body and body.type and body.type <= 2 then
      util.notify(
        body.message or "",
        body.type == 1 and vim.log.levels.ERROR or vim.log.levels.WARN
      )
    end
  end

  -- track adapter processes so none outlives Neovim
  dap.listeners.after.initialize[KEY] = function(session)
    local pid = session and session.adapter and session.adapter.pid
      or (session and session.handle and session.handle.pid)
    if pid then
      pids[pid] = true
    end
  end
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("nvim-al-dap", { clear = true }),
    callback = M.kill_adapters,
  })
  return true
end

--- Kill every adapter process nvim-al started.
function M.kill_adapters()
  for pid in pairs(pids) do
    pcall(vim.uv.kill, pid, "sigterm")
  end
  local list = vim.tbl_keys(pids)
  pids = {}
  if #list > 0 then
    vim.defer_fn(function()
      for _, pid in ipairs(list) do
        pcall(vim.uv.kill, pid, "sigkill")
      end
    end, 1000)
  end
end

--- :AL debug
function M.debug()
  if not M.setup() then
    return util.notify("nvim-dap is not installed", vim.log.levels.ERROR)
  end
  require("dap").continue()
end

return M
