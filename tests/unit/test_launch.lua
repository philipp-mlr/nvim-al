local H = require("helpers")
local eq = MiniTest.expect.equality

local env

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for _, m in ipairs({ "nvim-al", "nvim-al.launch", "nvim-al.credentials", "nvim-al.workspace" }) do
        package.loaded[m] = nil
      end
      env = { notes = {}, selects = 0 }
      env.orig_notify, env.orig_select = vim.notify, vim.ui.select
      vim.notify = function(msg, level)
        table.insert(env.notes, { msg = msg, level = level })
      end
      vim.ui.select = function(items, opts, cb)
        env.selects = env.selects + 1
        cb(items[env.pick or 1], env.pick or 1)
      end
      require("nvim-al").setup({})
      env.multi = H.fixture("multi")
      local ws =
        require("nvim-al.workspace").resolve(env.multi .. "/apps/B/app/src/B_app.Codeunit.al")
      env.ws = ws
      for _, f in ipairs(ws.folders) do
        if f.path:find("/B/app", 1, true) then
          env.B = f
        elseif f.name == "A" then
          env.A = f
        end
      end
    end,
    post_case = function()
      vim.notify, vim.ui.select = env.orig_notify, env.orig_select
    end,
  },
})

local function cfg()
  return require("nvim-al").config()
end

T["configurations: only type al, folder launch.json first"] = function()
  local launch = require("nvim-al.launch")
  local list = launch.configurations(env.ws, env.B, cfg())
  eq(#list, 2)
  eq(list[1].name, "Attach local")
  eq(list[2].name, "Cloud sandbox")
end

T["configurations: workspace file launch section follows"] = function()
  env.ws.launch =
    { configurations = { { name = "From workspace", type = "al", request = "attach" } } }
  local list = require("nvim-al.launch").configurations(env.ws, env.B, cfg())
  eq(#list, 3)
  eq(list[3].name, "From workspace")
end

T["configurations: launch hook replaces files"] = function()
  require("nvim-al").setup({
    hooks = {
      launch = function(folder)
        return { { name = "hooked " .. folder.name, type = "al", request = "attach" } }
      end,
    },
  })
  local list = require("nvim-al.launch").configurations(env.ws, env.B, cfg())
  eq(#list, 1)
  eq(list[1].name, "hooked app")
end

T["resolve: unsupported authentication"] = function()
  local launch = require("nvim-al.launch")
  local raw = launch.configurations(env.ws, env.B, cfg())[2]
  local t, err = launch.resolve(raw, env.ws, env.B)
  eq(t, nil)
  eq(err, "nvim-al: authentication 'AAD' is not supported in v1 (UserPassword, Windows)")
end

T["resolve: attach defaults and breakOnError split"] = function()
  local launch = require("nvim-al.launch")
  local raw = launch.configurations(env.ws, env.B, cfg())[1]
  local t = launch.resolve(raw, env.ws, env.B)
  eq(t.name, "Attach local")
  eq(t.request, "attach")
  eq(t.port, 7049)
  eq(t.server, "http://localhost")
  eq(t.serverInstance, "BC")
  eq(t.authentication, "UserPassword")
  local r = t.raw
  eq(r.port, 7049)
  eq(r.breakOnNext, "WebServiceClient")
  eq(r.sessionId, -1)
  eq(r.breakOnError, true)
  eq(r.breakOnErrorBehaviour, "ExcludeTry")
  eq(r.breakOnRecordWrite, false)
  eq(r.usePublicURLFromServer, true)
  eq(r.validateServerCertificate, true)
  eq(r.useMcpServerForDebugging, false)
  eq(r.isResolved, true)
  eq(r.projectReferenceDefinitions, nil)
end

T["resolve: Agent maps to ClientService; launch adds project references"] = function()
  local launch = require("nvim-al.launch")
  local t = launch.resolve({
    name = "a",
    type = "al",
    request = "attach",
    authentication = "Windows",
    breakOnNext = "Agent",
    breakOnError = false,
  }, env.ws, env.B)
  eq(t.raw.breakOnNext, "ClientService")
  eq(t.raw.breakOnError, false)
  eq(t.raw.breakOnErrorBehaviour, nil)
  local l = launch.resolve({
    name = "l",
    type = "al",
    request = "launch",
    authentication = "UserPassword",
    port = 8880,
  }, env.ws, env.B)
  eq(l.port, 8880)
  eq(l.raw.projectReferenceDefinitions, {
    {
      appId = "aaaaaaaa-0000-0000-0000-000000000001",
      name = "A",
      publisher = "Fixture",
      version = "1.0.0.0",
    },
  })
end

T["altool_flags omits unset fields"] = function()
  local launch = require("nvim-al.launch")
  local t = launch.resolve(launch.configurations(env.ws, env.B, cfg())[1], env.ws, env.B)
  eq(launch.altool_flags(t), {
    "--server",
    "http://localhost",
    "--port",
    "7049",
    "--serverinstance",
    "BC",
    "--tenant",
    "default",
    "--authentication",
    "UserPassword",
    "--environmenttype",
    "Sandbox",
  })
end

T["target: picks once, remembers per folder, forget re-asks"] = function()
  local launch = require("nvim-al.launch")
  env.ws.launch = {
    configurations = {
      { name = "Second", type = "al", request = "attach", authentication = "Windows" },
    },
  }
  env.pick = 2 -- the AAD one is dropped, so the list is {Attach local, Second}
  local got
  launch.target(env.ws, env.B, cfg(), function(t)
    got = t
  end)
  eq(got.name, "Second")
  eq(env.selects, 1)
  launch.target(env.ws, env.B, cfg(), function(t)
    got = t
  end)
  eq(got.name, "Second")
  eq(env.selects, 1)
  launch.forget(env.B.path)
  env.pick = 1
  launch.target(env.ws, env.B, cfg(), function(t)
    got = t
  end)
  eq(got.name, "Attach local")
  eq(env.selects, 2)
end

T["target: single usable configuration needs no picker; none notifies"] = function()
  local launch = require("nvim-al.launch")
  local got
  launch.target(env.ws, env.B, cfg(), function(t)
    got = t
  end)
  eq(got.name, "Attach local")
  eq(env.selects, 0)
  local none = "unset"
  launch.target(env.ws, env.A, cfg(), function(t)
    none = t
  end)
  eq(none, nil)
  eq(env.notes[#env.notes].msg, "nvim-al: no AL launch configuration for A")
end

return T
