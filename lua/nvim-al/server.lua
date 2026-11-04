-- Talk to a Business Central target over HTTP (dev endpoint + automation API)
-- for health checks and "what is installed". Uses curl; credentials go in via
-- a curl config on stdin, never on the command line.
local M = {}

--- Base URL of a target: server + port + instance, e.g. http://localhost:8880/main-de
---@param target nvim_al.Target
---@return string
function M.base_url(target)
  local server = (target.server or "http://localhost"):gsub("/+$", "")
  local scheme, host = server:match("^(%a+://)([^/]+)")
  if not scheme then
    scheme, host = "http://", server
  end
  host = host:gsub(":%d+$", "")
  local port = target.port and (":" .. target.port) or ""
  local instance = target.serverInstance and ("/" .. target.serverInstance) or ""
  return scheme .. host .. port .. instance
end

local function auth_config(env)
  local user = env.BC_SERVER_USERNAME or vim.env.BC_SERVER_USERNAME
  local pass = env.BC_SERVER_PASSWORD or vim.env.BC_SERVER_PASSWORD
  if not (user and pass) then
    return ""
  end
  -- curl config syntax; escape backslashes and quotes
  local esc = function(v)
    return (v:gsub("\\", "\\\\"):gsub('"', '\\"'))
  end
  return ('user = "%s:%s"\n'):format(esc(user), esc(pass))
end

--- GET a path below the target's base URL.
--- cb(status_code, body, err) on the main loop; status 0 = no connection.
---@param target nvim_al.Target
---@param env table credentials env (BC_SERVER_USERNAME/PASSWORD) or {}
---@param path string e.g. "/dev/metadata?tenant=default"
---@param cb fun(status: integer, body: string, err: string|nil)
---@param timeout? integer seconds (default 10)
function M.get(target, env, path, cb, timeout)
  local url = M.base_url(target) .. path
  local cmd = {
    "curl",
    "--silent",
    "--show-error",
    "--max-time",
    tostring(timeout or 10),
    "--config",
    "-",
    "--write-out",
    "\n%{http_code}",
    url,
  }
  local ok, err = pcall(vim.system, cmd, { stdin = auth_config(env), text = true }, function(res)
    local out = res.stdout or ""
    local body, code = out:match("^(.*)\n(%d%d%d)$")
    vim.schedule(function()
      if not code then
        cb(
          0,
          "",
          vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or ("curl exit " .. res.code)
        )
      else
        cb(tonumber(code), body or "", nil)
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(0, "", "curl not available: " .. tostring(err))
    end)
  end
end

local function tenant_query(target, sep)
  return (sep or "?") .. "tenant=" .. (target.tenant or "default")
end

--- Health check: is the dev endpoint reachable and are the credentials accepted?
--- cb(ok, message) — message explains what is wrong when not ok.
---@param target nvim_al.Target
---@param env table
---@param cb fun(ok: boolean, message: string)
function M.check(target, env, cb)
  M.get(target, env, "/dev/metadata" .. tenant_query(target), function(status, _, err)
    local base = M.base_url(target)
    if status == 0 then
      return cb(false, ("%s is not reachable (%s)"):format(base, err or "no connection"))
    elseif status == 401 then
      return cb(false, ("%s rejected the credentials (401)"):format(base))
    elseif status == 404 then
      return cb(false, ("%s has no dev endpoint (404): wrong serverInstance or port?"):format(base))
    elseif status >= 500 then
      return cb(false, ("%s answered %d: the service tier is not ready"):format(base, status))
    elseif status ~= 200 then
      return cb(false, ("%s answered %d"):format(base, status))
    end
    cb(true, base .. " is up")
  end, 8)
end

local function company_id(target, env, cb)
  M.get(target, env, "/api/v2.0/companies" .. tenant_query(target), function(status, body)
    if status ~= 200 then
      return cb(nil)
    end
    local ok, v = pcall(vim.json.decode, body)
    local first = ok and type(v) == "table" and v.value and v.value[1]
    cb(first and first.id or nil)
  end)
end

--- Installed extensions of a publisher (or all non-Microsoft ones):
--- cb({ [name] = { version = "28.0.0.0", installed = true } }) or cb(nil, err).
---@param target nvim_al.Target
---@param env table
---@param cb fun(apps: table<string, {version: string, installed: boolean, publisher: string}>|nil, err: string|nil)
function M.installed(target, env, cb)
  company_id(target, env, function(cid)
    if not cid then
      return cb(nil, "could not read companies from " .. M.base_url(target))
    end
    local path = ("/api/microsoft/automation/v2.0/companies(%s)/extensions%s"):format(
      cid,
      tenant_query(target)
    )
    M.get(target, env, path, function(status, body)
      if status ~= 200 then
        return cb(nil, ("extension list failed (%d)"):format(status))
      end
      local ok, v = pcall(vim.json.decode, body)
      if not ok or type(v) ~= "table" or type(v.value) ~= "table" then
        return cb(nil, "extension list unreadable")
      end
      local apps = {}
      for _, x in ipairs(v.value) do
        apps[x.publisher .. "|" .. x.displayName] = {
          publisher = x.publisher,
          version = ("%d.%d.%d.%d"):format(
            x.versionMajor or 0,
            x.versionMinor or 0,
            x.versionBuild or 0,
            x.versionRevision or 0
          ),
          installed = x.isInstalled == true,
        }
      end
      cb(apps, nil)
    end, 20)
  end)
end

return M
