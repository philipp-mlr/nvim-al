-- Workspace discovery: git root, project folder (nearest app.json), the
-- *.code-workspace file that lists it (outermost wins), and its folders.
local jsonc = require("nvim-al.jsonc")
local util = require("nvim-al.util")

local M = {}

---@class nvim_al.Dependency
---@field id string
---@field name string
---@field publisher string
---@field version string

---@class nvim_al.Manifest
---@field id string
---@field name string
---@field publisher string
---@field version string
---@field dependencies nvim_al.Dependency[]
---@field raw string file text without BOM

---@class nvim_al.Folder
---@field path string absolute, normalised
---@field name string workspace folder "name" or the basename
---@field index integer 0-based position in the workspace
---@field manifest nvim_al.Manifest|nil

---@class nvim_al.Workspace
---@field key string workspace file path, or folder path in single-folder mode
---@field file string|nil .code-workspace path
---@field root string git root (or the project folder when there is none)
---@field folders nvim_al.Folder[]
---@field settings table workspace file "settings" (raw al.* keys)
---@field launch table|nil workspace file "launch" section

local MAX_UP_WITHOUT_GIT = 10

---@type table<string, nvim_al.Workspace> project folder -> workspace
local cache = {}

local function dirname(path)
  return util.normalize(vim.fs.dirname(path))
end

