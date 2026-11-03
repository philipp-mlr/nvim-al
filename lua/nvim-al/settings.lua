-- al.* settings per workspace folder, resolved with VS Code's precedence,
-- and the WorkspaceSettings payload the language server expects
-- (docs/protocol.md §2.4).
local closure = require("nvim-al.closure")
local jsonc = require("nvim-al.jsonc")

local M = {}

--- Defaults from the AL extension's setting schema, for the keys we send.
M.defaults = {
  ["al.assemblyProbingPaths"] = { "./.netpackages" },
  ["al.codeAnalyzers"] = {},
  ["al.enableCodeAnalysis"] = false,
  ["al.backgroundCodeAnalysis"] = "File",
  ["al.packageCachePath"] = { "./.alpackages" },
  ["al.ruleSetPath"] = vim.NIL,
  ["al.enableCodeActions"] = true,
  ["al.incrementalBuild"] = false,
  ["al.enableCodeLensExternalUsage"] = false,
  ["al.outputAnalyzerStatistics"] = false,
  ["al.enableExternalRulesets"] = true,
  ["al.namespaceTemplate"] = vim.NIL,
  ["al.compilationOptions"] = {},
}

local function al_keys(t)
  local out = {}
  for k, v in pairs(t or {}) do
    if type(k) == "string" and k:sub(1, 3) == "al." then
      out[k] = v
    end
  end
  return out
end

--- Flat al.* map for `folder`: schema defaults < cfg.settings < workspace file
--- settings < <folder>/.vscode/settings.json, then hooks.settings.
---@param ws nvim_al.Workspace
---@param folder nvim_al.Folder
---@param cfg nvim_al.Config
---@return table<string, any>
function M.resolve(ws, folder, cfg)
  local folder_settings = jsonc.read(folder.path .. "/.vscode/settings.json") or {}
  local map = vim.tbl_extend(
    "force",
    vim.deepcopy(M.defaults),
    al_keys(cfg.settings),
    al_keys(ws.settings),
    al_keys(folder_settings)
  )
  if cfg.hooks and cfg.hooks.settings then
    map = cfg.hooks.settings(folder, map) or map
  end
  return map
end

local function list(v)
  if v == nil or v == vim.NIL then
    return {}
  end
  if type(v) == "string" then
    return { v }
  end
  return v
end

local function background(v)
  if v == true then
    return "File"
  elseif v == false then
    return "None"
  end
  return v
end

local function analyzers(values, folder_dir)
  if not folder_dir then
    return values
  end
  local dir = folder_dir:gsub("/+$", "")
  return vim.tbl_map(function(a)
    local rest = a:match("^%${analyzerFolder}[/\\]?(.*)$")
    if rest then
      return dir .. "/" .. rest
    end
    return a
  end, values)
end

local function nilish(v)
  if v == nil then
    return vim.NIL
  end
  return v
end

---@class nvim_al.PayloadOpts
---@field active boolean
---@field parent string|nil dependencyParentWorkspacePath

--- The WorkspaceSettings object for al/setActiveWorkspace and
--- workspace/didChangeConfiguration.
---@param ws nvim_al.Workspace
---@param folder nvim_al.Folder
---@param cfg nvim_al.Config
---@param opts nvim_al.PayloadOpts
---@return table
function M.payload(ws, folder, cfg, opts)
  local s = M.resolve(ws, folder, cfg)
  local res = {
    assemblyProbingPaths = list(s["al.assemblyProbingPaths"]),
    codeAnalyzers = analyzers(list(s["al.codeAnalyzers"]), cfg.analyzer_folder),
    enableCodeAnalysis = s["al.enableCodeAnalysis"],
    backgroundCodeAnalysis = background(s["al.backgroundCodeAnalysis"]),
    packageCachePaths = list(s["al.packageCachePath"]),
    ruleSetPath = nilish(s["al.ruleSetPath"]),
    enableCodeActions = s["al.enableCodeActions"],
    incrementalBuild = s["al.incrementalBuild"],
    enableCodeLensExternalUsage = s["al.enableCodeLensExternalUsage"],
    outputAnalyzerStatistics = s["al.outputAnalyzerStatistics"],
    enableExternalRulesets = s["al.enableExternalRulesets"],
    namespaceTemplate = nilish(s["al.namespaceTemplate"]),
  }
  local co = s["al.compilationOptions"]
  if type(co) == "table" then
    res.generateReportLayout = co.generateReportLayout
    res.parallelBuild = co.parallel
    res.maxDegreeOfParallelism = co.maxDegreeOfParallelism
    res.captureSymbolUsage = co.captureSymbolUsage
    res.outFolder = co.outFolder
  end

  local refs = {}
  for _, r in ipairs(closure.references(ws, folder)) do
    refs[#refs + 1] = {
      appId = r.manifest.id,
      name = r.manifest.name,
      publisher = r.manifest.publisher,
      version = r.manifest.version,
    }
  end

  return {
    workspacePath = folder.path,
    alResourceConfigurationSettings = res,
    setActiveWorkspace = opts.active,
    dependencyParentWorkspacePath = nilish(opts.parent),
    expectedProjectReferenceDefinitions = refs,
    activeWorkspaceClosure = opts.active and closure.closure(ws, folder) or {},
  }
end

return M
