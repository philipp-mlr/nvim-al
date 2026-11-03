local H = require("helpers")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["compiler lines: absolute, relative with [OUT], warning, info, noise"] = function()
  local qf = require("nvim-al.quickfix")
  local items = qf.from_compiler_lines({
    "/abs/src/A.al(12,5): error AL0118: The name 'X' does not exist.",
    "[OUT] src/B.al(3,9): warning AA0137: Variable 'Unused' is unused.",
    "src/C.al(1,1): info AL0792: Something informative.",
    "Starting compilation of 1 project(s)",
    "",
  }, "/base/proj")
  eq(#items, 3)
  eq(items[1], {
    filename = "/abs/src/A.al",
    lnum = 12,
    col = 5,
    type = "E",
    text = "AL0118: The name 'X' does not exist.",
  })
  eq(items[2].filename, "/base/proj/src/B.al")
  eq(items[2].type, "W")
  eq(items[2].text, "AA0137: Variable 'Unused' is unused.")
  eq(items[3].type, "I")
end

T["error log: severities, ranges, suppressed skipped"] = function()
  local qf = require("nvim-al.quickfix")
  local items = qf.from_error_log(H.root .. "/tests/fixtures/errorlog/App_20261103.errorLog.json")
  eq(#items, 3)
  eq(items[1], {
    filename = "/abs/src/Mgt.Codeunit.al",
    lnum = 47,
    col = 9,
    end_lnum = 47,
    end_col = 25,
    type = "E",
    text = "AL0118: The name 'ThisDoesNotExist' does not exist in the current context.",
  })
  eq(items[2].type, "W")
  eq(items[3].type, "I")
end

T["error log: issue without a location has no filename"] = function()
  local qf = require("nvim-al.quickfix")
  local p = vim.fn.tempname()
  vim.fn.writefile({
    vim.json.encode({
      issues = {
        {
          ruleId = "AD0001",
          fullMessage = "Analyzer crashed",
          properties = { severity = "Error" },
        },
        {
          ruleId = "AD0001",
          locations = { { analysisTarget = { { uri = "" } } } },
          fullMessage = "x",
          properties = { severity = "Error" },
        },
      },
    }),
  }, p)
  local items = qf.from_error_log(p)
  eq(#items, 2)
  eq(items[1].filename, nil)
  eq(items[2].filename, nil)
  eq(items[1].text, "AD0001: Analyzer crashed")
end

T["error log: missing or broken file yields nothing"] = function()
  local qf = require("nvim-al.quickfix")
  eq(qf.from_error_log("/nonexistent.json"), {})
  local p = vim.fn.tempname()
  vim.fn.writefile({ "{ broken" }, p)
  eq(qf.from_error_log(p), {})
end

return T
