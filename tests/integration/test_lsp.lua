-- Integration test against the real EditorServices host.
-- Needs NVIM_AL_TEST_EXTENSION (AL extension root) and NVIM_AL_TEST_PACKAGES
-- (a package cache with Microsoft symbols for platform/application 28).
local H = require("helpers")
local eq = MiniTest.expect.equality

local ext, pkgs = vim.env.NVIM_AL_TEST_EXTENSION, vim.env.NVIM_AL_TEST_PACKAGES
if not (ext and pkgs) then
  local T = MiniTest.new_set()
  T["skipped (set NVIM_AL_TEST_EXTENSION and NVIM_AL_TEST_PACKAGES)"] = function()
    MiniTest.skip("integration environment not configured")
  end
  return T
end

local real -- fixture copy shared by the cases of this file

local function codes(path)
  return vim.tbl_map(function(d)
    return d.code
  end, vim.diagnostic.get(vim.fn.bufadd(path)))
end

local function count_code(buf, code)
  local n = 0
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    if d.code == code then
      n = n + 1
    end
  end
  return n
end

local function wait_codes(path, code, ms)
  return vim.wait(ms or 90000, function()
    return vim.tbl_contains(codes(path), code)
  end, 200)
end

local function wait_active(folder)
  local lsp = require("nvim-al.lsp")
  local client = lsp.client_for(vim.api.nvim_get_current_buf())
  vim.wait(60000, function()
    local st = lsp.state(client.id)
    return st and st.active == folder
  end, 100)
  return client
end

local function cursor_on(pattern)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local c = l:find(pattern, 1, true)
    if c then
      vim.api.nvim_win_set_cursor(0, { i, c - 1 })
      return
    end
  end
  error("pattern not found: " .. pattern)
end

local T = MiniTest.new_set({
  hooks = {
    pre_once = function()
      real = H.fixture("real")
      for _, f in ipairs({ "app", "test" }) do
        vim.fn.mkdir(real .. "/" .. f .. "/.vscode", "p")
        vim.fn.writefile({
          vim.json.encode({ ["al.packageCachePath"] = { pkgs } }),
        }, real .. "/" .. f .. "/.vscode/settings.json")
      end
      vim.cmd("runtime plugin/nvim-al.lua")
      require("nvim-al").setup({ extension_path = ext })
    end,
    post_once = function()
      require("nvim-al.lsp").stop_all()
      vim.wait(3000, function()
        return #vim.lsp.get_clients({ name = "nvim-al", _uninitialized = true }) == 0
      end)
    end,
  },
})

T["diagnostics from the analyzer arrive for the active project"] = function()
  local mgt = real .. "/app/src/GadgetMgt.Codeunit.al"
  vim.cmd("edit " .. mgt)
  eq(wait_codes(mgt, "AA0137"), true)
end

T["switching to the test project keeps diagnostics of both"] = function()
  local mgt = real .. "/app/src/GadgetMgt.Codeunit.al"
  local test = real .. "/test/src/GadgetTest.Codeunit.al"
  vim.cmd("edit " .. test)
  wait_active(real .. "/test")
  eq(require("nvim-al.lsp").state(require("nvim-al.lsp").client_for(0).id).active, real .. "/test")
  vim.wait(5000)
  eq(vim.tbl_contains(codes(mgt), "AA0137"), true)
  -- the test resolves app objects from source: no errors
  local errs = vim.tbl_filter(function(d)
    return d.severity == vim.diagnostic.severity.ERROR
  end, vim.diagnostic.get(vim.fn.bufadd(test)))
  eq(errs, {})
end

