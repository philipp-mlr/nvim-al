local H = require("helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      require("nvim-al.workspace")._reset()
    end,
  },
})

local function load(multi)
  local ws = require("nvim-al.workspace").resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  local by = {}
  for _, f in ipairs(ws.folders) do
    by[f.name] = f
  end
  return ws, by
end

local function cfg(over)
  return require("nvim-al.config").merge(over or {})
end

T["config merge warns on unknown keys"] = function()
  local util = require("nvim-al.util")
  local msgs = {}
  local orig = util.notify
  util.notify = function(m)
    table.insert(msgs, m)
  end
  local c = require("nvim-al.config").merge({ bogus = 1, dotnet = "/x/dotnet" })
  util.notify = orig
  eq(c.dotnet, "/x/dotnet")
  eq(c.hooks, {})
  eq(#msgs, 1)
  MiniTest.expect.equality(msgs[1]:find("bogus", 1, true) ~= nil, true)
end

T["precedence: defaults < user < workspace file < folder settings.json"] = function()
  local settings = require("nvim-al.settings")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  local c = cfg({ settings = { ["al.ruleSetPath"] = "user.json", ["al.incrementalBuild"] = true } })
  local a = settings.resolve(ws, f["A"], c)
  eq(a["al.ruleSetPath"], "${workspaceFolder}/../../../ws.ruleset.json")
  eq(a["al.incrementalBuild"], true)
  eq(a["al.enableCodeActions"], true) -- schema default
  local b = settings.resolve(ws, f["app"], c)
  eq(b["al.ruleSetPath"], "./b.ruleset.json")
end

T["payload for the active folder"] = function()
  local settings = require("nvim-al.settings")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  local p = settings.payload(ws, f["app"], cfg(), { active = true })
  eq(p.workspacePath, f["app"].path)
  eq(p.setActiveWorkspace, true)
  eq(p.dependencyParentWorkspacePath, vim.NIL)
  eq(p.activeWorkspaceClosure, { f["app"].path, f["A"].path })
  eq(#p.expectedProjectReferenceDefinitions, 1)
  eq(p.expectedProjectReferenceDefinitions[1], {
    appId = "aaaaaaaa-0000-0000-0000-000000000001",
    name = "A",
    publisher = "Fixture",
    version = "1.0.0.0",
  })
  local r = p.alResourceConfigurationSettings
  eq(type(r.assemblyProbingPaths), "table")
  eq(r.packageCachePaths, { "./.alpackages" })
  eq(r.codeAnalyzers, { "${CodeCop}" })
  eq(r.ruleSetPath, "./b.ruleset.json")
  eq(r.backgroundCodeAnalysis, "File")
end

T["payload for a dependency folder"] = function()
  local settings = require("nvim-al.settings")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  local p = settings.payload(ws, f["A"], cfg(), { active = false, parent = f["app"].path })
  eq(p.setActiveWorkspace, false)
  eq(p.dependencyParentWorkspacePath, f["app"].path)
  eq(p.activeWorkspaceClosure, {})
end

T["value mapping: bool backgroundCodeAnalysis, string packageCachePath, null probing paths"] = function()
  local settings = require("nvim-al.settings")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  local c = cfg({
    settings = {
      ["al.backgroundCodeAnalysis"] = false,
      ["al.packageCachePath"] = "../../.alpackages",
      ["al.assemblyProbingPaths"] = vim.NIL,
    },
  })
  local r = settings.payload(ws, f["A"], c, { active = true }).alResourceConfigurationSettings
  eq(r.backgroundCodeAnalysis, "None")
  eq(r.packageCachePaths, { "../../.alpackages" })
  eq(r.assemblyProbingPaths, {})
  c.settings["al.backgroundCodeAnalysis"] = true
  r = settings.payload(ws, f["A"], c, { active = true }).alResourceConfigurationSettings
  eq(r.backgroundCodeAnalysis, "File")
end

T["analyzer_folder rewrites ${analyzerFolder} only"] = function()
  local settings = require("nvim-al.settings")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  ws.settings["al.codeAnalyzers"] =
    { "${CodeCop}", "${analyzerFolder}ALCops.LinterCop.dll", "${analyzerFolder}/X.dll" }
  local c = cfg({ analyzer_folder = "/opt/cops/" })
  local r = settings.payload(ws, f["A"], c, { active = true }).alResourceConfigurationSettings
  eq(r.codeAnalyzers, { "${CodeCop}", "/opt/cops/ALCops.LinterCop.dll", "/opt/cops/X.dll" })
  -- without the option, values pass through unresolved
  r = settings.payload(ws, f["A"], cfg(), { active = true }).alResourceConfigurationSettings
  eq(r.codeAnalyzers[2], "${analyzerFolder}ALCops.LinterCop.dll")
end

T["settings hook runs last"] = function()
  local settings = require("nvim-al.settings")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  local got
  local c = cfg({
    hooks = {
      settings = function(folder, map)
        got = folder.name
        map["al.ruleSetPath"] = "/hook.json"
        return map
      end,
    },
  })
  eq(settings.resolve(ws, f["app"], c)["al.ruleSetPath"], "/hook.json")
  eq(got, "app")
end

return T
