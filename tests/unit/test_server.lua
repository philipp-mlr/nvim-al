local eq = MiniTest.expect.equality

local env

-- A tiny HTTP server (python3 -m http.server is not flexible enough): answers
-- from a table of path -> {status, body}; records the Authorization header.
local function start_server(routes)
  local script = vim.fn.tempname() .. ".py"
  vim.fn.writefile({
    "import http.server, json, sys, os",
    "routes = json.load(open(sys.argv[1]))",
    "class H(http.server.BaseHTTPRequestHandler):",
    "    def do_GET(self):",
    "        open(sys.argv[2], 'a').write((self.headers.get('Authorization') or '') + ' ' + self.path + '\\n')",
    "        path = self.path.split('?')[0]",
    "        for p, r in routes.items():",
    "            if path == p:",
    "                self.send_response(r[0]); self.end_headers(); self.wfile.write(r[1].encode()); return",
    "        self.send_response(404); self.end_headers()",
    "    def log_message(self, *a): pass",
    "s = http.server.HTTPServer(('127.0.0.1', 0), H)",
    "print(s.server_address[1], flush=True)",
    "s.serve_forever()",
  }, script)
  local routes_file = vim.fn.tempname() .. ".json"
  vim.fn.writefile({ vim.json.encode(routes) }, routes_file)
  local log = vim.fn.tempname()
  local port
  local job = vim.fn.jobstart({ "python3", script, routes_file, log }, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not port and data[1] and data[1] ~= "" then
        port = tonumber(data[1])
      end
    end,
  })
  vim.wait(5000, function()
    return port ~= nil
  end, 20)
  return { job = job, port = port, log = log }
end

local function wait_cb(fn)
  local res
  fn(function(...)
    res = { ... }
  end)
  vim.wait(10000, function()
    return res ~= nil
  end, 20)
  return res
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["nvim-al.server"] = nil
      env = {}
    end,
    post_case = function()
      if env.srv then
        vim.fn.jobstop(env.srv.job)
      end
    end,
  },
})

local function target(port, over)
  return vim.tbl_extend("force", {
    name = "Local",
    server = "http://127.0.0.1",
    port = port,
    serverInstance = "main-de",
    tenant = "default",
    authentication = "UserPassword",
  }, over or {})
end

T["base_url combines server, port and instance"] = function()
  local s = require("nvim-al.server")
  eq(s.base_url(target(8880)), "http://127.0.0.1:8880/main-de")
  eq(
    s.base_url({ server = "http://localhost:7049/", port = 8880, serverInstance = "BC" }),
    "http://localhost:8880/BC"
  )
end

T["check: up, credentials sent via config, not argv"] = function()
  env.srv = start_server({ ["/main-de/dev/metadata"] = { 200, '{"runtimeVersion":"17.1"}' } })
  local r = wait_cb(function(cb)
    require("nvim-al.server").check(
      target(env.srv.port),
      { BC_SERVER_USERNAME = "admin", BC_SERVER_PASSWORD = 'p"w' },
      cb
    )
  end)
  eq(r[1], true)
  local log = table.concat(vim.fn.readfile(env.srv.log), "\n")
  eq(log:find("Basic ", 1, true) ~= nil, true)
  eq(log:find("tenant=default", 1, true) ~= nil, true)
end

T["check: wrong instance, rejected credentials, down"] = function()
  env.srv = start_server({ ["/main-de/dev/metadata"] = { 401, "" } })
  local s = require("nvim-al.server")
  local r = wait_cb(function(cb)
    s.check(target(env.srv.port, { serverInstance = "nope" }), {}, cb)
  end)
  eq(r[1], false)
  eq(r[2]:find("wrong serverInstance", 1, true) ~= nil, true)
  r = wait_cb(function(cb)
    s.check(target(env.srv.port), {}, cb)
  end)
  eq(r[2]:find("rejected the credentials", 1, true) ~= nil, true)
  vim.fn.jobstop(env.srv.job)
  vim.wait(300)
  r = wait_cb(function(cb)
    s.check(target(env.srv.port), {}, cb)
  end)
  eq(r[1], false)
  eq(r[2]:find("is not reachable", 1, true) ~= nil, true)
  env.srv = nil
end

T["installed: reads the automation API"] = function()
  env.srv = start_server({
    ["/main-de/api/v2.0/companies"] = { 200, '{"value":[{"id":"c1","name":"CRONUS DE"}]}' },
    ["/main-de/api/microsoft/automation/v2.0/companies(c1)/extensions"] = {
      200,
      vim.json.encode({
        value = {
          {
            displayName = "FO Telemetry",
            publisher = "FOND OF Solutions",
            versionMajor = 28,
            versionMinor = 0,
            versionBuild = 0,
            versionRevision = 0,
            isInstalled = true,
          },
          {
            displayName = "AI Library",
            publisher = "FOND OF Solutions",
            versionMajor = 27,
            versionMinor = 1,
            versionBuild = 0,
            versionRevision = 0,
            isInstalled = false,
          },
        },
      }),
    },
  })
  local r = wait_cb(function(cb)
    require("nvim-al.server").installed(target(env.srv.port), {}, cb)
  end)
  local apps = r[1]
  eq(
    apps["FOND OF Solutions|FO Telemetry"],
    { publisher = "FOND OF Solutions", version = "28.0.0.0", installed = true }
  )
  eq(apps["FOND OF Solutions|AI Library"].installed, false)
end

return T
