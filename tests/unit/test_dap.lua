local H = require("helpers")
local eq = MiniTest.expect.equality

local env

--- Minimal stand-in for nvim-dap: records what nvim-al registers.
local function stub_dap()
  local dap = {
    adapters = {},
    providers = { configs = {} },
    listeners = { after = {}, before = {}, on_config = {}, on_session = {} },
    _sessions = {},
  }
  dap.continue = function() end
  setmetatable(dap.listeners.after, {
    __index = function(t, k)
      rawset(t, k, {})
      return rawget(t, k)
    end,
  })
  setmetatable(dap.listeners.before, getmetatable(dap.listeners.after))
  function dap.sessions()
    return dap._sessions
  end
  function dap.session()
    return nil
  end
  return dap
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      for _, m in ipairs({
        "nvim-al",
        "nvim-al.dap",
        "nvim-al.launch",
        "nvim-al.credentials",
        "nvim-al.workspace",
      }) do
        package.loaded[m] = nil
      end
      env = { notes = {}, opened = {} }
      env.dap = stub_dap()
      package.loaded["dap"] = env.dap
      env.orig_notify, env.orig_open, env.orig_input, env.orig_secret =
        vim.notify, vim.ui.open, vim.ui.input, vim.fn.inputsecret
      env.orig_user, env.orig_pass = vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD
      vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD = nil, nil
      vim.notify = function(msg, level)
        table.insert(env.notes, { msg = msg, level = level })
      end
      vim.ui.open = function(uri)
        table.insert(env.opened, uri)
      end
      vim.ui.input = function(_, cb)
        cb("ADMIN")
      end
      vim.fn.inputsecret = function()
        return "pw"
      end
      env.ext = vim.fn.tempname()
      vim.fn.mkdir(env.ext .. "/bin", "p")
      vim.fn.writefile({ '{ "version": "30.0.1" }' }, env.ext .. "/package.json")
      vim.fn.writefile({}, env.ext .. "/bin/Microsoft.Dynamics.Nav.EditorServices.Host.dll")
      require("nvim-al").setup({ extension_path = env.ext, dotnet = vim.v.progpath })
      env.multi = H.fixture("multi")
      vim.cmd("edit " .. env.multi .. "/apps/B/app/src/B_app.Codeunit.al")
      require("nvim-al.dap").setup()
    end,
    post_case = function()
      package.loaded["dap"] = nil
      vim.notify, vim.ui.open, vim.ui.input, vim.fn.inputsecret =
        env.orig_notify, env.orig_open, env.orig_input, env.orig_secret
      vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD = env.orig_user, env.orig_pass
      vim.cmd("silent! %bwipeout!")
    end,
  },
})

T["provider lists resolved configurations and drops unsupported ones"] = function()
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  eq(#configs, 1)
  eq(configs[1].name, "Attach local")
  eq(configs[1].type, "al")
  eq(configs[1].isResolved, true)
  eq(configs[1].__nvim_al_folder, env.multi .. "/apps/B/app")
  local warn = vim.tbl_filter(function(n)
    return n.msg:find("'AAD' is not supported", 1, true) ~= nil
  end, env.notes)
  eq(#warn, 1)
end

T["adapter: executable in the project folder with credentials in env"] = function()
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  local got
  env.dap.adapters.al(function(a)
    got = a
  end, configs[1])
  eq(got.type, "executable")
  eq(got.command, vim.v.progpath)
  eq(got.args, {
    env.ext .. "/bin/Microsoft.Dynamics.Nav.EditorServices.Host.dll",
    "/startDebugging",
    "/disableTelemetry",
    "/projectRoot:" .. env.multi .. "/apps/B/app",
  })
  eq(got.options.cwd, env.multi .. "/apps/B/app")
  -- nvim-dap passes options.env to uv.spawn as is: it must be a "KEY=VALUE" list
  eq(vim.islist(got.options.env), true)
  eq(vim.tbl_contains(got.options.env, "BC_SERVER_USERNAME=ADMIN"), true)
  eq(vim.tbl_contains(got.options.env, "BC_SERVER_PASSWORD=pw"), true)
  eq(vim.tbl_contains(got.options.env, "PATH=" .. vim.env.PATH), true)
end

T["adapter: configuration from nvim-dap's own launch.json loader is resolved"] = function()
  local raw = { type = "al", request = "attach", name = "plain", authentication = "Windows" }
  local cfg = raw
  for _, fn in pairs(env.dap.listeners.on_config) do
    cfg = fn(cfg)
  end
  eq(cfg.isResolved, true)
  eq(cfg.breakOnNext, "WebServiceClient")
  eq(cfg.__nvim_al_folder, env.multi .. "/apps/B/app")
  -- other adapters are left alone
  local other = { type = "python", request = "launch", name = "py" }
  for _, fn in pairs(env.dap.listeners.on_config) do
    other = fn(other)
  end
  eq(other.isResolved, nil)
end

T["AL events: openUri opens, deviceLogin notifies and opens"] = function()
  local ev = env.dap.listeners.after
  local open_uri = ev["event_al/openUri"]["nvim-al"]
  local device = ev["event_al/deviceLogin"]["nvim-al"]
  open_uri({}, { uri = "http://bc/?page=22" })
  device(
    {},
    { message = "Enter code ABC", token = "ABC", uri = "https://microsoft.com/devicelogin" }
  )
  eq(env.opened, { "http://bc/?page=22", "https://microsoft.com/devicelogin" })
  eq(
    vim.tbl_contains(
      vim.tbl_map(function(n)
        return n.msg
      end, env.notes),
      "nvim-al: Enter code ABC"
    ),
    true
  )
end

T["nothing suppresses nvim-dap's breakpoint re-send on initialized"] = function()
  eq(rawget(env.dap.listeners.before, "event_initialized"), nil)
  local after = rawget(env.dap.listeners.after, "event_initialized") or {}
  eq(after["nvim-al"], nil)
end

T["responses without command get it back from the matching request"] = function()
  -- The AL adapter answers e.g. `attach` with no `command` field; nvim-dap routes
  -- response listeners by command and fails with "table index is nil".
  local session = {
    handle_body = function(self, body)
      self.got = vim.json.decode(body)
    end,
    request = function() end,
  }
  local fix = require("nvim-al.dap")._fix_responses
  fix(session)
  session.seq = 2
  session:request("attach", {})
  session:handle_body(vim.json.encode({ type = "response", request_seq = 2, success = true }))
  eq(session.got.command, "attach")
  -- untouched when present or not a response
  session:handle_body(
    vim.json.encode({ type = "response", request_seq = 3, command = "next", success = true })
  )
  eq(session.got.command, "next")
  session:handle_body(vim.json.encode({ type = "event", event = "output", body = {} }))
  eq(session.got.command, nil)
  -- a request sent before the wrapper existed: recovered from nvim-dap's pending args
  session.message_requests = { [1] = { request = "attach", name = "x" } }
  session:handle_body(vim.json.encode({ type = "response", request_seq = 1, success = true }))
  eq(session.got.command, "attach")
  -- the real adapter sends "command": null, not a missing field
  session:handle_body(
    '{"type":"response","request_seq":1,"command":null,"success":true,"body":null}'
  )
  eq(session.got.command, "attach")
end

T["setup is idempotent"] = function()
  local a = env.dap.adapters.al
  require("nvim-al.dap").setup()
  eq(env.dap.adapters.al == a, true)
end

return T
