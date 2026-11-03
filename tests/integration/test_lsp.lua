-- Integration test against the real EditorServices host.
-- Needs NVIM_AL_TEST_EXTENSION (AL extension root) and NVIM_AL_TEST_PACKAGES
-- (a package cache with Microsoft symbols for platform/application 28).
local H = require("helpers")
local eq = MiniTest.expect.equality

local ext, pkgs = vim.env.NVIM_AL_TEST_EXTENSION, vim.env.NVIM_AL_TEST_PACKAGES
local T = MiniTest.new_set()
if not (ext and pkgs) then
  T["skipped (set NVIM_AL_TEST_EXTENSION and NVIM_AL_TEST_PACKAGES)"] = function()
    MiniTest.skip("integration environment not configured")
  end
  return T
end

local real -- fixture copy shared by the cases of this file

local function codes(path)
  local buf = vim.fn.bufadd(path)
  return vim.tbl_map(function(d)
    return d.code
  end, vim.diagnostic.get(buf))
end

local function wait_codes(path, code, ms)
  return vim.wait(ms or 90000, function()
    return vim.tbl_contains(codes(path), code)
  end, 200)
end

T = MiniTest.new_set({
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
  local client = require("nvim-al.lsp").client_for(vim.api.nvim_get_current_buf())
  local lsp = require("nvim-al.lsp")
  vim.wait(30000, function()
    return lsp.state(client.id).active == real .. "/test"
  end, 100)
  eq(lsp.state(client.id).active, real .. "/test")
  vim.wait(5000)
  eq(vim.tbl_contains(codes(mgt), "AA0137"), true)
  -- the test resolves app objects from source: no "does not exist" errors
  local errs = vim.tbl_filter(function(d)
    return d.severity == vim.diagnostic.severity.ERROR
  end, vim.diagnostic.get(vim.fn.bufadd(test)))
  eq(errs, {})
end

T["completion labels are strings"] = function()
  local test = real .. "/test/src/GadgetTest.Codeunit.al"
  vim.cmd("edit " .. test)
  local buf = vim.api.nvim_get_current_buf()
  local client = require("nvim-al.lsp").client_for(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local row
  for i, l in ipairs(lines) do
    if l:find('Gadget."No."', 1, true) then
      row = i - 1
    end
  end
  local col = lines[row + 1]:find("Gadget.", 1, true) + #"Gadget." - 1
  local res = client:request_sync("textDocument/completion", {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = row, character = col },
  }, 30000, buf)
  local items = res and res.result and (res.result.items or res.result) or {}
  eq(#items > 0, true)
  local labels = {}
  local tables = 0
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

return T
