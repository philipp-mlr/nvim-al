-- Runs mini.test on the given files and always exits Neovim:
-- 0 when every case passed, 1 on a failure or when collection itself errors.
local M = {}

function M.run(files)
  local ok, err = pcall(MiniTest.run, {
    collect = {
      find_files = function()
        return files
      end,
    },
    execute = {
      reporter = MiniTest.gen_reporter.stdout({ group_depth = 2, quit_on_finish = false }),
    },
  })
  if not ok then
    io.stdout:write("\nERROR: " .. tostring(err) .. "\n")
    vim.cmd("cquit 1")
  end
  -- Execution is asynchronous; wait for it, then exit with the result.
  vim.wait(math.huge, function()
    return not MiniTest.is_executing()
  end, 50)
  local failed = false
  for _, case in ipairs(MiniTest.current.all_cases or {}) do
    if case.exec and case.exec.state and case.exec.state:find("^Fail") then
      failed = true
    end
  end
  io.stdout:write("\n")
  vim.cmd(failed and "cquit 1" or "qall!")
end

return M
