local H = require("helpers")
local eq = MiniTest.expect.equality

local env

local function wait_for(pred, ms)
  return vim.wait(ms or 5000, pred, 20)
end

local function read_log()
  local out = {}
  local f = io.open(env.log, "r")
  if not f then
    return out
  end
  for line in f:lines() do
    out[#out + 1] = vim.json.decode(line)
  end
  f:close()
  return out
end

-- The fake server reads FAKE_DEF at start-up, so each case sets it before
-- pre_case starts the server: cases are created by `case(mode, name, fn)`.
local next_mode = "file"

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      vim.env.FAKE_DEF = next_mode
      vim.g.loaded_nvim_al = nil
      vim.cmd("runtime plugin/nvim-al.lua")
      for _, mod in ipairs({ "nvim-al", "nvim-al.lsp", "nvim-al.workspace", "nvim-al.definition" }) do
        package.loaded[mod] = nil
      end
      env = { log = vim.fn.tempname(), notes = {} }
      vim.env.FAKE_LOG = env.log
      vim.env.FAKE_DELAY_MS = "10"
      env.orig_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(env.notes, { msg = msg, level = level })
      end
      require("nvim-al").setup({
        _host_cmd = { vim.v.progpath, "-l", H.root .. "/tests/fake_server.lua" },
      })
      env.multi = H.fixture("multi")
      vim.env.FAKE_DEF_TARGET = env.multi .. "/apps/A/test/src/A_test.Codeunit.al"
      vim.cmd("edit " .. env.multi .. "/apps/A/app/src/A_app.Codeunit.al")
      env.buf = vim.api.nvim_get_current_buf()
      env.client = require("nvim-al.lsp").attach(env.buf)
      wait_for(function()
        local st = require("nvim-al.lsp").state(env.client.id)
        return st and st.active ~= nil
      end)
    end,
    post_case = function()
      require("nvim-al.lsp").stop_all()
      wait_for(function()
        return #vim.lsp.get_clients({ name = "nvim-al", _uninitialized = true }) == 0
      end, 3000)
      vim.cmd("silent! %bwipeout!")
      vim.notify = env.orig_notify
    end,
  },
})

T["file location: jumps to the file and range"] = MiniTest.new_set({ hooks = { pre_once = function() next_mode = "file" end } })
T["file location: jumps to the file and range"]["case"] = function()
  require("nvim-al.definition").goto(env.buf)
  wait_for(function()
    return vim.api.nvim_buf_get_name(0) == vim.env.FAKE_DEF_TARGET
  end)
  eq(vim.api.nvim_buf_get_name(0), vim.env.FAKE_DEF_TARGET)
  eq(vim.api.nvim_win_get_cursor(0), { 3, 4 })
  -- the request body is wrapped as VS Code does
  local req
  for _, m in ipairs(read_log()) do
    if m.method == "al/gotodefinition" then
      req = m.params
    end
  end
  eq(req.browserInfo, { browser = "SystemDefault", incognito = false })
  eq(req.textDocumentPositionParams.textDocument.uri, vim.uri_from_bufnr(env.buf))
end

T["al-preview location: read-only al buffer without CR"] = MiniTest.new_set({ hooks = { pre_once = function() next_mode = "preview" end } })
T["al-preview location: read-only al buffer without CR"]["case"] = function()
  require("nvim-al.definition").goto(env.buf)
  local want = "al-preview://allang/Base Application/Table/18/Customer.al"
  wait_for(function()
    return vim.api.nvim_buf_get_name(0) == want
  end)
  local b = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.api.nvim_buf_line_count(b) > 1
  end)
  eq(vim.api.nvim_buf_get_name(b), want)
  eq(vim.bo[b].buftype, "nofile")
  eq(vim.bo[b].modifiable, false)
  eq(vim.bo[b].filetype, "al")
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  eq(lines[1], "table 18 Customer")
  eq(table.concat(lines, "\n"):find("\r", 1, true), nil)
  eq(vim.api.nvim_win_get_cursor(0), { 3, 4 })
  -- the preview buffer is attached to the same client
  eq(vim.lsp.get_clients({ bufnr = b, name = "nvim-al" })[1].id, env.client.id)
end

T[":edit al-preview:// works through BufReadCmd"] = MiniTest.new_set({ hooks = { pre_once = function() next_mode = "preview" end } })
T[":edit al-preview:// works through BufReadCmd"]["case"] = function()
  vim.cmd("edit al-preview://allang/X/Codeunit/1/Y.al")
  local b = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.api.nvim_buf_line_count(b) > 1
  end)
  eq(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], "table 18 Customer")
end

T[".dal location opens the .dal file next to the target"] = MiniTest.new_set({ hooks = { pre_once = function() next_mode = "dal" end } })
T[".dal location opens the .dal file next to the target"]["case"] = function()
  local dal = vim.fs.dirname(vim.env.FAKE_DEF_TARGET) .. "/Thing.dal"
  vim.fn.writefile({ "x", "y", "z", "    abcdefgh" }, dal)
  require("nvim-al.definition").goto(env.buf)
  wait_for(function()
    return vim.api.nvim_buf_get_name(0) == dal
  end)
  eq(vim.api.nvim_buf_get_name(0), dal)
end

T["no result: notify"] = MiniTest.new_set({ hooks = { pre_once = function() next_mode = "none" end } })
T["no result: notify"]["case"] = function()
  require("nvim-al.definition").goto(env.buf)
  wait_for(function()
    return #env.notes > 0
  end)
  eq(env.notes[#env.notes].msg, "No definition found")
end

T["gd is mapped buffer-locally on attach, tagfunc set"] = MiniTest.new_set({ hooks = { pre_once = function() next_mode = "file" end } })
T["gd is mapped buffer-locally on attach, tagfunc set"]["case"] = function()
  local map = vim.fn.maparg("gd", "n", false, true)
  eq(map.buffer, 1)
  eq(vim.bo[env.buf].tagfunc ~= "", true)
end

T["al-preview .dal location stays a preview"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      next_mode = "preview_dal"
    end,
  },
})
T["al-preview .dal location stays a preview"]["case"] = function()
  require("nvim-al.definition").goto(env.buf)
  local want = "al-preview://allang/app/Table/18/Customer.dal"
  wait_for(function()
    return vim.api.nvim_buf_get_name(0) == want
  end)
  eq(vim.api.nvim_buf_get_name(0), want)
  local b = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.api.nvim_buf_line_count(b) > 1
  end)
  eq(vim.bo[b].filetype, "al")
end

return T
