local H = require("helpers")
local eq = MiniTest.expect.equality

local env

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for _, m in ipairs({ "nvim-al", "nvim-al.build", "nvim-al.altool", "nvim-al.workspace" }) do
        package.loaded[m] = nil
      end
      env = { calls = {}, notes = {} }
      env.orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(env.notes, { msg = msg, level = level })
      end
      -- capture altool invocations instead of running them
      local altool = require("nvim-al.altool")
      env.orig_run = altool.run
      altool.run = function(args, opts, on_exit)
        table.insert(env.calls, { args = args, opts = opts })
        if env.on_run then
          env.on_run(args, opts)
        end
        on_exit(env.exit_code or 0, {})
      end
      env.ext = vim.fn.tempname()
      vim.fn.mkdir(env.ext .. "/bin", "p")
      vim.fn.writefile({ '{ "version": "30.0.1" }' }, env.ext .. "/package.json")
      vim.fn.writefile({}, env.ext .. "/bin/Microsoft.Dynamics.Nav.EditorServices.Host.dll")
      vim.fn.writefile({}, env.ext .. "/bin/altool.dll")
      require("nvim-al").setup({ extension_path = env.ext, analyzer_folder = "/opt/cops" })
      env.multi = H.fixture("multi")
    end,
    post_case = function()
      require("nvim-al.altool").run = env.orig_run
      vim.notify = env.orig_notify
      vim.fn.setqflist({}, "r")
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

local function flag(args, name)
  for i, a in ipairs(args) do
    if a == name then
      return args[i + 1]
    end
  end
end

