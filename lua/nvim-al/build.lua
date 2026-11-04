-- :AL build (the server's own build of the active project) and
-- :AL compile (altool workspace compile over all folders).
local altool = require("nvim-al.altool")
local feedback = require("nvim-al.feedback")
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

-- Builds rewrite tracked files (report layouts, *.g.xlf). Remember which ones
-- so the user is told and can undo exactly those.
---@type { root: string, files: string[] }|nil
M._rewritten = nil

--- Tracked files under `dir` that differ from HEAD, with their content hash
--- (so a file the user already edited still counts when the build changes it).
---@return table<string, string>|nil path (relative to the git root) -> hash
local function dirty_tracked(root, dir)
  local r = vim
    .system({ "git", "-C", root, "diff", "--name-only", "-z", "HEAD", "--", dir }, { text = true })
    :wait()
  if r.code ~= 0 then
    return nil
  end
  local out = {}
  local files = vim.split(r.stdout, "\0", { trimempty = true })
  if #files == 0 then
    return out
  end
  local h = vim
    .system(vim.list_extend({ "git", "-C", root, "hash-object", "--" }, files), { text = true })
    :wait()
  local hashes = vim.split(h.stdout or "", "\n", { trimempty = true })
  for i, f in ipairs(files) do
    out[f] = hashes[i] or "?"
  end
  return out
end

local function snapshot(folder)
  local root = require("nvim-al.workspace").git_root(folder.path)
  if not root then
    return nil
  end
  local files = dirty_tracked(root, folder.path)
  return files and { root = root, dir = folder.path, files = files } or nil
end

local function report_rewritten(snap)
  if not snap then
    return
  end
  local after = dirty_tracked(snap.root, snap.dir) or {}
  local changed = {}
  for f, hash in pairs(after) do
    if snap.files[f] ~= hash then
      changed[#changed + 1] = f
    end
  end
  if #changed == 0 then
    return
  end
  table.sort(changed)
  M._rewritten = { root = snap.root, files = changed }
  local shown = vim.list_slice(changed, 1, 5)
  util.notify(
    ("the build rewrote %d tracked file(s):\n  %s%s\n:AL restore puts them back"):format(
      #changed,
      table.concat(shown, "\n  "),
      #changed > #shown and ("\n  … and " .. (#changed - #shown) .. " more") or ""
    ),
    vim.log.levels.WARN
  )
end

--- Undo the tracked-file rewrites of the last build (git checkout of exactly
--- those files; the user's own edits elsewhere stay).
function M.restore()
  local r = M._rewritten
  if not r then
    return util.notify("nothing to restore")
  end
  local res = vim
    .system(vim.list_extend({ "git", "-C", r.root, "checkout", "--" }, r.files), { text = true })
    :wait()
  if res.code ~= 0 then
    return util.notify("restore failed: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
  end
  M._rewritten = nil
  vim.cmd("checktime")
  util.notify(("restored %d file(s)"):format(#r.files))
end

--- Build the project of the buffer with the language server (al/createPackage).
---@param bufnr integer|nil
---@param on_done? fun(ok: boolean, ctx: table)
---@param opts? { progress?: nvim_al.Progress } continue an existing progress (publish)
function M.build(bufnr, on_done, opts)
  opts = opts or {}
  local ctx = M.context(bufnr)
  if not ctx then
    return
  end
  if opts.folder then
    ctx.folder = opts.folder -- build another project of the same workspace (publish deps)
  end
  if ctx.cfg.hooks.build and ctx.cfg.hooks.build(ctx) then
    return
  end
  local lsp = require("nvim-al.lsp")
  local client = lsp.client_for(ctx.bufnr)
  if not client then
    util.notify("no AL language server for this buffer", vim.log.levels.WARN)
    if opts.progress and not opts.progress.finished then
      opts.progress:finish(false, "build failed (no language server)")
    end
    if on_done then
      on_done(false, ctx)
    end
    return
  end
  save_project_buffers(ctx.folder)
  local snap = snapshot(ctx.folder)
  local nvim_al = require("nvim-al")
  nvim_al._building = true
  local owned = opts.progress == nil
  local p = opts.progress or feedback.progress("AL build", ctx.folder.name, "building")
  p:phase("building")
  feedback.log("build", {})
  M._active = { client_id = client.id, progress = p, lines = {} }
  client:request("al/createPackage", {
    projectDir = ctx.folder.path,
    args = { '-project:"' .. ctx.folder.path .. '"' },
    isRad = false,
    vSCodeExtensionVersion = toolchain.version(ctx.cfg) or "",
    forceBuildDependencies = false,
  }, function(err, result)
    nvim_al._building = false
    local active = M._active or { lines = {} }
    M._active = nil
    local ok = not err and type(result) == "table" and result.success == true
    report_rewritten(snap)
    if ok then
      if owned then
        p:finish(true, "built")
      end
    else
      -- compiler errors as the server logged them (absolute paths)
      local items = vim.tbl_filter(function(it)
        return it.type == "E"
      end, quickfix.from_compiler_lines(active.lines, ctx.folder.path))
      vim.fn.setqflist({}, "r", { title = "AL build", items = items })
      local reasons = vim.tbl_map(function(it)
        return it.text
      end, items)
      if err then
        table.insert(reasons, 1, "Error: " .. (err.message or vim.inspect(err)))
      end
      local lines = vim.list_extend(
        vim.tbl_map(function(r)
          return r:match("^%u+%d+:") and ("error " .. r) or r
        end, reasons),
        active.lines
      )
      feedback.fail(p, "build of " .. ctx.folder.name, lines, 1, #items)
    end
    if on_done then
      on_done(ok, ctx)
    end
  end, ctx.bufnr)
end

--- window/logMessage from the language server: during :AL build these carry
--- the compiler output. Shown as progress and kept in the build log.
function M.server_log(_, result, ctx)
  local a = M._active
  if not (a and ctx and ctx.client_id == a.client_id and type(result) == "table") then
    return
  end
  local line = (result.message or ""):gsub("\r", "")
  a.lines[#a.lines + 1] = line
  feedback.append("build", line)
  -- phases only; individual diagnostics are not progress
  local project = line:match("^Compilation started for project '([^']+)'")
  if project then
    a.progress:phase("compiling " .. project)
  elseif line:match("^Creating package") or line:match("Success: The package is created") then
    a.progress:phase("creating package")
  end
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
  feedback.log("compile", { "$ altool " .. table.concat(args, " "), "" })
  if opts.show_log then
    feedback.open("compile")
    vim.cmd("wincmd p")
  end
  local nvim_al = require("nvim-al")
  nvim_al._building = true
  local total = 0
  for _, f in ipairs(ws.folders) do
    if f.manifest then
      total = total + 1
    end
  end
  local p = feedback.progress(
    "AL compile",
    vim.fs.basename(ws.file or ws.key),
    ("compiling %d project(s)"):format(total)
  )
  -- altool prints nothing per project while it works; count the per-project
  -- logs it writes to show how far it is
  local timer = vim.uv.new_timer()
  timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      local done = math.min(#vim.fn.glob(tmp .. "/logs/*.log", false, true), total)
      p:phase(
        ("compiling: %d/%d project(s) done"):format(done, total),
        total > 0 and math.floor(done * 100 / total) or nil
      )
    end)
  )
  altool.run(args, {
    cwd = ws.folders[1].path,
    on_line = function(line)
      feedback.append("compile", line)
    end,
  }, function(code, lines)
    timer:stop()
    timer:close()
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
    local summary = ("%d project(s), %d error(s), %d warning(s)"):format(total, n.E, n.W)
    if code == 0 and n.E == 0 then
      p:finish(true, "compiled " .. summary)
    elseif n.E > 0 then
      p:finish(false, "compile failed: " .. summary)
      util.notify(
        "compile failed: " .. summary .. "\nerrors in quickfix, :AL log for the full output",
        vim.log.levels.ERROR
      )
    else
      -- failed without error logs (e.g. altool itself could not start)
      feedback.fail(p, "compile", lines, code)
    end
  end)
end

return M
