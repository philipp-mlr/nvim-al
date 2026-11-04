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

T["file location: jumps to the file and range"] =
  MiniTest.new_set({ hooks = {
    pre_once = function()
      next_mode = "file"
    end,
  } })
T["file location: jumps to the file and range"]["case"] = function()
  require("nvim-al.definition").jump(env.buf)
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

T["al-preview location: read-only al buffer without CR"] =
  MiniTest.new_set({ hooks = {
    pre_once = function()
      next_mode = "preview"
    end,
  } })
T["al-preview location: read-only al buffer without CR"]["case"] = function()
  require("nvim-al.definition").jump(env.buf)
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

T[":edit al-preview:// works through BufReadCmd"] =
  MiniTest.new_set({ hooks = {
    pre_once = function()
      next_mode = "preview"
    end,
  } })
T[":edit al-preview:// works through BufReadCmd"]["case"] = function()
  vim.cmd("edit al-preview://allang/X/Codeunit/1/Y.al")
  local b = vim.api.nvim_get_current_buf()
  wait_for(function()
    return vim.api.nvim_buf_line_count(b) > 1
  end)
  eq(vim.api.nvim_buf_get_lines(b, 0, 1, false)[1], "table 18 Customer")
end

T[".dal location opens the .dal file next to the target"] =
  MiniTest.new_set({ hooks = {
    pre_once = function()
      next_mode = "dal"
    end,
  } })
T[".dal location opens the .dal file next to the target"]["case"] = function()
  local dal = vim.fs.dirname(vim.env.FAKE_DEF_TARGET) .. "/Thing.dal"
  vim.fn.writefile({ "x", "y", "z", "    abcdefgh" }, dal)
  require("nvim-al.definition").jump(env.buf)
  wait_for(function()
    return vim.api.nvim_buf_get_name(0) == dal
  end)
  eq(vim.api.nvim_buf_get_name(0), dal)
end

T["no result: notify"] =
  MiniTest.new_set({ hooks = {
    pre_once = function()
      next_mode = "none"
    end,
  } })
T["no result: notify"]["case"] = function()
  require("nvim-al.definition").jump(env.buf)
  wait_for(function()
    return #env.notes > 0
  end)
  eq(env.notes[#env.notes].msg, "No definition found")
end

T["gd is mapped buffer-locally on attach, tagfunc set"] =
  MiniTest.new_set({ hooks = {
    pre_once = function()
      next_mode = "file"
    end,
  } })
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
  require("nvim-al.definition").jump(env.buf)
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

T["fix: textDocument/definition is routed to al/gotodefinition"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      next_mode = "file"
    end,
  },
})
T["fix: textDocument/definition is routed to al/gotodefinition"]["case"] = function()
  eq(env.client.server_capabilities.definitionProvider, true)
  local res = env.client:request_sync(
    "textDocument/definition",
    vim.lsp.util.make_position_params(0, "utf-16"),
    5000,
    env.buf
  )
  eq(res.result.uri, vim.uri_from_fname(vim.env.FAKE_DEF_TARGET))
  -- vim.lsp.buf.definition() (what LspAttach gd mappings and pickers call) jumps
  vim.lsp.buf.definition()
  wait_for(function()
    return vim.api.nvim_buf_get_name(0) == vim.env.FAKE_DEF_TARGET
  end)
  eq(vim.api.nvim_buf_get_name(0), vim.env.FAKE_DEF_TARGET)
end

T["textDocument/declaration goes to the definition (AL has no separate declaration)"] =
  MiniTest.new_set({
    hooks = {
      pre_once = function()
        next_mode = "file"
      end,
    },
  })