T["completion labels are strings"] = function()
  vim.cmd("edit " .. real .. "/test/src/GadgetTest.Codeunit.al")
  local buf = vim.api.nvim_get_current_buf()
  local client = wait_active(real .. "/test")
  cursor_on('Gadget."No."')
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local col = vim.api.nvim_win_get_cursor(0)[2] + #"Gadget."
  local res = client:request_sync("textDocument/completion", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = row, character = col },
  }, 30000, buf)
  local items = res and res.result and (res.result.items or res.result) or {}
  eq(#items > 0, true)
  local labels, tables = {}, 0
  for _, it in ipairs(items) do
    if type(it.label) == "table" then
      tables = tables + 1
    else
      labels[it.label] = true
    end
  end
  eq(tables, 0)
  eq(labels["Description"], true)
end

T["gd from test into the app's table source"] = function()
  vim.cmd("edit " .. real .. "/test/src/GadgetTest.Codeunit.al")
  wait_active(real .. "/test")
  cursor_on('Record "Gadget"')
  vim.cmd("normal! 9l") -- onto Gadget inside the quotes
  require("nvim-al.definition").jump()
  local want = real .. "/app/src/Gadget.Table.al"
  vim.wait(30000, function()
    return vim.api.nvim_buf_get_name(0) == want
  end, 100)
  eq(vim.api.nvim_buf_get_name(0), want)
end

T["vim.lsp.buf.definition() works like gd (LspAttach mappings, pickers)"] = function()
  vim.cmd("edit " .. real .. "/test/src/GadgetTest.Codeunit.al")
  wait_active(real .. "/test")
  cursor_on('Record "Gadget"')
  vim.cmd("normal! 9l")
  vim.lsp.buf.definition()
  local want = real .. "/app/src/Gadget.Table.al"
  vim.wait(30000, function()
    return vim.api.nvim_buf_get_name(0) == want
  end, 100)
  eq(vim.api.nvim_buf_get_name(0), want)
end

T["gd into a symbol package opens a read-only preview"] = function()
  local mgt = real .. "/app/src/GadgetMgt.Codeunit.al"
  local lines = vim.fn.readfile(mgt)
  table.insert(lines, 6, "        Cust: Record Customer;")
  vim.fn.writefile(lines, mgt)
  vim.cmd("edit! " .. mgt)
  local buf = vim.api.nvim_get_current_buf()
  wait_active(real .. "/app")
  -- wait until the server has analysed the new line: its own "Cust is unused"
  -- diagnostic (not just any AA0137 left from earlier cases)
  vim.wait(90000, function()
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      if d.code == "AA0137" and d.message:find("'Cust'", 1, true) then
        return true
      end
    end
  end, 200)
  cursor_on("Record Customer")
  vim.cmd("normal! 9l")
  require("nvim-al.definition").jump()
  vim.wait(30000, function()
    return vim.api.nvim_buf_get_name(0):find("^al%-preview://") ~= nil
  end, 100)
  eq(vim.api.nvim_buf_get_name(0):find("^al%-preview://") ~= nil, true)
  local b = vim.api.nvim_get_current_buf()
  vim.wait(30000, function()
    return vim.api.nvim_buf_line_count(b) > 10
  end, 100)
  eq(vim.bo[b].modifiable, false)
  eq(vim.bo[b].filetype, "al")
  local text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
  eq(text:find("table 18 Customer", 1, true) ~= nil, true)
  eq(text:find("\r", 1, true), nil)
  vim.cmd("bwipeout!")
  table.remove(lines, 6)
  vim.fn.writefile(lines, mgt)
  vim.cmd("edit! " .. mgt)
end

T["code action applies the AA0137 suppression edit"] = function()
  local mgt = real .. "/app/src/GadgetMgt.Codeunit.al"
  vim.cmd("edit! " .. mgt)
  local buf = vim.api.nvim_get_current_buf()
  eq(wait_codes(mgt, "AA0137"), true)
  local d = vim.tbl_filter(function(x)
    return x.code == "AA0137"
  end, vim.diagnostic.get(buf))[1]
  vim.api.nvim_win_set_cursor(0, { d.lnum + 1, d.col })
  vim.lsp.buf.code_action({
    apply = true,
    filter = function(a)
      return a.title:find("AA0137", 1, true) ~= nil
    end,
  })
  local function text()
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  vim.wait(30000, function()
    return text():find("#pragma warning disable AA0137", 1, true) ~= nil
  end, 100)
  eq(text():find("#pragma warning disable AA0137", 1, true) ~= nil, true)
  vim.cmd("edit! " .. mgt)
end

return T