local function start_dir(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == "directory" then
    return util.normalize(path)
  end
  return dirname(path)
end

local function exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

--- Nearest ancestor (inclusive) containing `.git` (file or directory).
---@param path string
---@return string|nil
function M.git_root(path)
  local dir = start_dir(path)
  while true do
    if exists(dir .. "/.git") then
      return dir
    end
    local parent = dirname(dir)
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

--- Nearest ancestor (inclusive) containing app.json, bounded by the git root
--- (or MAX_UP_WITHOUT_GIT levels when there is no git root).
---@param path string
---@return string|nil
function M.project_folder(path)
  local root = M.git_root(path)
  local dir = start_dir(path)
  local levels = 0
  while true do
    if exists(dir .. "/app.json") and M.is_al_manifest(dir .. "/app.json") then
      return dir
    end
    if root and util.same_path(dir, root) then
      return nil
    end
    levels = levels + 1
    if not root and levels > MAX_UP_WITHOUT_GIT then
      return nil
    end
    local parent = dirname(dir)
    if parent == dir then
      return nil
    end
    dir = parent
  end
end

--- Read and parse app.json of a folder.
---@param folder_path string
---@return nvim_al.Manifest|nil
---@return string|nil err
function M.load_manifest(folder_path)
  local file = folder_path .. "/app.json"
  local text = util.read_file(file)
  if not text then
    return nil, "not found"
  end
  if text:sub(1, 3) == "\239\187\191" then
    text = text:sub(4)
  end
  local v, err = jsonc.decode(text)
  if not v then
    return nil, err
  end
  return {
    id = v.id or "",
    name = v.name or vim.fs.basename(folder_path),
    publisher = v.publisher or "",
    version = v.version or "0.0.0.0",
    dependencies = v.dependencies or {},
    raw = text,
  },
    nil
end

--- True when an app.json is an AL manifest (other ecosystems use app.json too).
---@param path string
---@return boolean
function M.is_al_manifest(path)
  local v = jsonc.read(path)
  return type(v) == "table"
    and type(v.id) == "string"
    and type(v.publisher) == "string"
    and (v.platform ~= nil or v.application ~= nil or v.runtime ~= nil or v.idRanges ~= nil)
end

--- Folders listed in a workspace file, resolved against the file's directory.
--- Folders that do not exist are skipped.
---@param file string
---@return nvim_al.Folder[]|nil folders
---@return table|nil decoded workspace file
local function read_workspace_file(file)
  local v = jsonc.read(file)
  if type(v) ~= "table" or type(v.folders) ~= "table" then
    return nil, nil
  end
  local base = dirname(file)
  local folders = {}
  for _, entry in ipairs(v.folders) do
    if type(entry) == "table" and type(entry.path) == "string" then
      local p = entry.path
      if not (p:sub(1, 1) == "/" or p:match("^%a:[/\\]")) then
        p = base .. "/" .. p
      end
      local real = vim.uv.fs_realpath(p)
      if real then
        real = util.normalize(real)
        folders[#folders + 1] = {
          path = real,
          name = entry.name or vim.fs.basename(real),
          index = #folders,
        }
      end
    end
  end
  return folders, v
end

local function depth(path)
  local _, n = path:gsub("/", "")
  return n
end

--- Workspace files between `project` and `root` whose folders include `project`.
---@return {file:string, folders:nvim_al.Folder[], data:table}[]
local function candidates(project, root)
  local found = {}
  local dir = project
  while true do
    for name, typ in vim.fs.dir(dir) do
      if typ == "file" and name:match("%.code%-workspace$") then
        local file = dir .. "/" .. name
        local folders, data = read_workspace_file(file)
        if folders then
          for _, f in ipairs(folders) do
            if util.same_path(f.path, project) then
              found[#found + 1] = { file = file, folders = folders, data = data }
              break
            end
          end
        end
      end
    end
    if util.same_path(dir, root) then
      break
    end
    local parent = dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end
  return found
end

local function pick_outermost(found)
  table.sort(found, function(a, b)
    local da, db = depth(a.file), depth(b.file)
    if da ~= db then
      return da < db
    end
    return a.file < b.file
  end)
  if #found > 1 and depth(found[1].file) == depth(found[2].file) then
    util.notify_once(
      "tie:" .. found[1].file,
      ("several workspace files at the same level list this project; using %s"):format(
        vim.fs.basename(found[1].file)
      )
    )
  end
  return found[1]
end

---@class nvim_al.ResolveOpts
---@field workspace_file? fun(project: string, candidates: string[]): string|nil

--- Resolve the workspace for a file or directory. Cached per project folder.
---@param path string
---@param opts? nvim_al.ResolveOpts
---@return nvim_al.Workspace|nil
---@return string|nil reason
function M.resolve(path, opts)
  opts = opts or {}
  local project = M.project_folder(path)
  if not project then
    return nil, "no app.json"
  end
  project = util.normalize(vim.uv.fs_realpath(project) or project)
  if cache[project] then
    return cache[project], nil
  end
  local root = M.git_root(project) or project

  local found = candidates(project, root)
  local chosen
  if #found > 0 then
    if opts.workspace_file then
      local files = vim.tbl_map(function(c)
        return c.file
      end, found)
      local want = opts.workspace_file(project, files)
      for _, c in ipairs(found) do
        if want and util.same_path(c.file, want) then
          chosen = c
        end
      end
    end
    chosen = chosen or pick_outermost(found)
  end

  ---@type nvim_al.Workspace
  local ws
  if chosen then
    ws = {
      key = chosen.file,
      file = chosen.file,
      root = root,
      folders = chosen.folders,
      settings = chosen.data.settings or {},
      launch = chosen.data.launch,
    }
  else
    ws = {
      key = project,
      file = nil,
      root = root,
      folders = { { path = project, name = vim.fs.basename(project), index = 0 } },
      settings = {},
    }
  end
  for _, f in ipairs(ws.folders) do
    f.manifest = M.load_manifest(f.path)
  end
  if not chosen and ws.folders[1].manifest then
    ws.folders[1].name = ws.folders[1].manifest.name
  end

  -- cache only the resolved project: siblings resolve on their own, so the
  -- workspace a folder belongs to never depends on what was opened first
  cache[project] = ws
  return ws, nil
end

--- Deepest workspace folder containing `path`.
---@param ws nvim_al.Workspace
---@param path string
---@return nvim_al.Folder|nil
function M.folder_for(ws, path)
  local best
  for _, f in ipairs(ws.folders) do
    if util.is_inside(path, f.path) and (not best or #f.path > #best.path) then
      best = f
    end
  end
  return best
end

--- Drop cached workspaces affected by a change to `path` (a workspace file,
--- an app.json, or a .vscode/settings.json).
---@param path string
function M.invalidate(path)
  path = util.normalize(path)
  for project, ws in pairs(cache) do
    local hit = ws.file and util.same_path(ws.file, path)
    for _, f in ipairs(ws.folders) do
      if util.is_inside(path, f.path) then
        hit = true
      end
    end
    if hit or path:match("%.code%-workspace$") then
      cache[project] = nil
    end
  end
end

--- Clear the whole cache (tests).
function M._reset()
  cache = {}
end

return M