T["textDocument/declaration goes to the definition (AL has no separate declaration)"]["case"] = function()
  eq(env.client.server_capabilities.declarationProvider, true)
  local res = env.client:request_sync(
    "textDocument/declaration",
    vim.lsp.util.make_position_params(0, "utf-16"),
    5000,
    env.buf
  )
  eq(res.result.uri, vim.uri_from_fname(vim.env.FAKE_DEF_TARGET))
  local sent = vim.tbl_filter(function(m)
    return m.method == "al/gotodefinition"
  end, read_log())
  eq(#sent, 1)
  vim.lsp.buf.declaration()
  wait_for(function()
    return vim.api.nvim_buf_get_name(0) == vim.env.FAKE_DEF_TARGET
  end)
  eq(vim.api.nvim_buf_get_name(0), vim.env.FAKE_DEF_TARGET)
end

T["fix: vim.lsp.buf.definition opens al-preview results"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      next_mode = "preview"
    end,
  },
})
T["fix: vim.lsp.buf.definition opens al-preview results"]["case"] = function()
  local errs = {}
  local orig_err = vim.api.nvim_err_writeln
  local orig_sched = vim.schedule
  vim.schedule = function(fn)
    orig_sched(function()
      local ok, e = pcall(fn)
      if not ok then
        table.insert(errs, e)
      end
    end)
  end
  vim.lsp.buf.definition()
  local want = "al-preview://allang/Base Application/Table/18/Customer.al"
  wait_for(function()
    return vim.api.nvim_buf_get_name(0) == want and vim.api.nvim_buf_line_count(0) > 1
  end)
  vim.wait(300)
  vim.schedule = orig_sched
  eq(errs, {})
  eq(vim.api.nvim_buf_get_name(0), want)
  eq(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1], "table 18 Customer")
  eq(vim.api.nvim_win_get_cursor(0), { 3, 4 })
end

T["fix: a user gd mapping is kept"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      next_mode = "file"
    end,
  },
})
T["fix: a user gd mapping is kept"]["case"] = function()
  vim.keymap.set("n", "gd", "<cmd>echo 'mine'<cr>")
  vim.cmd("edit " .. env.multi .. "/apps/B/app/src/B_app.Codeunit.al")
  local b = vim.api.nvim_get_current_buf()
  require("nvim-al.lsp").attach(b)
  vim.wait(500)
  local m = vim.fn.maparg("gd", "n", false, true)
  vim.keymap.del("n", "gd")
  eq(m.buffer, 0)
  eq(m.rhs, "<cmd>echo 'mine'<cr>")
end

T["minor: <C-]> jumps synchronously and pushes the tag stack"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      next_mode = "file"
    end,
  },
})
T["minor: <C-]> jumps synchronously and pushes the tag stack"]["case"] = function()
  vim.api.nvim_win_set_cursor(0, { 1, 10 })
  local ok, err = pcall(vim.cmd, "normal! \29") -- <C-]>
  eq(ok, true, err)
  eq(vim.api.nvim_buf_get_name(0), vim.env.FAKE_DEF_TARGET)
  eq(vim.api.nvim_win_get_cursor(0), { 3, 4 })
  local stack = vim.fn.gettagstack()
  eq(stack.length >= 1, true)
  vim.cmd("pop")
  eq(vim.api.nvim_get_current_buf(), env.buf)
end

T["minor: tagfunc for previews returns a tag into the preview buffer"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      next_mode = "preview"
    end,
  },
})
T["minor: tagfunc for previews returns a tag into the preview buffer"]["case"] = function()
  local tags = require("nvim-al.definition").tagfunc("x", "c")
  eq(type(tags), "table")
  eq(#tags, 1)
  eq(tags[1].filename, "al-preview://allang/Base Application/Table/18/Customer.al")
  eq(tags[1].cmd, "call cursor(3, 5)")
end

T["minor: a preview is loaded from the client that returned it"] = MiniTest.new_set({
  hooks = {
    pre_once = function()
      next_mode = "preview"
    end,
  },
})
T["minor: a preview is loaded from the client that returned it"]["case"] = function()
  -- a second workspace (another worktree) with its own client, started first in the list
  local other = H.fixture("multi")
  vim.cmd("edit " .. other .. "/apps/A/app/src/A_app.Codeunit.al")
  local c2 = require("nvim-al.lsp").attach(vim.api.nvim_get_current_buf())
  vim.wait(3000, function()
    local st = require("nvim-al.lsp").state(c2.id)
    return st and st.active ~= nil
  end, 20)
  vim.cmd("buffer " .. env.buf)
  require("nvim-al.definition").jump(env.buf)
  local want = "al-preview://allang/Base Application/Table/18/Customer.al"
  vim.wait(5000, function()
    return vim.api.nvim_buf_get_name(0) == want and vim.api.nvim_buf_line_count(0) > 1
  end, 20)
  local b = vim.api.nvim_get_current_buf()
  eq(vim.b[b].nvim_al_client, env.client.id)
  eq(vim.lsp.buf_is_attached(b, env.client.id), true)
  eq(vim.lsp.buf_is_attached(b, c2.id), false)
end

return T
