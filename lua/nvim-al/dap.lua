-- Debugging with nvim-dap: the AL debug adapter is EditorServices.Host started
-- with /startDebugging (docs/protocol.md §3). Loaded only when nvim-dap exists.
local credentials = require("nvim-al.credentials")
local launch = require("nvim-al.launch")
local toolchain = require("nvim-al.toolchain")
local util = require("nvim-al.util")
local feedback = require("nvim-al.feedback")
local server = require("nvim-al.server")
local workspace = require("nvim-al.workspace")

local M = {}

local KEY = "nvim-al"
local done = false

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

local function server_key(c)
  return table.concat({ c.server or "", tostring(c.port or ""), c.serverInstance or "" }, "|")
end

--- Only one adapter per environment: an older armed one takes the next break.
--- Runs inside the adapter function, before the new session exists. cb(true)
--- to go ahead.
local function check_single(config, cb)
  local ok, dap = pcall(require, "dap")
  if not ok then
    return cb(true)
  end
  for _, s in pairs(dap.sessions() or {}) do
    if s.config and s.config.type == "al" and server_key(s.config) == server_key(config) then
      return vim.ui.select({ "Stop the other session", "Cancel" }, {
        prompt = "An AL debug session for this environment is already running",
      }, function(choice)
        if choice == "Stop the other session" then
          s:close()
          cb(true)
        else
          cb(false)
        end
      end)
    end
  end
  cb(true)
end

--- A loaded buffer below `folder` with an AL language server attached (the
--- build runs through it), else the current buffer.
---@param folder string
---@return integer
function M._buffer_in(folder)
  local lsp = require("nvim-al.lsp")
  local prefix = folder:gsub("/+$", "") .. "/"
  local cur = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_get_name(cur):sub(1, #prefix) == prefix and lsp.client_for(cur) then
    return cur
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(b)
      and vim.api.nvim_buf_get_name(b):sub(1, #prefix) == prefix
      and lsp.client_for(b)
    then
      return b
    end
  end
  return cur
end

---@type nvim_al.Progress|nil the debug start in flight
M._progress = nil
---@type string[] adapter output of the current debug start
M._output = {}

--- Hand the adapter executable to nvim-dap.
local function start(callback, cmd, folder, config, extra)
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
    options = { cwd = folder, env = env, detached = false, initialize_timeout_sec = 30 },
  })
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
  check_single(config, function(go)
    if not go then
      return
    end
    credentials.env(target, function(extra)
      if not extra then
        return util.notify("debugging cancelled (no credentials)", vim.log.levels.WARN)
      end
      local where = server.where(target)
      local manifest = require("nvim-al.jsonc").read(folder .. "/app.json")
      local subject = type(manifest) == "table" and manifest.name or vim.fs.basename(folder)
      feedback.log("debug", {})
      local p = feedback.progress("AL debug", subject, "checking " .. where)
      M._progress = p
      M._output = {}
      server.check(target, extra, function(ok, msg)
        if not ok then
          M._progress = nil
          p:finish(false, "not started")
          return util.notify(
            ("%s: %s\ncheck the environment, or pick another target with :AL target"):format(
              config.name,
              msg
            ),
            vim.log.levels.ERROR
          )
        end
        if config.request ~= "launch" then
          p:phase("connecting to " .. where)
          return start(callback, cmd, folder, config, extra)
        end
        -- the adapter publishes the .app in the folder as is: build first, like
        -- VS Code, so it is current and has a fresh package id (else the server
        -- rejects it as a duplicate of the one already published)
        local ws_folder = { path = folder, name = subject, manifest = manifest }
        require("nvim-al.build").build(M._buffer_in(folder), function(built)
          if not built then
            M._progress = nil
            if not p.finished then
              p:finish(false, "build failed")
            end
            return -- the build reported why (quickfix, notification)
          end
          p:phase("publishing to " .. where)
          start(callback, cmd, folder, config, extra)
        end, { progress = p, folder = ws_folder })
      end)
    end)
  end)
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

  -- progress of the debug start: attached/launched, or why not
  local function started(request)
    return function(session, err)
      local p = M._progress
      if not (p and session and session.config and session.config.type == "al") then
        return
      end
      M._progress = nil
      local where = server.where(session.config)
      if err then
        -- the adapter's own message points at VS Code's debug console; the
        -- reason is in its output events (nvim-al://debug)
        local reasons = feedback.reasons(M._output)
        local text = #reasons > 0 and table.concat(reasons, "\n")
          or (err.message or vim.inspect(err)):gsub(
            "%s*See Visual Studio Code debug console.*$",
            ""
          )
        p:finish(false, request .. " failed")
        return util.notify(
          ("debugging %s on %s failed:\n%s\n:AL log debug for the adapter output%s"):format(
            p.subject,
            where,
            text,
            request == "attach" and "; is the app published (:AL publish)?" or ""
          ),
          vim.log.levels.ERROR
        )
      end
      p:finish(
        true,
        request == "attach"
            and ("attached to %s, waiting for a session to hit a breakpoint"):format(where)
          or ("published and launched on %s"):format(where)
      )
    end
  end
  -- adapter output (publish steps, server errors) goes to nvim-al://debug
  dap.listeners.after.event_output[KEY] = function(session, body)
    if
      not (session and session.config and session.config.type == "al" and body and body.output)
    then
      return
    end
    if body.category == "telemetry" then
      return
    end
    for _, line in ipairs(vim.split(body.output, "\n", { trimempty = true })) do
      M._output[#M._output + 1] = line
      feedback.append("debug", line)
    end
  end
  dap.listeners.after.attach[KEY] = started("attach")
  dap.listeners.after.launch[KEY] = started("launch")
  dap.listeners.after.event_terminated[KEY] = function(session)
    local p = M._progress
    if p and session and session.config and session.config.type == "al" then
      M._progress = nil
      p:finish(false, "the debug adapter ended before the session started")
    end
  end

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

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("nvim-al-dap", { clear = true }),
    callback = M.kill_adapters,
  })
  return true
end

--- PIDs of AL debug adapters started from this Neovim. nvim-dap keeps the
--- adapter pid private, so find them among Neovim's child processes by their
--- command line (EditorServices.Host … /startDebugging).
---@return integer[]
function M._adapter_pids()
  local out = {}
  local function walk(pid)
    for _, child in ipairs(vim.api.nvim_get_proc_children(pid)) do
      local ok, info = pcall(vim.api.nvim_get_proc, child)
      local cmd = ok and info and info.name or ""
      local args = ""
      local f = io.open("/proc/" .. child .. "/cmdline", "rb")
      if f then
        args = f:read("*a"):gsub("%z", " ")
        f:close()
      end
      local line = cmd .. " " .. args
      if line:find("EditorServices.Host", 1, true) and line:find("/startDebugging", 1, true) then
        out[#out + 1] = child
      else
        walk(child)
      end
    end
  end
  walk(vim.fn.getpid())
  return out
end

--- Kill every AL debug adapter started from this Neovim (VimLeavePre).
function M.kill_adapters()
  local list = M._adapter_pids()
  for _, pid in ipairs(list) do
    pcall(vim.uv.kill, pid, "sigterm")
  end
  if #list > 0 then
    -- VimLeavePre: no event loop left for a deferred SIGKILL; wait briefly instead
    vim.wait(1000, function()
      for _, pid in ipairs(list) do
        if vim.uv.kill(pid, 0) == 0 then
          return false
        end
      end
      return true
    end, 50)
    for _, pid in ipairs(list) do
      pcall(vim.uv.kill, pid, "sigkill")
    end
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
