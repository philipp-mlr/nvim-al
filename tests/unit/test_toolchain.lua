local eq = MiniTest.expect.equality
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["nvim-al.toolchain"] = nil
    end,
  },
})

local HOST = "Microsoft.Dynamics.Nav.EditorServices.Host.dll"

--- Fake extension: <dir>/ms-dynamics-smb.al-<version>/{package.json, bin/...}
local function fake_ext(parent, version, opts)
  opts = opts or {}
  local dir = parent .. "/ms-dynamics-smb.al-" .. version
  vim.fn.mkdir(dir .. "/bin", "p")
  vim.fn.writefile(
    { ('{ "name": "al", "version": "%s" }'):format(version) },
    dir .. "/package.json"
  )
  if not opts.no_host then
    vim.fn.writefile({}, dir .. "/bin/" .. HOST)
  end
  vim.fn.writefile({}, dir .. "/bin/altool.dll")
  return dir
end

local function fake_home()
  local home = vim.fn.tempname()
  vim.fn.mkdir(home .. "/.vscode/extensions", "p")
  return home
end

local function with_home(home, fn)
  local orig = vim.env.HOME
  local orig_ext = vim.env.NVIM_AL_EXTENSION
  vim.env.HOME = home
  vim.env.NVIM_AL_EXTENSION = nil
  local ok, err = pcall(fn)
  vim.env.HOME = orig
  vim.env.NVIM_AL_EXTENSION = orig_ext
  if not ok then
    error(err, 0)
  end
end

T["picks the newest usable version"] = function()
  local home = fake_home()
  local ext = home .. "/.vscode/extensions"
  fake_ext(ext, "30.0.1")
  fake_ext(ext, "30.1.5")
  fake_ext(ext, "29.9.9")
  fake_ext(ext, "31.0.0", { no_host = true })
  with_home(home, function()
    local tc = require("nvim-al.toolchain")
    local found, err = tc.find_extension({})
    eq(err, nil)
    eq(found.version, "30.1.5")
    eq(found.path, ext .. "/ms-dynamics-smb.al-30.1.5")
    local skipped = tc.skipped()
    local reasons = {}
    for _, s in ipairs(skipped) do
      reasons[vim.fs.basename(s.path)] = s.reason
    end
    eq(reasons["ms-dynamics-smb.al-31.0.0"], "missing EditorServices host")
    eq(reasons["ms-dynamics-smb.al-29.9.9"], "version 29.9.9 is older than 30.0")
  end)
end

T["only old versions: error names the minimum"] = function()
  local home = fake_home()
  fake_ext(home .. "/.vscode/extensions", "29.0.0")
  with_home(home, function()
    local found, err = require("nvim-al.toolchain").find_extension({})
    eq(found, nil)
    eq(err:find(">= 30.0", 1, true) ~= nil, true)
  end)
end

T["extension_path may point at an unzipped vsix extension/ folder"] = function()
  local root = vim.fn.tempname()
  local dir = fake_ext(root, "30.0.2863738")
  local unzipped = root .. "/vsix/extension"
  vim.fn.mkdir(vim.fs.dirname(unzipped), "p")
  vim.fn.rename(dir, unzipped)
  with_home(fake_home(), function()
    local tc = require("nvim-al.toolchain")
    local found = tc.find_extension({ extension_path = root .. "/vsix" })
    eq(found.path, unzipped)
    eq(found.version, "30.0.2863738")
    eq(tc.find_extension({ extension_path = unzipped }).path, unzipped)
  end)
end

T["NVIM_AL_EXTENSION is used before the scan"] = function()
  local root = vim.fn.tempname()
  local dir = fake_ext(root, "30.0.9")
  local home = fake_home()
  fake_ext(home .. "/.vscode/extensions", "30.5.0")
  with_home(home, function()
    vim.env.NVIM_AL_EXTENSION = dir
    eq(require("nvim-al.toolchain").find_extension({}).path, dir)
  end)
end

T["host_cmd and altool_cmd"] = function()
  local root = vim.fn.tempname()
  local dir = fake_ext(root, "30.0.9")
  local tc = require("nvim-al.toolchain")
  local cfg = { extension_path = dir, dotnet = vim.v.progpath }
  local cmd = tc.host_cmd(cfg, { "/sessionId:x" })
  eq(cmd, { vim.v.progpath, dir .. "/bin/" .. HOST, "/sessionId:x" })
  eq(tc.altool_cmd(cfg, { "--version" })[2], dir .. "/bin/altool.dll")
  eq(tc.version(cfg), "30.0.9")
  eq(tc.analyzers_dir(cfg), dir .. "/bin/Analyzers")
end

T["dotnet missing"] = function()
  local tc = require("nvim-al.toolchain")
  local d, err = tc.dotnet({ dotnet = "/definitely/not/dotnet" })
  eq(d, nil)
  eq(err:find("dotnet", 1, true) ~= nil, true)
end

T["check_runtime needs both 10.x frameworks"] = function()
  local tc = require("nvim-al.toolchain")
  tc._list_runtimes = function()
    return "Microsoft.NETCore.App 10.0.12 [/x]\nMicrosoft.AspNetCore.App 8.0.1 [/x]\n"
  end
  local ok, err = tc.check_runtime({ dotnet = vim.v.progpath })
  eq(ok, false)
  eq(err, "needs Microsoft.AspNetCore.App 10.0")
  package.loaded["nvim-al.toolchain"] = nil
  tc = require("nvim-al.toolchain")
  tc._list_runtimes = function()
    return "Microsoft.AspNetCore.App 10.0.12 [/x]\nMicrosoft.NETCore.App 10.0.12 [/x]\n"
  end
  eq(tc.check_runtime({ dotnet = vim.v.progpath }), true)
end

return T
