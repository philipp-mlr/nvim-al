local eq = MiniTest.expect.equality

local env

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["nvim-al.credentials"] = nil
      env = { inputs = 0, secrets = 0 }
      env.orig_input, env.orig_secret = vim.ui.input, vim.fn.inputsecret
      env.orig_user, env.orig_pass = vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD
      vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD = nil, nil
      vim.ui.input = function(_, cb)
        env.inputs = env.inputs + 1
        cb(env.user)
      end
      vim.fn.inputsecret = function()
        env.secrets = env.secrets + 1
        return env.pass or ""
      end
    end,
    post_case = function()
      vim.ui.input, vim.fn.inputsecret = env.orig_input, env.orig_secret
      vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD = env.orig_user, env.orig_pass
    end,
  },
})

local function target(over)
  return vim.tbl_extend("force", {
    name = "t",
    server = "http://localhost",
    port = 7049,
    serverInstance = "BC",
    tenant = "default",
    authentication = "UserPassword",
  }, over or {})
end

local function get(t)
  local out = "unset"
  require("nvim-al.credentials").env(t, function(e)
    out = e
  end)
  return out
end

T["Windows needs nothing"] = function()
  eq(get(target({ authentication = "Windows" })), {})
  eq(env.inputs, 0)
end

T["environment variables set: inherit, no prompt"] = function()
  vim.env.BC_SERVER_USERNAME, vim.env.BC_SERVER_PASSWORD = "admin", "secret"
  eq(get(target()), {})
  eq(env.inputs, 0)
end

T["prompts once per target, then reuses"] = function()
  env.user, env.pass = "ADMIN", "pw"
  eq(get(target()), { BC_SERVER_USERNAME = "ADMIN", BC_SERVER_PASSWORD = "pw" })
  eq(get(target()), { BC_SERVER_USERNAME = "ADMIN", BC_SERVER_PASSWORD = "pw" })
  eq(env.inputs, 1)
  eq(env.secrets, 1)
  -- another instance prompts again
  env.user, env.pass = "OTHER", "pw2"
  eq(get(target({ serverInstance = "BC2" })).BC_SERVER_USERNAME, "OTHER")
  eq(env.inputs, 2)
end

T["cancel returns nil and caches nothing"] = function()
  env.user = nil
  eq(get(target()), nil)
  env.user, env.pass = "ADMIN", "pw"
  eq(get(target()).BC_SERVER_USERNAME, "ADMIN")
  eq(env.inputs, 2)
end

T["clear forgets cached credentials"] = function()
  env.user, env.pass = "ADMIN", "pw"
  get(target())
  require("nvim-al.credentials").clear()
  get(target())
  eq(env.inputs, 2)
end

return T
