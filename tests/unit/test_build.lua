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
