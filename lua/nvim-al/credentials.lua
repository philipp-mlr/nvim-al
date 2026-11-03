-- UserPassword credentials: asked once per target for the session, kept in
-- memory only, handed to child processes as BC_SERVER_USERNAME/PASSWORD.
-- Never written to disk, never sent to the language server.
local M = {}

---@type table<string, {user: string, pass: string}>
local cache = {}

local function key(t)
  return table.concat({
    t.server or "",
    tostring(t.port or ""),
    t.serverInstance or "",
    t.tenant or "",
  }, "|")
end

--- Environment additions for a child process talking to `target`.
--- cb({}) when nothing is needed (Windows auth, or the variables are already
--- set), cb(nil) when the user cancels the prompt.
---@param target nvim_al.Target
---@param cb fun(env: table<string, string>|nil)
function M.env(target, cb)
  if target.authentication ~= "UserPassword" then
    return cb({})
  end
  if vim.env.BC_SERVER_USERNAME and vim.env.BC_SERVER_PASSWORD then
    return cb({})
  end
  local k = key(target)
  local c = cache[k]
  if c then
    return cb({ BC_SERVER_USERNAME = c.user, BC_SERVER_PASSWORD = c.pass })
  end
  vim.ui.input(
    { prompt = ("BC user (%s): "):format(target.serverInstance or target.name) },
    function(user)
      if not user or user == "" then
        return cb(nil)
      end
      local pass = vim.fn.inputsecret("Password: ")
      if pass == nil then
        return cb(nil)
      end
      cache[k] = { user = user, pass = pass }
      cb({ BC_SERVER_USERNAME = user, BC_SERVER_PASSWORD = pass })
    end
  )
end

--- Forget all cached credentials.
function M.clear()
  cache = {}
end

return M
