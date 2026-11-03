-- Shared test helpers.
local H = {}

H.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

--- Copy a fixture repository to a fresh temp dir and turn `dot-git` back into `.git`
--- (git cannot commit a nested .git). Returns the copy's absolute path.
---@param name string fixture directory under tests/fixtures
---@return string
function H.fixture(name)
  local dst = vim.fn.tempname() .. "-" .. name
  vim.fn.mkdir(vim.fs.dirname(dst), "p")
  vim.fn.system({ "cp", "-r", H.root .. "/tests/fixtures/" .. name, dst })
  for _, p in ipairs(vim.fn.globpath(dst, "**/dot-git", true, true)) do
    vim.fn.rename(p, vim.fs.dirname(p) .. "/.git")
  end
  local top = dst .. "/dot-git"
  if vim.uv.fs_stat(top) then
    vim.fn.rename(top, dst .. "/.git")
  end
  return vim.fs.normalize(vim.uv.fs_realpath(dst))
end

return H
