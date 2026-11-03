local T = MiniTest.new_set()

T["module loads with a setup function"] = function()
  local m = require("nvim-al")
  MiniTest.expect.equality(type(m), "table")
  MiniTest.expect.equality(type(m.setup), "function")
end

T["fixture copies restore .git"] = function()
  local H = require("helpers")
  local multi = H.fixture("multi")
  MiniTest.expect.equality(vim.fn.isdirectory(multi .. "/.git"), 1)
  local single = H.fixture("single")
  MiniTest.expect.equality(vim.fn.filereadable(single .. "/.git"), 1)
end

return T
