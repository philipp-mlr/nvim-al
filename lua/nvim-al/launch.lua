-- Launch configurations (.vscode/launch.json, the workspace file's "launch"
-- section, or the launch hook), resolved as VS Code does (docs/protocol.md §3.2),
-- and the per-project target shared by debugging, publish, symbols and tests.
local closure = require("nvim-al.closure")
local jsonc = require("nvim-al.jsonc")
local util = require("nvim-al.util")

local M = {}

---@class nvim_al.Target
---@field name string
---@field request "launch"|"attach"|"snapshotInitialize"
---@field server string|nil
---@field port integer
---@field serverInstance string|nil
---@field tenant string|nil
---@field authentication "UserPassword"|"Windows"
---@field environmentType string|nil
---@field environmentName string|nil
---@field raw table the resolved configuration sent to the debug adapter

local SUPPORTED_AUTH = { UserPassword = true, Windows = true }
local DEFAULT_PORT = 7049

---@type table<string, nvim_al.Target> folder path -> remembered target
local remembered = {}

local function only_al(list)
  local out = {}
  for _, c in ipairs(list or {}) do
    if type(c) == "table" and c.type == "al" then
      out[#out + 1] = c
    end
  end
  return out
end

--- Configurations for a folder: hooks.launch(folder) if set; otherwise the
--- folder's .vscode/launch.json followed by the workspace file's launch section.
---@param ws nvim_al.Workspace
---@param folder nvim_al.Folder
---@param cfg nvim_al.Config
---@return table[]
function M.configurations(ws, folder, cfg)
  if cfg.hooks and cfg.hooks.launch then
    return only_al(cfg.hooks.launch(folder))
  end
  local list = {}
  local file = jsonc.read(folder.path .. "/.vscode/launch.json")
  vim.list_extend(list, only_al(file and file.configurations))
  vim.list_extend(list, only_al(ws.launch and ws.launch.configurations))
  return list
end

local function split_break(raw, key)
  local v = raw[key]
  if type(v) == "string" then
    raw[key] = true
    raw[key .. "Behaviour"] = v
  elseif v == nil then
    raw[key] = false
  end
end

local function default(raw, key, value)
  if raw[key] == nil then
    raw[key] = value
  end
end

--- Resolve a raw configuration the way the VS Code extension does before it
--- reaches the debug adapter.
---@param raw table
---@param ws nvim_al.Workspace
---@param folder nvim_al.Folder
---@return nvim_al.Target|nil
---@return string|nil err
function M.resolve(raw, ws, folder)
  local r = vim.deepcopy(raw)
  local auth = r.authentication or "UserPassword"
  if not SUPPORTED_AUTH[auth] then
    return nil,
      ("nvim-al: authentication '%s' is not supported in v1 (UserPassword, Windows)"):format(auth)
  end
  r.authentication = auth
  if r.request == "launch" or r.request == "attach" then
    default(r, "port", DEFAULT_PORT)
    split_break(r, "breakOnError")
    split_break(r, "breakOnRecordWrite")
    default(r, "usePublicURLFromServer", true)
    default(r, "validateServerCertificate", true)
    r.useMcpServerForDebugging = r.useMcpServerForDebugging == true
    if r.request == "attach" then
      default(r, "breakOnNext", "WebServiceClient")
      if r.breakOnNext == "Agent" then
        r.breakOnNext = "ClientService"
      end
      default(r, "sessionId", -1)
    else
      local refs = {}
      for _, f in ipairs(closure.references(ws, folder)) do
        refs[#refs + 1] = {
          appId = f.manifest.id,
          name = f.manifest.name,
          publisher = f.manifest.publisher,
          version = f.manifest.version,
        }
      end
      r.projectReferenceDefinitions = refs
    end
  elseif r.request == "snapshotInitialize" then
    default(r, "port", 7083)
  end
  r.isResolved = true
  return {
    name = r.name or "AL",
    request = r.request,
    server = r.server,
    port = r.port or DEFAULT_PORT,
    serverInstance = r.serverInstance,
    tenant = r.tenant,
    authentication = auth,
    environmentType = r.environmentType,
    environmentName = r.environmentName,
    raw = r,
  },
    nil
end

--- The target for a folder: remembered for the session; asks when several
--- usable configurations exist. cb(nil) when there is none or the user cancels.
---@param ws nvim_al.Workspace
---@param folder nvim_al.Folder
---@param cfg nvim_al.Config
---@param cb fun(target: nvim_al.Target|nil)
function M.target(ws, folder, cfg, cb)
  if remembered[folder.path] then
    return cb(remembered[folder.path])
  end
  local usable, errors = {}, {}
  for _, raw in ipairs(M.configurations(ws, folder, cfg)) do
    local t, err = M.resolve(raw, ws, folder)
    if t then
      usable[#usable + 1] = t
    else
      errors[#errors + 1] = err
    end
  end
  if #usable == 0 then
    if #errors > 0 then
      vim.notify(errors[1], vim.log.levels.WARN)
    else
      util.notify("no AL launch configuration for " .. folder.name, vim.log.levels.WARN)
    end
    return cb(nil)
  end
  local function choose(t)
    if t then
      remembered[folder.path] = t
    end
    cb(t)
  end
  if #usable == 1 then
    return choose(usable[1])
  end
  vim.ui.select(usable, {
    prompt = "AL target for " .. folder.name,
    format_item = function(t)
      return t.name
    end,
  }, choose)
end

--- Forget the remembered target of a folder (:AL target).
---@param folder_path string
---@param on_forget? fun(target: nvim_al.Target) called with the forgotten target
function M.forget(folder_path, on_forget)
  local old = remembered[folder_path]
  remembered[folder_path] = nil
  if old and on_forget then
    on_forget(old)
  end
end

--- altool connection flags for a target, only for fields that are set.
---@param t nvim_al.Target
---@return string[]
function M.altool_flags(t)
  local out = {}
  local function add(flag, v)
    if v ~= nil and v ~= vim.NIL and v ~= "" then
      vim.list_extend(out, { flag, tostring(v) })
    end
  end
  add("--server", t.server)
  add("--port", t.port)
  add("--serverinstance", t.serverInstance)
  add("--tenant", t.tenant)
  add("--authentication", t.authentication)
  add("--environmenttype", t.environmentType)
  add("--environmentname", t.environmentName)
  return out
end

return M
