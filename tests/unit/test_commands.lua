local eq = MiniTest.expect.equality

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["nvim-al.commands"] = nil
      vim.g.loaded_nvim_al = nil
      vim.cmd("runtime plugin/nvim-al.lua")
    end,
  },
})

T["names and completion"] = function()
  local c = require("nvim-al.commands")
  eq(c.names(), {
    "build",
    "compile",
    "debug",
    "info",
    "log",
    "publish",
    "restart",
    "symbols",
    "target",
    "test",
  })
  eq(c.complete("", "AL ", 3), c.names())
  eq(c.complete("co", "AL co", 5), { "compile" })
  eq(c.complete("", "AL symbols ", 11), { "global" })
end

T["unknown subcommand lists valid ones"] = function()
  local notes = {}
  local orig = vim.notify
  vim.notify = function(m, l)
    table.insert(notes, { m, l })
  end
  vim.cmd("AL foo")
  vim.notify = orig
  eq(#notes, 1)
  eq(
    notes[1][1],
    "nvim-al: unknown subcommand 'foo'; valid: build, compile, debug, info, log, publish, restart, symbols, target, test"
  )
  eq(notes[1][2], vim.log.levels.ERROR)
end

T[":AL log opens the most recent output"] = function()
  local fb = require("nvim-al.feedback")
  fb.log("publish", { "line 1", "Error: boom" })
  vim.cmd("AL log")
  eq(vim.api.nvim_buf_get_name(0), "nvim-al://publish")
  eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "line 1", "Error: boom" })
  vim.cmd("close")
  eq(require("nvim-al.commands").complete("p", "AL log p", 8), { "publish" })
end

T[":AL is defined with completion"] = function()
  local cmd = vim.api.nvim_get_commands({})["AL"]
  eq(cmd ~= nil, true)
  eq(vim.fn.getcompletion("AL p", "cmdline"), { "publish" })
end

return T
