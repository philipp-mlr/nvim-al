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

T["references and closure"] = function()
  local closure = require("nvim-al.closure")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  eq(closure.closure(ws, f["A - Test"]), { f["A - Test"].path, f["A"].path })
  -- B depends on A with an upper-case id: ids compare case-insensitively
  eq(closure.closure(ws, f["app"]), { f["app"].path, f["A"].path })
  eq(closure.references(ws, f["A"]), {})
  local refs = closure.references(ws, f["app"])
  eq(#refs, 1)
  eq(refs[1].path, f["A"].path)
end

T["cycles terminate"] = function()
  local closure = require("nvim-al.closure")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  -- make A depend on B: A -> B -> A
  f["A"].manifest.dependencies = {
    { id = f["app"].manifest.id, name = "B", publisher = "Fixture", version = "2.0.0.0" },
  }
  eq(closure.closure(ws, f["app"]), { f["app"].path, f["A"].path })
  eq(closure.closure(ws, f["A"]), { f["A"].path, f["app"].path })
end

T["folders without manifest are ignored"] = function()
  local closure = require("nvim-al.closure")
  local multi = H.fixture("multi")
  local ws, f = load(multi)
  f["A"].manifest = nil
  eq(closure.closure(ws, f["app"]), { f["app"].path })
end

return T
