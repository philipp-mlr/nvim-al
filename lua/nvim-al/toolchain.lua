-- The single resolver for every AL binary: finds the AL extension and dotnet,
-- and builds the commands for EditorServices.Host and altool.
local jsonc = require("nvim-al.jsonc")

local M = {}

local HOST = "Microsoft.Dynamics.Nav.EditorServices.Host.dll"
local MIN_MAJOR = 30

---@class nvim_al.Extension
---@field path string extension root (the folder containing package.json and bin/)
---@field version string

---@type {path:string, reason:string}[]
local skipped = {}

local function exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

local function parse_version(v)
  local parts = {}
  for n in tostring(v):gmatch("%d+") do
    parts[#parts + 1] = tonumber(n)
  end
  return parts
end

local function newer(a, b)
  local pa, pb = parse_version(a), parse_version(b)
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then
      return x > y
    end
  end
  return false
end

--- Inspect one candidate directory (extension root or a dir containing extension/).
---@return nvim_al.Extension|nil, string|nil reason
local function inspect(dir)
  dir = vim.fs.normalize(dir)
  if not exists(dir .. "/package.json") and exists(dir .. "/extension/package.json") then
    dir = dir .. "/extension"
  end
  local pkg = jsonc.read(dir .. "/package.json")
  if not pkg or not pkg.version then
    return nil, "no package.json"
  end
  if (parse_version(pkg.version)[1] or 0) < MIN_MAJOR then
    return nil, ("version %s is older than %d.0"):format(pkg.version, MIN_MAJOR)
  end
  if not exists(dir .. "/bin/" .. HOST) then
    return nil, "missing EditorServices host"
  end
  return { path = dir, version = pkg.version }, nil
end

local function search_dirs()
  local home = vim.env.HOME or vim.fn.expand("~")
  local dirs = {
    home .. "/.vscode/extensions",
    home .. "/.vscode-server/extensions",
    home .. "/.vscode-insiders/extensions",
    home .. "/.cursor/extensions",
  }
  if vim.fn.has("win32") == 1 and vim.env.USERPROFILE then
    table.insert(dirs, vim.env.USERPROFILE .. "/.vscode/extensions")
  end
  return dirs
end

--- Locate the AL extension: cfg.extension_path, $NVIM_AL_EXTENSION, then the
--- newest usable ms-dynamics-smb.al-* in the VS Code extension directories.
---@param cfg table
---@return nvim_al.Extension|nil
---@return string|nil err
function M.find_extension(cfg)
  skipped = {}
  local explicit = cfg.extension_path or vim.env.NVIM_AL_EXTENSION
  if explicit and explicit ~= "" then
    local ext, reason = inspect(explicit)
    if not ext then
      return nil, ("AL extension at %s is not usable: %s"):format(explicit, reason)
    end
    return ext, nil
  end
  local best
  for _, d in ipairs(search_dirs()) do
    for _, cand in ipairs(vim.fn.glob(d .. "/ms-dynamics-smb.al-*", false, true)) do
      local ext, reason = inspect(cand)
      if ext then
        if not best or newer(ext.version, best.version) then
          best = ext
        end
      else
        skipped[#skipped + 1] = { path = vim.fs.normalize(cand), reason = reason }
      end
    end
  end
  if not best then
    return nil,
      ("no AL extension >= %d.0 found (set extension_path or $NVIM_AL_EXTENSION)"):format(MIN_MAJOR)
  end
  return best, nil
end

--- Candidates the last find_extension() scan rejected, with reasons.
---@return {path:string, reason:string}[]
function M.skipped()
  return skipped
end

--- dotnet executable.
---@param cfg table
---@return string|nil
---@return string|nil err
function M.dotnet(cfg)
  local d = cfg.dotnet or "dotnet"
  if vim.fn.executable(d) == 1 then
    return vim.fn.exepath(d) ~= "" and vim.fn.exepath(d) or d
  end
  return nil, ("dotnet not found (%s); install the .NET 10 runtime or set `dotnet`"):format(d)
end

local function tool_cmd(cfg, file, args)
  local ext, err = M.find_extension(cfg)
  if not ext then
    return nil, err
  end
  local dotnet, derr = M.dotnet(cfg)
  if not dotnet then
    return nil, derr
  end
  local cmd = { dotnet, ext.path .. "/bin/" .. file }
  vim.list_extend(cmd, args or {})
  return cmd, nil
end

---@param cfg table
---@param args string[]
---@return string[]|nil
---@return string|nil err
function M.host_cmd(cfg, args)
  return tool_cmd(cfg, HOST, args)
end

---@param cfg table
---@param args string[]
---@return string[]|nil
---@return string|nil err
function M.altool_cmd(cfg, args)
  return tool_cmd(cfg, "altool.dll", args)
end

---@param cfg table
---@return string|nil
function M.version(cfg)
  local ext = M.find_extension(cfg)
  return ext and ext.version or nil
end

--- The extension's built-in analyzer directory (what ${analyzerFolder} means to the server).
---@param cfg table
---@return string|nil
function M.analyzers_dir(cfg)
  local ext = M.find_extension(cfg)
  return ext and (ext.path .. "/bin/Analyzers") or nil
end

--- `dotnet --list-runtimes` output; overridable in tests.
function M._list_runtimes(dotnet)
  local r = vim.system({ dotnet, "--list-runtimes" }, { text = true }):wait()
  return r.stdout or ""
end

local runtime_ok = {}

--- True when dotnet has Microsoft.NETCore.App and Microsoft.AspNetCore.App 10.x.
---@param cfg table
---@return boolean
---@return string|nil err
function M.check_runtime(cfg)
  local dotnet, err = M.dotnet(cfg)
  if not dotnet then
    return false, err
  end
  if runtime_ok[dotnet] ~= nil then
    return runtime_ok[dotnet][1], runtime_ok[dotnet][2]
  end
  local out = M._list_runtimes(dotnet)
  local result = { true, nil }
  for _, fw in ipairs({ "Microsoft.NETCore.App", "Microsoft.AspNetCore.App" }) do
    if not out:find(fw:gsub("%.", "%%.") .. " 10%.") then
      result = { false, "needs " .. fw .. " 10.0" }
      break
    end
  end
  runtime_ok[dotnet] = result
  return result[1], result[2]
end

return M
