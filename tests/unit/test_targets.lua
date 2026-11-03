local H = require("helpers")
local eq = MiniTest.expect.equality

local env

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for _, m in ipairs({
        "nvim-al",
        "nvim-al.targets",
        "nvim-al.altool",
        "nvim-al.launch",
        "nvim-al.credentials",
        "nvim-al.workspace",
        "nvim-al.build",
      }) do
        package.loaded[m] = nil
      end
      env = { calls = {}, notes = {} }
      env.orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(env.notes, { msg = msg, level = level })
      end
      env.orig_user, env.orig_pass = vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD
      vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD = "admin", "pw"
      local altool = require("nvim-al.altool")
      env.orig_run = altool.run
      altool.run = function(args, opts, on_exit)
        table.insert(env.calls, { args = args, opts = opts })
        on_exit(env.exit_code or 0, env.lines or {})
      end
      env.real = H.fixture("real")
      vim.fn.mkdir(env.real .. "/test/.vscode", "p")
      vim.fn.writefile({
        vim.json.encode({
          version = "0.2.0",
          configurations = {
            {
              name = "Local",
              type = "al",
              request = "attach",
              server = "http://localhost",
              port = 8880,
              serverInstance = "BC",
              tenant = "default",
              authentication = "UserPassword",
              environmentType = "Sandbox",
            },
          },
        }),
      }, env.real .. "/test/.vscode/launch.json")
      vim.fn.mkdir(env.real .. "/app/.vscode", "p")
      vim.fn.writefile(
        vim.fn.readfile(env.real .. "/test/.vscode/launch.json"),
        env.real .. "/app/.vscode/launch.json"
      )
      require("nvim-al").setup({})
    end,
    post_case = function()
      require("nvim-al.altool").run = env.orig_run
      vim.notify = env.orig_notify
      vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD = env.orig_user, env.orig_pass
      vim.fn.setqflist({}, "r")
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

local function lines(path)
  return vim.split(table.concat(vim.fn.readfile(path), "\n"), "\n")
end

T["test_at_cursor: codeunit id and enclosing [Test] procedure"] = function()
  local targets = require("nvim-al.targets")
  local file = env.real .. "/test/src/GadgetTest.Codeunit.al"
  local l = lines(file)
  local row
  for i, s in ipairs(l) do
    if s:find("cursor tests put the cursor in here", 1, true) then
      row = i
    end
  end
  eq(
    targets.test_at_cursor(l, row),
    { codeunit = 50150, method = "SecondTest", method_line = row - 2 }
  )
  -- cursor on the first test's body
  eq(targets.test_at_cursor(l, 12).method, "DescribeReturnsDescription")
  -- cursor in a non-test procedure: whole codeunit
  local helper
  for i, s in ipairs(l) do
    if s:find("local procedure Helper", 1, true) then
      helper = i
    end
  end
  eq(targets.test_at_cursor(l, helper + 1), { codeunit = 50150 })
  -- a non-test codeunit
  eq(targets.test_at_cursor(lines(env.real .. "/app/src/GadgetMgt.Codeunit.al"), 3), nil)
end

T["parse_runtests: real passed output"] = function()
  local targets = require("nvim-al.targets")
  local text = table.concat(vim.fn.readfile(H.root .. "/tests/fixtures/runtests/passed.json"), "\n")
  local r = targets.parse_runtests(text)
  -- altool reports 2 passed: the method plus a codeunit row with an empty
  -- methodName; only real methods are counted
  eq(r, { passed = 1, failed = 0, skipped = 0, failures = {} })
end

T["parse_runtests: failures carry method and message, codeunit summary row skipped"] = function()
  local targets = require("nvim-al.targets")
  local text = table.concat(vim.fn.readfile(H.root .. "/tests/fixtures/runtests/failed.json"), "\n")
  local r = targets.parse_runtests(text)
  eq(r.passed, 1)
  eq(r.failed, 1)
  eq(r.failures, {
    {
      codeunit = 50150,
      method = "SecondTest",
      message = "Assert.AreEqual failed. Expected:<Thing> (Text). Actual:<> (Text). unexpected",
    },
  })
  eq(targets.parse_runtests("not json"), nil)
