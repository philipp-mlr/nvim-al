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
        "nvim-al.server",
        "nvim-al.feedback",
        "nvim-al.build",
      }) do
        package.loaded[m] = nil
      end
      env = { notes = {}, opened = {}, echos = {} }
      env.health = { true, "up" }
      require("nvim-al.server").check = function(_, _, cb)
        cb(env.health[1], env.health[2])
      end
      env.orig_echo = vim.api.nvim_echo
      vim.api.nvim_echo = function(chunks, history, opts)
        if opts and opts.kind == "progress" and opts.title == "AL debug" then
          table.insert(env.echos, { text = chunks[1][1], status = opts.status })
        end
        return env.orig_echo(chunks, history, opts)
      end
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
      vim.api.nvim_echo = env.orig_echo
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
  -- .NET startup takes longer than nvim-dap's 4s default: no false "didn't respond"
  eq(got.options.initialize_timeout_sec >= 30, true)
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

T["fix: single-session guard runs in the adapter, ignores other envs, async select"] = function()
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  local cfg = configs[1]
  -- no other session: no prompt, adapter starts
  local prompts, got = 0, nil
  local orig = vim.ui.select
  vim.ui.select = function(items, _, cb)
    prompts = prompts + 1
    vim.schedule(function()
      cb(env.choice)
    end)
  end
  env.dap.adapters.al(function(a)
    got = a
  end, cfg)
  eq(prompts, 0)
  eq(got ~= nil, true)
  -- a running session for another environment: still no prompt
  local closed = false
  env.dap._sessions = {
    [1] = {
      config = vim.tbl_extend("force", cfg, { serverInstance = "OTHER" }),
      close = function()
        closed = true
      end,
    },
  }
  got = nil
  env.dap.adapters.al(function(a)
    got = a
  end, cfg)
  eq(prompts, 0)
  eq(got ~= nil, true)
  -- same environment: async prompt; cancel -> adapter not started
  env.dap._sessions = {
    [1] = {
      config = vim.deepcopy(cfg),
      close = function()
        closed = true
      end,
    },
  }
  env.choice = "Cancel"
  got = nil
  env.dap.adapters.al(function(a)
    got = a
  end, cfg)
  vim.wait(200)
  eq(prompts, 1)
  eq(got, nil)
  eq(closed, false)
  -- stop the other -> it is closed and the adapter starts
  env.choice = "Stop the other session"
  env.dap.adapters.al(function(a)
    got = a
  end, cfg)
  vim.wait(200)
  eq(closed, true)
  eq(got ~= nil, true)
  vim.ui.select = orig
  -- no before.launch/attach listeners (they run on the response, not before)
  eq(rawget(env.dap.listeners.before, "launch") and env.dap.listeners.before.launch["nvim-al"], nil)
end

T["minor: kill_adapters finds AL debug adapters among Neovim's children"] = function()
  -- a fake adapter: a child process whose command line looks like the real one
  -- argv carries the same markers as `dotnet …EditorServices.Host.dll /startDebugging`
  local job = vim.fn.jobstart({
    "sh",
    "-c",
    "sleep 30; true", -- two commands: sh stays the process, with its argv
    "/x/Microsoft.Dynamics.Nav.EditorServices.Host.dll",
    "/startDebugging",
  })
  local other = vim.fn.jobstart({ "sleep", "30" })
  vim.wait(300)
  local pid = vim.fn.jobpid(job)
  local found = require("nvim-al.dap")._adapter_pids()
  eq(vim.tbl_contains(found, pid), true)
  eq(vim.tbl_contains(found, vim.fn.jobpid(other)), false)
  require("nvim-al.dap").kill_adapters()
  -- jobwait returns -3 for a job id that already ended and was cleaned up
  local exited = vim.fn.jobwait({ job }, 3000)[1]
  eq(exited ~= -1, true)
  pcall(vim.fn.jobstop, other)
end

local function fire(kind, name, ...)
  local l = env.dap.listeners[kind][name]["nvim-al"]
  assert(l, kind .. "." .. name .. " listener missing")
  l(...)
end