T["compile: workspace file, analyzers mapped, ruleset absolute, warns on differing folders"] = function()
  vim.cmd("edit " .. env.multi .. "/apps/A/app/src/A_app.Codeunit.al")
  require("nvim-al.build").compile(0)
  eq(#env.calls, 1)
  local args = env.calls[1].args
  eq(vim.list_slice(args, 1, 3), { "workspace", "compile", env.multi .. "/all.code-workspace" })
  eq(flag(args, "--analyzers"), "CodeCop")
  eq(flag(args, "--customanalyzers"), nil)
  -- the server treats ${workspaceFolder}/.. as the folder itself (verified), so
  -- ${workspaceFolder}/../../../ws.ruleset.json from apps/A/app is apps/ws.ruleset.json
  eq(flag(args, "--ruleset"), env.multi .. "/apps/ws.ruleset.json")
  eq(flag(args, "--packagecachepath"), env.multi .. "/apps/A/app/.alpackages")
  eq(flag(args, "--errorlogdirectory") ~= nil, true)
  local warns = vim.tbl_filter(function(n)
    return n.msg:find("differs for", 1, true) ~= nil
  end, env.notes)
  eq(#warns, 1)
  eq(warns[1].msg:find("app", 1, true) ~= nil, true)
end

T["compile: custom analyzers use analyzer_folder; built-ins map to names"] = function()
  local f = env.multi .. "/all.code-workspace"
  local text = table.concat(vim.fn.readfile(f), "\n")
  text = text:gsub(
    '"al.codeAnalyzers": %["%${CodeCop}"%]',
    '"al.codeAnalyzers": ["${CodeCop}", "${UICop}", "${PerTenantExtensionCop}", "${analyzerFolder}ALCops.LinterCop.dll", "/abs/Other.dll"]'
  )
  vim.fn.writefile(vim.split(text, "\n"), f)
  vim.cmd("edit " .. env.multi .. "/apps/A/app/src/A_app.Codeunit.al")
  require("nvim-al.build").compile(0)
  local args = env.calls[1].args
  eq(flag(args, "--analyzers"), "CodeCop,UICop,PTECop")
  local custom = {}
  for i, a in ipairs(args) do
    if a == "--customanalyzers" then
      table.insert(custom, args[i + 1])
    end
  end
  eq(custom, { "/opt/cops/ALCops.LinterCop.dll", "/abs/Other.dll" })
end

T["compile: ${workspaceFolder} package cache resolves like the server"] = function()
  local f = env.multi .. "/all.code-workspace"
  local text = table.concat(vim.fn.readfile(f), "\n")
  text = text:gsub(
    '"settings": {',
    '"settings": { "al.packageCachePath": ["${workspaceFolder}/../../../.alpackages"],',
    1
  )
  vim.fn.writefile(vim.split(text, "\n"), f)
  vim.cmd("edit " .. env.multi .. "/apps/A/app/src/A_app.Codeunit.al")
  require("nvim-al.build").compile(0)
  eq(flag(env.calls[1].args, "--packagecachepath"), env.multi .. "/apps/.alpackages")
end

T["compile: single folder writes a temporary workspace file"] = function()
  local single = H.fixture("single")
  vim.cmd("edit " .. single .. "/src/X.Codeunit.al")
  require("nvim-al.build").compile(0)
  local file = env.calls[1].args[3]
  eq(file:match("%.code%-workspace$") ~= nil, true)
  local ws = vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  eq(ws.folders[1].path, single)
end

T["compile: error logs fill quickfix"] = function()
  env.exit_code = 1
  env.on_run = function(args)
    local dir = flag(args, "--errorlogdirectory")
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(
      vim.fn.readfile(H.root .. "/tests/fixtures/errorlog/App_20261103.errorLog.json"),
      dir .. "/App_1.errorLog.json"
    )
  end
  vim.cmd("edit " .. env.multi .. "/apps/A/app/src/A_app.Codeunit.al")
  require("nvim-al.build").compile(0)
  local qf = vim.fn.getqflist({ items = 0, title = 0 })
  eq(qf.title, "AL compile")
  eq(#qf.items, 3)
  local summary = env.notes[#env.notes].msg
  eq(summary:find("1 error", 1, true) ~= nil, true)
end

T["build: compiler log lines become progress, log buffer and quickfix"] = function()
  vim.cmd("edit " .. env.multi .. "/apps/A/app/src/A_app.Codeunit.al")
  local buf = vim.api.nvim_get_current_buf()
  local mgt = env.multi .. "/apps/A/app/src/A_app.Codeunit.al"
  -- a fake client: createPackage answers after the server "logged" compiler output
  local handlers = {}
  local client = {
    id = 4242,
    request = function(_, method, _, cb)
      if method == "al/createPackage" then
        local h = handlers["window/logMessage"]
        for _, m in ipairs({
          "Microsoft (R) AL Compiler version 30.0.43.45776",
          "Compilation started for project 'A' containing '3' files at '10:21:00.126'.",
          mgt .. "(3,5): error AL0118: The name 'X' does not exist in the current context.",
          mgt .. "(1,1): info AA0247: Use namespaces to organize your code.",
          "Compilation ended at '10:21:04.000'.",
        }) do
          h(nil, { type = 4, message = m }, { client_id = 4242 })
        end
        cb(nil, { success = false })
      end
    end,
  }
  local lsp = require("nvim-al.lsp")
  local orig_client_for = lsp.client_for
  lsp.client_for = function()
    return client
  end
  handlers["window/logMessage"] = require("nvim-al.build").server_log
  local done
  require("nvim-al.build").build(buf, function(ok)
    done = ok
  end)
  vim.wait(1000, function()
    return done ~= nil
  end)
  lsp.client_for = orig_client_for
  eq(done, false)
  local qf = vim.fn.getqflist({ items = 0, title = 0 })
  eq(qf.title, "AL build")
  eq(#qf.items, 1)
  eq(qf.items[1].lnum, 3)
  eq(qf.items[1].text, "AL0118: The name 'X' does not exist in the current context.")
  local log = vim.fn.bufnr("nvim-al://build")
  eq(log > 0, true)
  eq(#vim.api.nvim_buf_get_lines(log, 0, -1, false) >= 5, true)
  local errs = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR
  end, env.notes)
  eq(errs[#errs].msg:find("AL0118", 1, true) ~= nil, true)
end

local function git(dir, ...)
  local r = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()
  assert(r.code == 0, r.stderr)
  return r.stdout
end

-- a real git repo for the fixture: layout.docx and Mine.al tracked, Mine.al
-- already modified by "the user" before the build
local function repo_with_layout()
  local root = env.multi
  vim.fn.delete(root .. "/.git", "rf")
  git(root, "init", "-q")
  git(root, "config", "user.email", "t@t")
  git(root, "config", "user.name", "t")
  local app = root .. "/apps/A/app"
  vim.fn.writefile({ "original" }, app .. "/layout.docx")
  vim.fn.writefile({ "mine" }, app .. "/src/Mine.al")
  git(root, "add", "-A")
  git(root, "commit", "-q", "-m", "init")
  vim.fn.writefile({ "my edit" }, app .. "/src/Mine.al")
  return app
end

local function fake_build_client(on_request)
  local client = {
    id = 4243,
    request = function(_, method, _, cb)
      if method == "al/createPackage" then
        on_request()
        cb(nil, { success = true })
      end
    end,
  }
  local lsp = require("nvim-al.lsp")
  env.orig_client_for = lsp.client_for
  lsp.client_for = function()
    return client
  end
end

T["build: warns about tracked files it rewrote and :AL restore undoes only those"] = function()
  local app = repo_with_layout()
  fake_build_client(function()
    vim.fn.writefile({ "rewritten" }, app .. "/layout.docx")
  end)
  vim.cmd("edit " .. app .. "/src/A_app.Codeunit.al")
  local done
  require("nvim-al.build").build(0, function(ok)
    done = ok
  end)
  vim.wait(3000, function()
    return done ~= nil
  end)
  require("nvim-al.lsp").client_for = env.orig_client_for
  local warns = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.WARN and n.msg:find("rewrote", 1, true)
  end, env.notes)
  eq(#warns, 1)
  eq(warns[1].msg:find("layout.docx", 1, true) ~= nil, true)
  eq(warns[1].msg:find("Mine.al", 1, true), nil)
  eq(warns[1].msg:find(":AL restore", 1, true) ~= nil, true)
  require("nvim-al.build").restore()
  eq(vim.fn.readfile(app .. "/layout.docx"), { "original" })
  eq(vim.fn.readfile(app .. "/src/Mine.al"), { "my edit" })
end

T["build: no warning when nothing tracked changed; no git is fine"] = function()
  local app = repo_with_layout()
  fake_build_client(function() end)
  vim.cmd("edit " .. app .. "/src/A_app.Codeunit.al")
  local done
  require("nvim-al.build").build(0, function(ok)
    done = ok
  end)
  vim.wait(3000, function()
    return done ~= nil
  end)
  vim.fn.delete(env.multi .. "/.git", "rf")
  done = nil
  require("nvim-al.build").build(0, function(ok)
    done = ok
  end)
  vim.wait(3000, function()
    return done ~= nil
  end)
  require("nvim-al.lsp").client_for = env.orig_client_for
  eq(done, true)
  local warns = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.WARN and n.msg:find("rewrote", 1, true)
  end, env.notes)
  eq(#warns, 0)
end

T["build: without a language server it still reports back and ends the caller's progress"] = function()
  vim.cmd("edit " .. env.multi .. "/apps/A/app/src/A_app.Codeunit.al")
  local lsp = require("nvim-al.lsp")
  local orig = lsp.client_for
  lsp.client_for = function()
    return nil
  end
  local p = require("nvim-al.feedback").progress("AL publish", "A", "building")
  local done
  require("nvim-al.build").build(0, function(ok)
    done = ok
  end, { progress = p })
  lsp.client_for = orig
  eq(done, false)
  eq(p.finished, true)
end

T["compile hook short-circuits"] = function()
  local got
  require("nvim-al").setup({
    extension_path = env.ext,
    hooks = {
      compile = function(ctx)
        got = ctx
        return true
      end,
    },
  })
  vim.cmd("edit " .. env.multi .. "/apps/A/app/src/A_app.Codeunit.al")
  require("nvim-al.build").compile(0)
  eq(#env.calls, 0)
  eq(got.ws.file, env.multi .. "/all.code-workspace")
  eq(got.folder.name, "A")
end

return T