end

T["test: runs altool with target flags and fills quickfix with failures"] = function()
  local file = env.real .. "/test/src/GadgetTest.Codeunit.al"
  vim.cmd("edit " .. file)
  vim.api.nvim_win_set_cursor(0, { 21, 4 })
  env.lines = vim.fn.readfile(H.root .. "/tests/fixtures/runtests/failed.json")
  env.exit_code = 1
  require("nvim-al.targets").test(0)
  eq(#env.calls, 1)
  local a = env.calls[1].args
  eq(
    vim.list_slice(a, 1, 6),
    { "runtests", "50150", "--project", env.real .. "/test", "--testmethods", "SecondTest" }
  )
  eq(vim.tbl_contains(a, "--serverinstance"), true)
  eq(vim.tbl_contains(a, "8880"), true)
  local qf = vim.fn.getqflist({ items = 0, title = 0 })
  eq(qf.title, "AL tests")
  eq(#qf.items, 1)
  eq(qf.items[1].lnum, 19)
  eq(qf.items[1].text:find("SecondTest", 1, true) ~= nil, true)
  local summary = env.notes[#env.notes].msg
  eq(summary, "nvim-al: tests: 1 passed, 1 failed, 0 skipped")
end

T["publish: build then publishapp with the newest matching .app"] = function()
  local build = require("nvim-al.build")
  build.build = function(_, on_done)
    on_done(true, build.context(0))
  end
  local app = env.real .. "/app"
  vim.fn.writefile({}, app .. "/nvim-al_Real App_0.9.0.0.app")
  vim.fn.writefile({}, app .. "/nvim-al_Real App_1.0.0.0.app")
  vim.fn.writefile({}, app .. "/Other_Thing_9.0.0.0.app")
  vim.uv.fs_utime(app .. "/nvim-al_Real App_0.9.0.0.app", os.time() + 100, os.time() + 100)
  vim.cmd("edit " .. app .. "/src/GadgetMgt.Codeunit.al")
  require("nvim-al.targets").publish(0)
  eq(#env.calls, 1)
  local a = env.calls[1].args
  eq(a[1], "publishapp")
  eq(a[2], app .. "/nvim-al_Real App_1.0.0.0.app")
  eq(vim.list_slice(a, 3, 4), { "--project", app })
end

T["symbols: downloadsymbols with target flags, global variant"] = function()
  vim.cmd("edit " .. env.real .. "/app/src/GadgetMgt.Codeunit.al")
  require("nvim-al.targets").symbols(0)
  require("nvim-al.targets").symbols(0, { global = true })
  eq(#env.calls, 2)
  eq(
    vim.list_slice(env.calls[1].args, 1, 4),
    { "downloadsymbols", "--project", env.real .. "/app", "--raw" }
  )
  eq(vim.tbl_contains(env.calls[1].args, "--server"), true)
  eq(vim.tbl_contains(env.calls[2].args, "--globalsourcesonly"), true)
  eq(vim.tbl_contains(env.calls[2].args, "--server"), false)
end

T["hooks short-circuit publish and test"] = function()
  local seen = {}
  require("nvim-al").setup({
    hooks = {
      publish = function(ctx)
        seen.publish = ctx.folder.name
        return true
      end,
      test = function(ctx)
        seen.test = ctx.test
        return true
      end,
    },
  })
  vim.cmd("edit " .. env.real .. "/test/src/GadgetTest.Codeunit.al")
  vim.api.nvim_win_set_cursor(0, { 21, 4 })
  require("nvim-al.targets").publish(0)
  require("nvim-al.targets").test(0)
  eq(#env.calls, 0)
  eq(seen.publish, "test")
  eq(seen.test, { codeunit = 50150, method = "SecondTest", method_line = 19 })
end

return T