T["debug feedback: unreachable target stops before the adapter starts"] = function()
  env.health = { false, "http://localhost:8880/BC is not reachable (connection refused)" }
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  local got
  env.dap.adapters.al(function(a)
    got = a
  end, configs[1])
  eq(got, nil)
  local errs = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR
  end, env.notes)
  eq(#errs, 1)
  eq(errs[1].msg:find("not reachable", 1, true) ~= nil, true)
  eq(env.echos[#env.echos].status, "failed")
end

T["debug feedback: connecting, then attached and waiting"] = function()
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  env.dap.adapters.al(function() end, configs[1])
  eq(env.echos[1].status, "running")
  eq(env.echos[#env.echos].text:find("connecting to", 1, true) ~= nil, true)
  local session = { config = configs[1] }
  fire("after", "attach", session, nil, { success = true })
  local last = env.echos[#env.echos]
  eq(last.status, "success")
  eq(last.text:find("attached to", 1, true) ~= nil, true)
  eq(last.text:find("waiting", 1, true) ~= nil, true)
end

T["debug feedback: a rejected attach fails with the server's reason"] = function()
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  env.dap.adapters.al(function() end, configs[1])
  local session = { config = configs[1] }
  fire("after", "attach", session, { message = "The app 'B' is not published on the server" }, nil)
  local last = env.echos[#env.echos]
  eq(last.status, "failed")
  local errs = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR
  end, env.notes)
  eq(errs[#errs].msg:find("not published", 1, true) ~= nil, true)
  eq(errs[#errs].msg:find(":AL publish", 1, true) ~= nil, true)
end

T["debug feedback: a failed launch shows the adapter's output, named after the app"] = function()
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  local cfg = vim.tbl_extend("force", configs[1], { request = "launch" })
  require("nvim-al.build").build = function(_, on_done)
    on_done(true, {})
  end
  env.dap.adapters.al(function() end, cfg)
  eq(env.echos[1].text:find("^B app:") ~= nil or env.echos[1].text:find("^B:") ~= nil, true)
  local session = { config = cfg }
  fire(
    "after",
    "event_output",
    session,
    { category = "console", output = "Publishing package to server\n" }
  )
  fire("after", "event_output", session, {
    category = "stderr",
    output = "error: The extension 'B' could not be deployed: dependency 'X' is not installed.\n",
  })
  fire("after", "launch", session, {
    message = "Could not publish the package to the server. See Visual Studio Code debug console for more details.",
  }, nil)
  local errs = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR
  end, env.notes)
  local msg = errs[#errs].msg
  eq(msg:find("dependency 'X' is not installed", 1, true) ~= nil, true)
  eq(msg:find("Visual Studio Code", 1, true), nil)
  eq(msg:find(":AL log debug", 1, true) ~= nil, true)
  eq(
    vim.api.nvim_buf_get_lines(vim.fn.bufnr("nvim-al://debug"), 0, -1, false)[1],
    "Publishing package to server"
  )
end

T["launch builds first (fresh package id), attach does not; a failed build stops"] = function()
  local build = require("nvim-al.build")
  local built = {}
  env.build_ok = true
  build.build = function(_, on_done, opts)
    table.insert(built, opts and opts.folder and opts.folder.path)
    on_done(env.build_ok, {})
  end
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  local got
  env.dap.adapters.al(function(a)
    got = a
  end, configs[1])
  eq(built, {})
  eq(got ~= nil, true)
  local launch = vim.tbl_extend("force", configs[1], { request = "launch" })
  got = nil
  env.dap.adapters.al(function(a)
    got = a
  end, launch)
  eq(built, { env.multi .. "/apps/B/app" })
  eq(got ~= nil, true)
  env.build_ok = false
  got = nil
  env.dap.adapters.al(function(a)
    got = a
  end, launch)
  eq(got, nil)
  eq(env.echos[#env.echos].status, "failed")
end

T["debug feedback: adapter exits before attaching"] = function()
  local configs = env.dap.providers.configs["nvim-al"](vim.api.nvim_get_current_buf())
  env.dap.adapters.al(function() end, configs[1])
  fire("after", "event_terminated", { config = configs[1] }, {})
  eq(env.echos[#env.echos].status, "failed")
end

T["setup is idempotent"] = function()
  local a = env.dap.adapters.al
  require("nvim-al.dap").setup()
  eq(env.dap.adapters.al == a, true)
end

return T
