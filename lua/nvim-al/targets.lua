-- :AL publish, :AL symbols, :AL test: altool against the project's target,
-- with connection flags passed explicitly and credentials via the environment.
local altool = require("nvim-al.altool")
local feedback = require("nvim-al.feedback")
local quickfix = require("nvim-al.quickfix")
local credentials = require("nvim-al.credentials")
local launch = require("nvim-al.launch")
local util = require("nvim-al.util")

local M = {}

local function context(bufnr)
  return require("nvim-al.build").context(bufnr)
end

--- Run `fn(target, env)` with the target and credentials of a project.
local function with_target(ctx, fn)
  launch.target(ctx.ws, ctx.folder, ctx.cfg, function(target)
    if not target then
      return
    end
    credentials.env(target, function(env)
      if not env then
        return util.notify("cancelled (no credentials)", vim.log.levels.WARN)
      end
      fn(target, env)
    end)
  end)
end

--- altool output lines that mark a phase worth showing.
local PHASES = {
  { "^Sending request to .*/dev/apps", "uploading" },
  { "^Downloading symbols", "downloading symbols" },
  { "^Running tests", "running tests" },
  { "^Authenticat", "authenticating" },
}

--- Run altool for `op` with progress phases and a log buffer.
--- `p` is an existing progress (publish continues the build's) or a
--- {title, subject, phase} spec for a new one. on_done(code, lines, p).
local function run_tool(op, p, args, opts, on_done)
  if getmetatable(p) == nil then
    p = feedback.progress(p[1], p[2], p[3])
  end
  feedback.log(op, { "$ altool " .. table.concat(args, " "), "" })
  opts = vim.tbl_extend("force", opts, {
    on_line = function(line)
      feedback.append(op, line)
      for _, ph in ipairs(PHASES) do
        if line:match(ph[1]) then
          p:phase(ph[2])
        end
      end
    end,
  })
  local header = { "$ altool " .. table.concat(args, " "), "" }
  altool.run(args, opts, function(code, lines)
    -- the complete output (stdout and stderr) replaces the streamed lines
    feedback.log(op, vim.list_extend(vim.list_extend({}, header), lines))
    feedback.append(op, "")
    feedback.append(op, "[exit code " .. tostring(code) .. "]")
    on_done(code, lines, p)
  end)
end

--- Newest `<publisher>_<name>_*.app` in the folder (or its outFolder).
local function newest_app(ctx)
  local m = ctx.folder.manifest
  if not m then
    return nil
  end
  local dirs = { ctx.folder.path }
  local s = require("nvim-al.settings").resolve(ctx.ws, ctx.folder, ctx.cfg)
  local co = s["al.compilationOptions"]
  if type(co) == "table" and type(co.outFolder) == "string" then
    local out = co.outFolder
    if out:sub(1, 1) ~= "/" then
      out = ctx.folder.path .. "/" .. out
    end
    table.insert(dirs, 1, vim.fs.normalize(out))
  end
  local best, best_time
  local prefix = ("%s_%s_"):format(m.publisher, m.name)
  for _, d in ipairs(dirs) do
    for name, typ in vim.fs.dir(d) do
      if typ == "file" and name:sub(1, #prefix) == prefix and name:match("%.app$") then
        local p = d .. "/" .. name
        local st = vim.uv.fs_stat(p)
        local t = st and st.mtime.sec or 0
        -- prefer the manifest version; otherwise the most recently written
        if name == prefix .. m.version .. ".app" then
          return p
        end
        if not best_time or t > best_time then
          best, best_time = p, t
        end
      end
    end
  end
  return best
end

--- Build, then publish the project's .app to its target.
---@param bufnr integer|nil
function M.publish(bufnr)
  local ctx = context(bufnr)
  if not ctx then
    return
  end
  if ctx.cfg.hooks.publish and ctx.cfg.hooks.publish(ctx) then
    return
  end
  local name = ctx.folder.name
  local p = feedback.progress("AL publish", name, "building")
  require("nvim-al.build").build(ctx.bufnr, function(ok)
    if not ok then
      return -- build reported the failure on this progress
    end
    local app = newest_app(ctx)
    if not app then
      p:finish(false, "publish failed")
      return util.notify("no .app found for " .. name, vim.log.levels.ERROR)
    end
    with_target(ctx, function(target, env)
      local args = { "publishapp", app, "--project", ctx.folder.path }
      vim.list_extend(args, launch.altool_flags(target))
      p:phase("publishing to " .. target.name)
      run_tool("publish", p, args, { cwd = ctx.folder.path, env = env }, function(code, lines)
        if code == 0 then
          p:finish(true, "published to " .. target.name)
          return
        end
        -- server-side compile errors are relative to the project folder
        local items = quickfix.from_compiler_lines(lines, ctx.folder.path)
        for _, r in ipairs(feedback.reasons(lines)) do
          if r:match("^error %u+%d+:") then
            local code_, text = r:match("^error (%u+%d+):%s*(.*)$")
            table.insert(items, 1, { type = "E", text = code_ .. ": " .. text })
          end
        end
        vim.fn.setqflist({}, "r", { title = "AL publish", items = items })
        feedback.fail(p, "publish of " .. name, lines, code, #items)
      end)
    end)
  end, { progress = p })
end

--- Download symbols for the project, then make the server reload them.
---@param bufnr integer|nil
---@param opts? { global?: boolean }
function M.symbols(bufnr, opts)
  opts = opts or {}
  local ctx = context(bufnr)
  if not ctx then
    return
  end
  local function run(target, env)
    local args = { "downloadsymbols", "--project", ctx.folder.path, "--raw" }
    if opts.global then
      table.insert(args, "--globalsourcesonly")
    else
      vim.list_extend(args, launch.altool_flags(target))
    end
    run_tool(
      "symbols",
      {
        "AL symbols",
        ctx.folder.name,
        opts.global and "downloading from NuGet" or "downloading symbols",
      },
      args,
      { cwd = ctx.folder.path, env = env },
      function(code, lines, p)
        if code ~= 0 then
          return feedback.fail(p, "symbol download for " .. ctx.folder.name, lines, code)
        end
        p:finish(true, "symbols downloaded")
        local lsp = require("nvim-al.lsp")
        local client = lsp.client_for(ctx.bufnr)
        if client then
          lsp.switch(client, ctx.folder, { force = true })
        end
      end
    )
  end
  if opts.global then
    return run(nil, {})
  end
  with_target(ctx, run)
end

--- The test under the cursor: `{ codeunit, method?, method_line? }` for a
--- `Subtype = Test` codeunit, nil otherwise. `row` is 1-based.
---@param lines string[]
---@param row integer
---@return table|nil
function M.test_at_cursor(lines, row)
  local id, is_test
  for _, l in ipairs(lines) do
    id = id or tonumber(l:match("^%s*codeunit%s+(%d+)"))
    if l:match("^%s*Subtype%s*=%s*Test%s*;") then
      is_test = true
    end
  end
  if not (id and is_test) then
    return nil
  end
  -- nearest procedure at or above the cursor, and whether [Test] precedes it
  for i = math.min(row, #lines), 1, -1 do
    local name = lines[i]:match("^%s*procedure%s+([%w_]+)%s*%(")
      or lines[i]:match('^%s*procedure%s+"([^"]+)"%s*%(')
    local local_proc = lines[i]:match("^%s*local%s+procedure")
    if name or local_proc then
      if name then
        for j = i - 1, math.max(1, i - 3), -1 do
          if lines[j]:match("^%s*%[Test%]") then
            return { codeunit = id, method = name, method_line = i }
          end
          if lines[j]:match("^%s*$") then
            break
          end
        end
      end
      return { codeunit = id }
    end
  end
  return { codeunit = id }
end

--- Parse `altool runtests` JSON output.
---@param text string
---@return { passed: integer, failed: integer, skipped: integer, failures: table[] }|nil
function M.parse_runtests(text)
  local start = text:find("{", 1, true)
  if not start then
    return nil
  end
  local ok, v = pcall(vim.json.decode, text:sub(start), { luanil = { object = true } })
  if not ok or type(v) ~= "table" or type(v.data) ~= "table" then
    return nil
  end
  local d = v.data
  local failures = {}
  for _, r in ipairs(d.results or {}) do
    if r.status == "failed" and r.methodName and r.methodName ~= "" then
      failures[#failures + 1] =
        { codeunit = r.codeunitId, method = r.methodName, message = r.output or "" }
    end
  end
  -- the codeunit row (empty methodName) is counted in the totals; leave it out
  local summary_rows = 0
  for _, r in ipairs(d.results or {}) do
    if (r.methodName or "") == "" and r.status == "passed" then
      summary_rows = summary_rows + 1
    end
  end
  return {
    passed = math.max(0, (d.passed or 0) - summary_rows),
    failed = #failures,
    skipped = d.skipped or 0,
    failures = failures,
  }
end

--- Run the test method (or codeunit) at the cursor, or the given one.
---@param bufnr integer|nil
---@param opts? { codeunit?: integer, method?: string }
function M.test(bufnr, opts)
  opts = opts or {}
  local ctx = context(bufnr)
  if not ctx then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(ctx.bufnr, 0, -1, false)
  local at = M.test_at_cursor(lines, vim.api.nvim_win_get_cursor(0)[1])
  local test = opts.codeunit and { codeunit = opts.codeunit, method = opts.method } or at
  if not test then
    return util.notify(
      "not a test codeunit; pass a codeunit id: :AL test <id> [method]",
      vim.log.levels.WARN
    )
  end
  ctx.test = test
  if ctx.cfg.hooks.test and ctx.cfg.hooks.test(ctx) then
    return
  end
  local file = vim.api.nvim_buf_get_name(ctx.bufnr)
  with_target(ctx, function(target, env)
    local args = { "runtests", tostring(test.codeunit), "--project", ctx.folder.path }
    if test.method then
      vim.list_extend(args, { "--testmethods", test.method })
    end
    vim.list_extend(args, launch.altool_flags(target))
    local label = ("%s%s"):format(test.codeunit, test.method and (" " .. test.method) or "")
    run_tool(
      "test",
      { "AL test", label, "running tests" },
      args,
      { cwd = ctx.folder.path, env = env },
      function(code, out, p)
        local r = M.parse_runtests(table.concat(out, "\n"))
        if not r then
          return feedback.fail(p, "test run of " .. label, out, code)
        end
        local items = {}
        for _, f in ipairs(r.failures) do
          local lnum = 1
          for i, l in ipairs(lines) do
            if l:match('procedure%s+"?' .. vim.pesc(f.method) .. '"?%s*%(') then
              lnum = i
            end
          end
          items[#items + 1] = {
            filename = file,
            lnum = lnum,
            type = "E",
            text = f.method .. ": " .. f.message,
          }
        end
        vim.fn.setqflist({}, "r", { title = "AL tests", items = items })
        if #items > 0 then
          vim.cmd("botright copen")
        end
        local summary = ("tests: %d passed, %d failed, %d skipped"):format(
          r.passed,
          r.failed,
          r.skipped
        )
        p:finish(r.failed == 0, summary)
        util.notify(summary, r.failed > 0 and vim.log.levels.ERROR or vim.log.levels.INFO)
      end
    )
  end)
end

return M
