local util = require("nvim-al.util")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["normalize strips trailing slash"] = function()
  eq(util.normalize("/a/b/"), "/a/b")
  eq(util.normalize("/a//b"), "/a/b")
  eq(util.normalize("/"), "/")
end

T["is_inside"] = function()
  eq(util.is_inside("/a/b/c", "/a/b"), true)
  eq(util.is_inside("/a/b", "/a/b"), true)
  eq(util.is_inside("/a/bc", "/a/b"), false)
  eq(util.is_inside("/a", "/a/b"), false)
end

T["same_path is exact on non-Windows"] = function()
  eq(util.same_path("/a/B", "/a/B/"), true)
  eq(util.same_path("/a/B", "/a/b"), vim.fn.has("win32") == 1)
end

T["read_file"] = function()
  local p = vim.fn.tempname()
  vim.fn.writefile({ "x", "y" }, p)
  eq(util.read_file(p), "x\ny\n")
  eq(util.read_file("/nonexistent"), nil)
end

T["notify prefixes and notify_once dedupes"] = function()
  local got = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(got, { msg, level })
  end
  util.notify("hello")
  util.notify_once("k1", "once")
  util.notify_once("k1", "once")
  vim.notify = orig
  eq(#got, 2)
  eq(got[1][1], "nvim-al: hello")
  eq(got[2][1], "nvim-al: once")
end

return T
