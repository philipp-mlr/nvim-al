local H = require("helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["nvim-al.workspace"] = nil
    end,
  },
})

local function ws_mod()
  return require("nvim-al.workspace")
end

T["git_root finds .git directory and .git file"] = function()
  local multi = H.fixture("multi")
  eq(ws_mod().git_root(multi .. "/apps/A/app/src/A_app.Codeunit.al"), multi)
  local single = H.fixture("single")
  eq(ws_mod().git_root(single .. "/src/X.Codeunit.al"), single)
end

T["project_folder stops at nearest app.json"] = function()
  local multi = H.fixture("multi")
  eq(ws_mod().project_folder(multi .. "/apps/A/app/src/A_app.Codeunit.al"), multi .. "/apps/A/app")
end

T["outermost workspace file wins"] = function()
  local multi = H.fixture("multi")
  local ws = ws_mod().resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  eq(ws.file, multi .. "/all.code-workspace")
  eq(ws.key, ws.file)
  eq(ws.root, multi)
  eq(#ws.folders, 3)
  eq(ws.folders[1].path, multi .. "/apps/A/app")
  eq(ws.folders[1].name, "A")
  eq(ws.folders[1].index, 0)
  eq(ws.folders[2].name, "A - Test")
  eq(ws.folders[3].name, "app")
  eq(ws.folders[3].index, 2)
  eq(ws.settings["al.codeAnalyzers"][1], "${CodeCop}")
end

T["workspace_file hook overrides the choice"] = function()
  local multi = H.fixture("multi")
  local seen
  local ws = ws_mod().resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al", {
    workspace_file = function(project, candidates)
      seen = { project, candidates }
      for _, c in ipairs(candidates) do
        if c:find("A.code-workspace", 1, true) then
          return c
        end
      end
    end,
  })
  eq(ws.file, multi .. "/apps/A/A.code-workspace")
  eq(#ws.folders, 2)
  eq(seen[1], multi .. "/apps/A/app")
  eq(#seen[2], 2)
end

T["single-folder mode with a .git file"] = function()
  local single = H.fixture("single")
  local ws = ws_mod().resolve(single .. "/src/X.Codeunit.al")
  eq(ws.file, nil)
  eq(ws.key, single)
  eq(ws.root, single)
  eq(#ws.folders, 1)
  eq(ws.folders[1].path, single)
  eq(ws.folders[1].name, "Single")
  eq(ws.settings, {})
end

T["no app.json returns nil and a reason"] = function()
  local loose = H.fixture("loose")
  local ws, reason = ws_mod().resolve(loose .. "/x.al")
  eq(ws, nil)
  eq(reason, "no app.json")
end

T["manifest with BOM and trailing comma loads"] = function()
  local multi = H.fixture("multi")
  local m = ws_mod().load_manifest(multi .. "/apps/A/app")
  eq(m.id, "aaaaaaaa-0000-0000-0000-000000000001")
  eq(m.name, "A")
  eq(m.dependencies, {})
  eq(m.raw:sub(1, 1), "{")
  local ws = ws_mod().resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  eq(ws.folders[1].manifest.id, m.id)
end

T["two copies resolve to different keys"] = function()
  local a, b = H.fixture("multi"), H.fixture("multi")
  local wa = ws_mod().resolve(a .. "/apps/A/app/src/A_app.Codeunit.al")
  local wb = ws_mod().resolve(b .. "/apps/A/app/src/A_app.Codeunit.al")
  MiniTest.expect.no_equality(wa.key, wb.key)
end

T["missing folder in workspace file is skipped"] = function()
  local multi = H.fixture("multi")
  vim.fn.writefile({
    '{ "folders": [ { "path": "apps/A/app" }, { "path": "does/not/exist" } ] }',
  }, multi .. "/all.code-workspace")
  local ws = ws_mod().resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  eq(ws.file, multi .. "/all.code-workspace")
  eq(#ws.folders, 1)
end

T["tie at same depth: alphabetical plus one notice"] = function()
  local multi = H.fixture("multi")
  vim.fn.writefile({ '{ "folders": [ { "path": "apps/A/app" } ] }' }, multi .. "/zz.code-workspace")
  vim.fn.writefile({ '{ "folders": [ { "path": "apps/A/app" } ] }' }, multi .. "/aa.code-workspace")
  local util = require("nvim-al.util")
  local notes = {}
  local orig = util.notify_once
  util.notify_once = function(id, msg)
    table.insert(notes, msg)
  end
  local ws = ws_mod().resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  util.notify_once = orig
  eq(ws.file, multi .. "/aa.code-workspace")
  eq(#notes, 1)
end

T["minor: a sibling resolves to its own outermost workspace, not the one opened first"] = function()
  local multi = H.fixture("multi")
  -- inner workspace lists A/app only; the outer one lists A/app and A/test
  vim.fn.writefile({ '{ "folders": [ { "path": "app" } ] }' }, multi .. "/apps/A/A.code-workspace")
  vim.fn.writefile(
    { '{ "folders": [ { "path": "apps/A/test" }, { "path": "apps/B/app" } ] }' },
    multi .. "/all.code-workspace"
  )
  -- open A/app first: only A.code-workspace lists it
  local wa = ws_mod().resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  eq(wa.file, multi .. "/apps/A/A.code-workspace")
  -- A/test is in that workspace? no. B/app: its own resolution, the outer file
  local wb = ws_mod().resolve(multi .. "/apps/B/app/src/B_app.Codeunit.al")
  eq(wb.file, multi .. "/all.code-workspace")
  -- now a case where the first-opened workspace contains the sibling
  ws_mod()._reset()
  vim.fn.writefile(
    { '{ "folders": [ { "path": "app" }, { "path": "test" } ] }' },
    multi .. "/apps/A/A.code-workspace"
  )
  vim.fn.writefile(
    { '{ "folders": [ { "path": "apps/A/test" } ] }' },
    multi .. "/all.code-workspace"
  )
  eq(
    ws_mod().resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al").file,
    multi .. "/apps/A/A.code-workspace"
  )
  -- A/test is listed by both; outermost (all) must win regardless of what was opened first
  eq(
    ws_mod().resolve(multi .. "/apps/A/test/src/A_test.Codeunit.al").file,
    multi .. "/all.code-workspace"
  )
end

T["folder_for picks the deepest folder"] = function()
  local multi = H.fixture("multi")
  local ws = ws_mod().resolve(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  eq(ws_mod().folder_for(ws, multi .. "/apps/A/test/src/A_test.Codeunit.al").name, "A - Test")
  eq(ws_mod().folder_for(ws, multi .. "/README.md"), nil)
end

T["resolve is cached and invalidate drops it"] = function()
  local multi = H.fixture("multi")
  local file = multi .. "/apps/A/app/src/A_app.Codeunit.al"
  local w1 = ws_mod().resolve(file)
  eq(ws_mod().resolve(file) == w1, true)
  ws_mod().invalidate(multi .. "/apps/A/app/app.json")
  eq(ws_mod().resolve(file) == w1, false)
end

return T
