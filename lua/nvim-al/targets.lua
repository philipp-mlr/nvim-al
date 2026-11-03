-- :AL publish, :AL symbols, :AL test: altool against the project's target,
-- with connection flags passed explicitly and credentials via the environment.
local altool = require("nvim-al.altool")
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
  require("nvim-al.build").build(ctx.bufnr, function(ok)
    if not ok then
      return
    end
    local app = newest_app(ctx)
    if not app then
      return util.notify("no .app found for " .. ctx.folder.name, vim.log.levels.ERROR)
    end
    with_target(ctx, function(target, env)
      local args = { "publishapp", app, "--project", ctx.folder.path }
      vim.list_extend(args, launch.altool_flags(target))
      util.notify(("publishing %s to %s…"):format(vim.fs.basename(app), target.name))
      altool.run(args, { cwd = ctx.folder.path, env = env }, function(code, lines)
        if code == 0 then
          util.notify("published " .. vim.fs.basename(app))
        else
          util.notify(
            "publish failed: " .. (lines[#lines] or ("exit code " .. code)),
            vim.log.levels.ERROR
          )
        end
      end)
    end)
  end)
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
    util.notify("downloading symbols for " .. ctx.folder.name .. "…")
    altool.run(args, { cwd = ctx.folder.path, env = env }, function(code, lines)
      if code ~= 0 then
        return util.notify(
          "symbol download failed: " .. (lines[#lines] or ("exit code " .. code)),
          vim.log.levels.ERROR
        )
      end
      util.notify("symbols downloaded for " .. ctx.folder.name)
      local lsp = require("nvim-al.lsp")
      local client = lsp.client_for(ctx.bufnr)
      if client then
        lsp.switch(client, ctx.folder, { force = true })
      end
    end)
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
    util.notify(
      ("running %s%s…"):format(test.codeunit, test.method and (" " .. test.method) or "")
    )
    altool.run(args, { cwd = ctx.folder.path, env = env }, function(code, out)
      local r = M.parse_runtests(table.concat(out, "\n"))
      if not r then
        return util.notify(
          "test run failed: " .. (out[#out] or ("exit code " .. code)),
          vim.log.levels.ERROR
        )
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
      util.notify(
        ("tests: %d passed, %d failed, %d skipped"):format(r.passed, r.failed, r.skipped),
        r.failed > 0 and vim.log.levels.ERROR or vim.log.levels.INFO
      )
    end)
  end)
end

return M
