local H = require("helpers")
local eq = MiniTest.expect.equality

local env -- per-case state

local function read_log()
  local out = {}
  local f = io.open(env.log, "r")
  if not f then
    return out
  end
  for line in f:lines() do
    -- the fake server may be mid-write: skip a partial last line
    local ok, v = pcall(vim.json.decode, line)
    if ok then
      out[#out + 1] = v
    end
  end
  f:close()
  return out
end

-- Protocol messages only: textDocument/* sync traffic is Neovim's own and may interleave.
local function methods(log)
  local out = {}
  for _, m in ipairs(log) do
    if not (m.method or ""):match("^textDocument/") then
      out[#out + 1] = m.method or "<response>"
    end
  end
  return out
end

local function clients()
  return vim.lsp.get_clients({ name = "nvim-al", _uninitialized = true })
end

local function count(log, method)
  local n = 0
  for _, m in ipairs(log) do
    if m.method == method then
      n = n + 1
    end
  end
  return n
end

local function wait_for(pred, ms)
  return vim.wait(ms or 5000, pred, 20)
end

local hooks = {
  pre_case = function()
    for _, mod in ipairs({ "nvim-al", "nvim-al.lsp", "nvim-al.workspace" }) do
      package.loaded[mod] = nil
    end
    env = { log = vim.fn.tempname(), notes = {} }
    vim.env.FAKE_LOG = env.log
    vim.env.FAKE_DELAY_MS = "200"
    vim.env.FAKE_EXIT_CODE = nil
    vim.env.FAKE_ASK_LOADED = nil
    local util = require("nvim-al.util")
    env.orig_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(env.notes, { msg = msg, level = level })
    end
    require("nvim-al").setup({
      _host_cmd = { vim.v.progpath, "-l", H.root .. "/tests/fake_server.lua" },
    })
    env.util = util
  end,
  post_case = function()
    for _, c in ipairs(vim.lsp.get_clients({ name = "nvim-al", _uninitialized = true })) do
      c:stop(true)
    end
    wait_for(function()
      return #vim.lsp.get_clients({ name = "nvim-al", _uninitialized = true }) == 0
    end, 3000)
    vim.cmd("silent! %bwipeout!")
    vim.notify = env.orig_notify
  end,
}
local T = MiniTest.new_set({ hooks = hooks })

local function open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local buf = vim.api.nvim_get_current_buf()
  return require("nvim-al.lsp").attach(buf), buf
end

local function settle(n_set_active)
  wait_for(function()
    return count(read_log(), "al/setActiveWorkspace") >= n_set_active
  end)
  -- let the delayed response and any queued switch go through
  vim.wait(400)
end

T["startup sequence"] = function()
  local multi = H.fixture("multi")
  local client = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  eq(client ~= nil, true)
  settle(1)
  local log = vim.tbl_filter(function(m)
    return not (m.method or ""):match("^textDocument/")
  end, read_log())
  eq(vim.list_slice(methods(log), 1, 6), {
    "initialize",
    "initialized",
    "al/loadManifest",
    "al/loadManifest",
    "al/loadManifest",
    "al/setActiveWorkspace",
  })
  local sw = log[6].params
  eq(sw.currentWorkspaceFolderPath.name, "A")
  eq(sw.currentWorkspaceFolderPath.index, 0)
  eq(sw.currentWorkspaceFolderPath.uri, vim.uri_from_fname(multi .. "/apps/A/app"))
  eq(sw.settings.workspacePath, multi .. "/apps/A/app")
  eq(sw.settings.setActiveWorkspace, true)
  local init = log[1].params
  eq(#init.workspaceFolders, 3)
  eq(init.rootPath, multi .. "/apps/A/app")
  local st = require("nvim-al.lsp").state(client.id)
  eq(st.active, multi .. "/apps/A/app")
end

T["switching to another project sends active + dependency configuration"] = function()
  local multi = H.fixture("multi")
  open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  open(multi .. "/apps/B/app/src/B_app.Codeunit.al")
  settle(2)
  local log = read_log()
  local sets, dcc = {}, {}
  for _, m in ipairs(log) do
    if m.method == "al/setActiveWorkspace" then
      sets[#sets + 1] = m.params
    elseif m.method == "workspace/didChangeConfiguration" then
      dcc[#dcc + 1] = m.params
    end
  end
  eq(#sets, 2)
  eq(sets[2].settings.workspacePath, multi .. "/apps/B/app")
  eq(sets[2].settings.activeWorkspaceClosure, { multi .. "/apps/B/app", multi .. "/apps/A/app" })
  eq(#dcc, 1)
  eq(dcc[1].settings.workspacePath, multi .. "/apps/A/app")
  eq(dcc[1].settings.setActiveWorkspace, false)
  eq(dcc[1].settings.dependencyParentWorkspacePath, multi .. "/apps/B/app")
end

T["transitive dependencies are configured with their referencing parent"] = function()
  local multi = H.fixture("multi")
  -- chain: A - Test -> B -> A
  vim.fn.writefile({
    vim.json.encode({
      id = "aaaaaaaa-0000-0000-0000-000000000002",
      name = "A Test",
      publisher = "Fixture",
      version = "1.0.0.0",
      platform = "28.0.0.0",
      dependencies = {
        {
          id = "bbbbbbbb-0000-0000-0000-000000000001",
          name = "B",
          publisher = "Fixture",
          version = "2.0.0.0",
        },
      },
    }),
  }, multi .. "/apps/A/test/app.json")
  open(multi .. "/apps/A/test/src/A_test.Codeunit.al")
  settle(1)
  local dcc = {}
  for _, m in ipairs(read_log()) do
    if m.method == "workspace/didChangeConfiguration" then
      dcc[#dcc + 1] = {
        path = m.params.settings.workspacePath,
        parent = m.params.settings.dependencyParentWorkspacePath,
      }
    end
  end
  eq(dcc, {
    { path = multi .. "/apps/B/app", parent = multi .. "/apps/A/test" },
    { path = multi .. "/apps/A/app", parent = multi .. "/apps/B/app" },
  })
end

T["same folder does not re-send"] = function()
  local multi = H.fixture("multi")
  local client = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  require("nvim-al.lsp").switch(client, require("nvim-al.lsp").state(client.id).ws.folders[1])
  vim.wait(400)
  eq(count(read_log(), "al/setActiveWorkspace"), 1)
end

T["rapid switching coalesces, last folder wins"] = function()
  local multi = H.fixture("multi")
  local lsp = require("nvim-al.lsp")
  local client = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  local ws = lsp.state(client.id).ws
  local A, B = ws.folders[1], ws.folders[3]
  for _, f in ipairs({ A, B, A, B, A, B, A }) do
    lsp.switch(client, f)
  end
  vim.wait(1200)
  local sets = vim.tbl_filter(function(m)
    return m.method == "al/setActiveWorkspace"
  end, read_log())
  -- the first (startup) plus at most 2 more
  eq(#sets <= 3, true)
  eq(lsp.state(client.id).active, A.path)
end

T["two fixture copies get two clients"] = function()
  local a, b = H.fixture("multi"), H.fixture("multi")
  local ca = open(a .. "/apps/A/app/src/A_app.Codeunit.al")
  local cb = open(b .. "/apps/A/app/src/A_app.Codeunit.al")
  eq(ca.id ~= cb.id, true)
  eq(#clients(), 2)
end

T["server crash: one error, no restart"] = function()
  vim.env.FAKE_EXIT_CODE = "3"
  local multi = H.fixture("multi")
  open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  wait_for(function()
    return #clients() == 0
  end)
  vim.wait(300)
  eq(#clients(), 0)
  -- Neovim itself also warns "Client nvim-al quit with exit code 3" (WARN, not suppressible);
  -- nvim-al adds exactly one ERROR with the way out.
  local errors = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR and n.msg:find("code 3", 1, true) ~= nil
  end, env.notes)
  eq(#errors, 1)
  eq(errors[1].msg, "nvim-al: language server exited with code 3; :AL restart to try again")
end

T["al/activeProjectLoaded is answered with null"] = function()
  vim.env.FAKE_ASK_LOADED = "1"
  local multi = H.fixture("multi")
  local client = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  local resp
  wait_for(function()
    for _, m in ipairs(read_log()) do
      if m.id == 1001 and m.method == nil then
        resp = m
        return true
      end
    end
  end)
  eq(resp ~= nil, true)
  eq(resp.result, vim.NIL)
  eq(require("nvim-al.lsp").state(client.id).loaded, true)
end

T["file without app.json: no client, one notice"] = function()
  local loose = H.fixture("loose")
  local c1 = open(loose .. "/x.al")
  local c2 = require("nvim-al.lsp").attach(vim.api.nvim_get_current_buf())
  eq(c1, nil)
  eq(c2, nil)
  eq(#clients(), 0)
  local hits = vim.tbl_filter(function(n)
    return n.msg == "nvim-al: no app.json found for " .. loose .. "/x.al"
  end, env.notes)
  eq(#hits, 1)
end

T["completion item labels are flattened to strings"] = function()
  local multi = H.fixture("multi")
  local client, buf = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  local res = client:request_sync("textDocument/completion", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 0, character = 0 },
  }, 5000, buf)
  local items = res.result.items
  eq(items[1].label, '"No." (PK1)')
  eq(items[2].label, "Description")
  local got
  client:request("textDocument/completion", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = 0, character = 0 },
  }, function(_, result)
    got = result
  end, buf)
  wait_for(function()
    return got ~= nil
  end)
  eq(got.items[1].label, '"No." (PK1)')
end

T["missing dotnet: no error raised, one scheduled error notice"] = function()
  require("nvim-al").setup({ dotnet = "/nonexistent/dotnet" })
  local multi = H.fixture("multi")
  local ok, err = pcall(open, multi .. "/apps/A/app/src/A_app.Codeunit.al")
  eq(ok, true, err)
  vim.wait(200)
  local errs = vim.tbl_filter(function(n)
    return n.level == vim.log.levels.ERROR and n.msg:find("dotnet", 1, true) ~= nil
  end, env.notes)
  eq(#errs, 1)
  eq(#clients(), 0)
end

T["fix: crashed server is not respawned on the next AL buffer"] = function()
  vim.env.FAKE_EXIT_CODE = "3"
  local multi = H.fixture("multi")
  open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  wait_for(function()
    return #clients() == 0
  end)
  vim.wait(300)
  local inits = count(read_log(), "initialize")
  open(multi .. "/apps/B/app/src/B_app.Codeunit.al")
  vim.wait(500)
  eq(count(read_log(), "initialize"), inits)
  eq(#clients(), 0)
  -- :AL restart starts it again
  vim.env.FAKE_EXIT_CODE = nil
  require("nvim-al.lsp").restart_buffer(vim.api.nvim_get_current_buf())
  wait_for(function()
    return count(read_log(), "initialize") > inits
  end)
  eq(count(read_log(), "initialize") > inits, true)
end

T["fix: :AL restart starts a fresh client and activates the folder"] = function()
  local multi = H.fixture("multi")
  local client = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  local old = client.id
  require("nvim-al.lsp").restart(client.config._nvim_al_key)
  local fresh
  wait_for(function()
    fresh = vim.lsp.get_clients({ name = "nvim-al" })[1]
    local st = fresh and require("nvim-al.lsp").state(fresh.id)
    return fresh and fresh.id ~= old and st and st.active ~= nil
  end, 8000)
  eq(fresh ~= nil and fresh.id ~= old, true)
  eq(require("nvim-al.lsp").state(fresh.id).active, multi .. "/apps/A/app")
end

T["fix: slow initialize (>2 s) still activates the first folder"] = function()
  require("nvim-al").setup({
    _host_cmd = { vim.v.progpath, "-l", H.root .. "/tests/fake_server.lua" },
  })
  vim.env.FAKE_INIT_DELAY_MS = "2500"
  local multi = H.fixture("multi")
  local client = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  vim.env.FAKE_INIT_DELAY_MS = nil
  wait_for(function()
    local st = require("nvim-al.lsp").state(client.id)
    return st and st.active ~= nil
  end, 8000)
  eq(require("nvim-al.lsp").state(client.id).active, multi .. "/apps/A/app")
end

T["fix: entering a buffer of a running workspace does not look up the toolchain"] = function()
  local multi = H.fixture("multi")
  open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  local tc = require("nvim-al.toolchain")
  local orig = tc.find_extension
  local calls = 0
  tc.find_extension = function(...)
    calls = calls + 1
    return orig(...)
  end
  -- drop the test override: without the fix, start() would now run the toolchain lookup
  require("nvim-al").config()._host_cmd = nil
  open(multi .. "/apps/B/app/src/B_app.Codeunit.al")
  tc.find_extension = orig
  eq(calls, 0)
end

T["fix: a non-AL app.json does not start the server"] = function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir .. "/.git", "p")
  vim.fn.writefile({ '{ "expo": { "name": "my-app", "slug": "my-app" } }' }, dir .. "/app.json")
  vim.g.loaded_nvim_al = nil
  vim.cmd("runtime plugin/nvim-al.lua")
  vim.cmd("edit " .. dir .. "/app.json")
  vim.wait(300)
  eq(#clients(), 0)
  -- an AL app.json does
  local multi = H.fixture("multi")
  vim.cmd("edit " .. multi .. "/apps/A/app/app.json")
  wait_for(function()
    return #clients() == 1
  end)
  eq(#clients(), 1)
end

T["fix: switching re-sends the open buffers of the new active folder"] = function()
  local multi = H.fixture("multi")
  open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  open(multi .. "/apps/B/app/src/B_app.Codeunit.al")
  settle(2)
  local before = 0
  for _, m in ipairs(read_log()) do
    if
      m.method == "textDocument/didChange" and m.params.textDocument.uri:find("A_app", 1, true)
    then
      before = before + 1
    end
  end
  open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(3)
  local after, full = 0, false
  for _, m in ipairs(read_log()) do
    if
      m.method == "textDocument/didChange" and m.params.textDocument.uri:find("A_app", 1, true)
    then
      after = after + 1
      full = m.params.contentChanges[1].range == nil
        and m.params.contentChanges[1].text:find("codeunit", 1, true) ~= nil
    end
  end
  eq(after, before + 1)
  eq(full, true)
end

T["minor: folders added to the saved workspace file are loaded"] = function()
  local multi = H.fixture("multi")
  local ws_file = multi .. "/all.code-workspace"
  vim.g.loaded_nvim_al = nil
  vim.cmd("runtime plugin/nvim-al.lua")
  -- start with only A/app and B/app
  vim.fn.writefile(
    { '{ "folders": [ { "path": "apps/A/app", "name": "A" }, { "path": "apps/B/app" } ] }' },
    ws_file
  )
  open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  eq(count(read_log(), "al/loadManifest"), 2)
  -- add A/test and save the workspace file in Neovim
  vim.cmd("edit " .. ws_file)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    '{ "folders": [ { "path": "apps/A/app", "name": "A" }, { "path": "apps/B/app" }, { "path": "apps/A/test", "name": "A - Test" } ] }',
  })
  vim.cmd("write")
  wait_for(function()
    return count(read_log(), "al/loadManifest") >= 3
  end)
  eq(count(read_log(), "al/loadManifest"), 3)
  local added
  for _, m in ipairs(read_log()) do
    if m.method == "al/didChangeWorkspaceFolders" then
      added = m.params
    end
  end
  eq(added ~= nil, true)
  eq(#added.added, 1)
  eq(added.added[1].name, "A - Test")
  eq(#added.removed, 0)
  -- the new folder is usable: a buffer in it activates it
  open(multi .. "/apps/A/test/src/A_test.Codeunit.al")
  settle(3)
  local last
  for _, m in ipairs(read_log()) do
    if m.method == "al/setActiveWorkspace" then
      last = m.params
    end
  end
  eq(last.settings.workspacePath, multi .. "/apps/A/test")
end

T["publishDiagnostics with a bare path (no URI scheme) does not raise"] = function()
  vim.env.FAKE_BARE_URI = "1"
  local errs = {}
  local orig = vim.schedule
  vim.schedule = function(fn)
    return orig(function()
      local ok, e = pcall(fn)
      if not ok then
        table.insert(errs, e)
      end
    end)
  end
  local multi = H.fixture("multi")
  open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  vim.wait(300)
  vim.schedule = orig
  vim.env.FAKE_BARE_URI = nil
  eq(errs, {})
end

T["workspace loading shows as a progress message and in status()"] = function()
  vim.env.FAKE_LOAD_PROGRESS = "1"
  local echos = {}
  local orig = vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks, history, opts)
    if opts and opts.kind == "progress" then
      table.insert(echos, { text = chunks[1][1], status = opts.status })
    end
    return orig(chunks, history, opts)
  end
  local multi = H.fixture("multi")
  local _, buf = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  settle(1)
  vim.wait(300)
  vim.api.nvim_echo = orig
  vim.env.FAKE_LOAD_PROGRESS = nil
  local texts = vim.tbl_map(function(e)
    return e.text
  end, echos)
  eq(vim.tbl_contains(texts, "A: loading project 'A'"), true)
  eq(echos[#echos].status, "success")
  local s = require("nvim-al").status(buf)
  eq(s.loaded, true)
  eq(require("nvim-al").statusline(buf):find("AL A", 1, true) ~= nil, true)
end

T["workspace reload during a build is shown as a build phase, not a second message"] = function()
  vim.env.FAKE_LOAD_PROGRESS = "1"
  vim.env.FAKE_DELAY_MS = "300"
  local multi = H.fixture("multi")
  local client = open(multi .. "/apps/A/app/src/A_app.Codeunit.al")
  local fb = require("nvim-al.feedback")
  local p = fb.progress("AL build", "A", "building")
  require("nvim-al.build")._active = { client_id = client.id, progress = p, lines = {} }
  local titles = {}
  local orig = vim.api.nvim_echo
  vim.api.nvim_echo = function(chunks, history, opts)
    if opts and opts.kind == "progress" then
      table.insert(titles, (opts.title or "") .. "|" .. chunks[1][1])
    end
    return orig(chunks, history, opts)
  end
  settle(1)
  vim.wait(300)
  vim.api.nvim_echo = orig
  vim.env.FAKE_LOAD_PROGRESS = nil
  require("nvim-al.build")._active = nil
  eq(vim.tbl_contains(titles, "AL build|A: loading project 'A'"), true)
  for _, t in ipairs(titles) do
    eq(t:match("^AL|") == nil, true)
  end
end

T["status reports workspace and folder"] = function()
  local multi = H.fixture("multi")
  local _, buf = open(multi .. "/apps/A/test/src/A_test.Codeunit.al")
  settle(1)
  local s = require("nvim-al").status(buf)
  eq(s.workspace, multi .. "/all.code-workspace")
  eq(s.folder, multi .. "/apps/A/test")
  eq(s.building, false)
end

return T
