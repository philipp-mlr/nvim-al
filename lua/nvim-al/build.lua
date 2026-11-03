-- :AL build (the server's own build of the active project) and
-- :AL compile (altool workspace compile over all folders).
local altool = require("nvim-al.altool")
local quickfix = require("nvim-al.quickfix")
local settings = require("nvim-al.settings")
local toolchain = require("nvim-al.toolchain")
local util = require("nvim-al.util")
local workspace = require("nvim-al.workspace")

local M = {}

local BUILTIN = {
  ["${CodeCop}"] = "CodeCop",
  ["${UICop}"] = "UICop",
  ["${PerTenantExtensionCop}"] = "PTECop",
  ["${AppSourceCop}"] = "AppSourceCop",
}

local function cfg()
  return require("nvim-al").config()
end

--- { ws, folder, cfg } for a buffer, or nil with a notice.
---@param bufnr integer
---@return table|nil
function M.context(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local name = vim.api.nvim_buf_get_name(bufnr)
  name = util.normalize(vim.uv.fs_realpath(name) or name)
  local ws = workspace.resolve(name, { workspace_file = cfg().hooks.workspace_file })
  if not ws then
    util.notify("no AL project for this buffer", vim.log.levels.WARN)
    return nil
  end
  local folder = workspace.folder_for(ws, name) or ws.folders[1]
  return { ws = ws, folder = folder, cfg = cfg(), bufnr = bufnr }
end

--- Write modified buffers that belong to `folder`.
local function save_project_buffers(folder)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and util.is_inside(name, folder.path) then
        vim.api.nvim_buf_call(b, function()
          vim.cmd("silent write")
        end)
      end
    end
  end
end

M._save_project_buffers = save_project_buffers

--- Build the project of the buffer with the language server (al/createPackage).
---@param bufnr integer|nil
---@param on_done? fun(ok: boolean, ctx: table)
function M.build(bufnr, on_done)
  local ctx = M.context(bufnr)
  if not ctx then
    return
  end
  if ctx.cfg.hooks.build and ctx.cfg.hooks.build(ctx) then
    return
  end
  local lsp = require("nvim-al.lsp")
  local client = lsp.client_for(ctx.bufnr)
  if not client then
    return util.notify("no AL language server for this buffer", vim.log.levels.WARN)
  end
  save_project_buffers(ctx.folder)
  local nvim_al = require("nvim-al")
  nvim_al._building = true
  client:request("al/createPackage", {
    projectDir = ctx.folder.path,
    args = { '-project:"' .. ctx.folder.path .. '"' },
    isRad = false,
    vSCodeExtensionVersion = toolchain.version(ctx.cfg) or "",
    forceBuildDependencies = false,
  }, function(err, result)
    nvim_al._building = false
    local ok = not err and type(result) == "table" and result.success == true
    if ok then
      util.notify("built " .. ctx.folder.name)
    else
      util.notify("build of " .. ctx.folder.name .. " failed", vim.log.levels.ERROR)
      vim.defer_fn(function()
        vim.diagnostic.setqflist({ severity = vim.diagnostic.severity.ERROR, title = "AL build" })
      end, 300)
    end
    if on_done then
      on_done(ok, ctx)
    end
  end, ctx.bufnr)
end

local function rewrite_analyzer(a, dir)
  local rest = a:match("^%${analyzerFolder}[/\\]?(.*)$")
  if rest and dir then
    return dir:gsub("/+$", "") .. "/" .. rest
  end
  return a
end

--- Workspace-level al.* map: schema defaults < cfg.settings < workspace file settings.
local function workspace_settings(ws, c)
  local map = vim.deepcopy(settings.defaults)
  for _, src in ipairs({ c.settings or {}, ws.settings or {} }) do
    for k, v in pairs(src) do
      map[k] = v
    end
  end
  return map
end

local function list(v)
  if v == nil or v == vim.NIL then
    return {}
  end
  return type(v) == "string" and { v } or v
end

--- Resolve a setting path the way the language server does. Verified against
--- EditorServices 30.0: "${workspaceFolder}/.." stays in the folder (the variable
--- behaves like a path to a file inside it), so "${workspaceFolder}/../../.alpackages"
--- from apps/X/app is apps/.alpackages, one level up per remaining "..".
local function resolve_path(p, base, folder1)
  local rest = p:match("^%${workspaceFolder}[/\\]?(.*)$")
  if rest then
    p = folder1 .. "/_/" .. rest
  end
  if not (p:sub(1, 1) == "/" or p:match("^%a:[/\\]")) then
    p = base .. "/" .. p
  end
  p = vim.fs.normalize(p)
  -- collapse "." and ".." lexically (the directory may not exist)
  local out = {}
  for part in p:gmatch("[^/]+") do
    if part == ".." then
      table.remove(out)
    elseif part ~= "." then
      out[#out + 1] = part
    end
  end
  local prefix = p:match("^%a:") and "" or "/"
  return prefix .. table.concat(out, "/")
end

--- altool arguments for `workspace compile`, plus the folders whose settings differ.
---@return string[] args, string[] differing, string tmpdir
function M.compile_args(ws, c, file)
  local base = ws.file and vim.fs.dirname(ws.file) or ws.folders[1].path
  local folder1 = ws.folders[1].path
  local s = workspace_settings(ws, c)
  local tmp = vim.fn.tempname() .. "-al-compile"
  local cache = list(s["al.packageCachePath"])[1] or "./.alpackages"
  local args = {
    "workspace",
    "compile",
    file,
    "--packagecachepath",
    resolve_path(cache, folder1, folder1),
    "--outfolder",
    tmp .. "/out",
    "--logdirectory",
    tmp .. "/logs",
    "--errorlogdirectory",
    tmp .. "/err",
  }
  local builtins, custom = {}, {}
  for _, a in ipairs(list(s["al.codeAnalyzers"])) do
    if BUILTIN[a] then
      builtins[#builtins + 1] = BUILTIN[a]
    else
      custom[#custom + 1] = rewrite_analyzer(a, c.analyzer_folder)
    end
  end
  if #builtins > 0 then
    vim.list_extend(args, { "--analyzers", table.concat(builtins, ",") })
  end
  for _, a in ipairs(custom) do
    vim.list_extend(args, { "--customanalyzers", a })
  end
  local ruleset = s["al.ruleSetPath"]
  if type(ruleset) == "string" and ruleset ~= "" then
    vim.list_extend(args, { "--ruleset", resolve_path(ruleset, folder1, folder1) })
  end

  local differing = {}
  for _, f in ipairs(ws.folders) do
    if f.manifest then
      local fs = settings.resolve(ws, f, c)
      if
        not vim.deep_equal(list(fs["al.codeAnalyzers"]), list(s["al.codeAnalyzers"]))
        or fs["al.ruleSetPath"] ~= s["al.ruleSetPath"]
      then
        differing[#differing + 1] = f.name
      end
    end
  end
  return args, differing, tmp
end

local log_buf

local function log_line(line)
  if not (log_buf and vim.api.nvim_buf_is_valid(log_buf)) then
    return
  end
  vim.bo[log_buf].modifiable = true
  vim.api.nvim_buf_set_lines(log_buf, -1, -1, false, { line })
  vim.bo[log_buf].modifiable = false
end

local function open_log(show)
  if not (log_buf and vim.api.nvim_buf_is_valid(log_buf)) then
    log_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(log_buf, "nvim-al://compile")
    vim.bo[log_buf].bufhidden = "hide"
  end
  vim.bo[log_buf].modifiable = true
  vim.api.nvim_buf_set_lines(log_buf, 0, -1, false, {})
  vim.bo[log_buf].modifiable = false
  if show then
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, log_buf)
    vim.cmd("wincmd p")
  end
end

--- Compile every folder of the buffer's workspace with altool.
---@param bufnr integer|nil
---@param opts? { show_log?: boolean }
function M.compile(bufnr, opts)
  opts = opts or {}
  local ctx = M.context(bufnr)
  if not ctx then
    return
  end
  if ctx.cfg.hooks.compile and ctx.cfg.hooks.compile(ctx) then
    return
  end
  local ws = ctx.ws
  local file = ws.file
  if not file then
    file = vim.fn.tempname() .. ".code-workspace"
    vim.fn.writefile({ vim.json.encode({ folders = { { path = ws.folders[1].path } } }) }, file)
  end
  local args, differing, tmp = M.compile_args(ws, ctx.cfg, file)
  if #differing > 0 then
    util.notify(
      ":AL compile uses workspace-level analyzers/ruleset; differs for: "
        .. table.concat(differing, ", "),
      vim.log.levels.WARN
    )
  end
  for _, f in ipairs(ws.folders) do
    save_project_buffers(f)
  end
  open_log(opts.show_log)
  local nvim_al = require("nvim-al")
  nvim_al._building = true
  util.notify(("compiling %d project(s)…"):format(#ws.folders))
  altool.run(args, { cwd = ws.folders[1].path, on_line = log_line }, function(code)
    nvim_al._building = false
    local items = {}
    for _, log in ipairs(vim.fn.glob(tmp .. "/err/*.errorLog.json", false, true)) do
      vim.list_extend(items, quickfix.from_error_log(log))
    end
    local n = { E = 0, W = 0, I = 0 }
    for _, it in ipairs(items) do
      n[it.type] = (n[it.type] or 0) + 1
    end
    vim.fn.setqflist({}, "r", { title = "AL compile", items = items })
    if n.E > 0 then
      vim.cmd("botright copen")
    end
    util.notify(
      ("compile %s: %d projects, %d error(s), %d warning(s)"):format(
        code == 0 and "succeeded" or "failed",
        #ws.folders,
        n.E,
        n.W
      ),
      (code == 0 and n.E == 0) and vim.log.levels.INFO or vim.log.levels.ERROR
    )
  end)
end

return M
