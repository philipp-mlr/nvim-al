-- Feedback for long-running work: a progress message that updates in place,
-- a log buffer per operation with the full output (:AL log), and the reason
-- when something fails.
local util = require("nvim-al.util")

local M = {}

local has_progress = vim.fn.has("nvim-0.12") == 1

---@class nvim_al.Progress
---@field title string message title, e.g. "AL publish"
---@field subject string what it is about, e.g. the project name
---@field phase_text string current phase, e.g. "building"
---@field started integer uv.now() at start
---@field shown_secs integer|nil elapsed seconds last shown
---@field id integer|string|nil message id
local Progress = {}
Progress.__index = Progress

---@type table<nvim_al.Progress, boolean> running operations (statusline, ticker)
local running = {}
local ticker

local function echo(p, msg, status, history, percent)
  if has_progress then
    local ok, id = pcall(vim.api.nvim_echo, { { msg } }, history, {
      id = p.id,
      kind = "progress",
      source = "nvim-al",
      title = p.title,
      status = status,
      percent = percent,
    })
    if ok then
      p.id = id
      return
    end
  end
  vim.api.nvim_echo({ { ("nvim-al: %s"):format(msg) } }, history, {})
end

local function elapsed(p)
  return math.floor((vim.uv.now() - p.started) / 1000)
end

function Progress:_render(percent)
  local secs = elapsed(self)
  self.shown_secs = secs
  local msg = ("%s: %s"):format(self.subject, self.phase_text)
  if secs > 0 then
    msg = msg .. (" (%ds)"):format(secs)
  end
  echo(self, msg, "running", false, percent)
  vim.api.nvim_exec_autocmds("User", { pattern = "NvimAlStatus", modeline = false })
end

local function ensure_ticker()
  if ticker then
    return
  end
  ticker = vim.uv.new_timer()
  ticker:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      for p in pairs(running) do
        p:tick()
      end
      if next(running) == nil and ticker then
        ticker:stop()
        ticker:close()
        ticker = nil
      end
    end)
  )
end

--- Start a progress message for an operation.
---@param title string e.g. "AL publish"
---@param subject string e.g. the project name
---@param phase? string first phase
---@return nvim_al.Progress
function M.progress(title, subject, phase)
  local p = setmetatable({
    title = title,
    subject = subject,
    phase_text = phase or "starting",
    started = vim.uv.now(),
    id = nil,
  }, Progress)
  running[p] = true
  p:_render()
  ensure_ticker()
  return p
end

--- Enter a new phase ("building", "publishing to main-de", "compiling FO Base Application").
---@param text string
---@param percent? integer
function Progress:phase(text, percent)
  if text == self.phase_text and percent == nil then
    return
  end
  self.phase_text = text
  self:_render(percent)
end

--- Refresh the elapsed time (at most once per second).
function Progress:tick()
  if elapsed(self) ~= self.shown_secs then
    self:_render()
  end
end

--- Compatibility: detail updates only change the phase text when given.
---@param msg string
---@param percent? integer
function Progress:update(msg, percent)
  self:phase(msg, percent)
end

--- Finish. The final message stays in :messages.
---@param ok boolean
---@param msg string e.g. "published", "publish failed"
function Progress:finish(ok, msg)
  running[self] = nil
  self.finished = true
  local secs = elapsed(self)
  local text = ("%s: %s"):format(self.subject, msg)
  if secs > 0 then
    text = text .. (ok and " in %ds" or " after %ds"):format(secs)
  end
  echo(self, text, ok and "success" or "failed", true, nil)
  vim.api.nvim_exec_autocmds("User", { pattern = "NvimAlStatus", modeline = false })
end

--- Operations currently running, for statuslines: { "Email: publishing to main-de (12s)" }.
---@return string[]
function M.running()
  local out = {}
  for p in pairs(running) do
    local secs = elapsed(p)
    out[#out + 1] = ("%s: %s%s"):format(
      p.subject,
      p.phase_text,
      secs > 0 and (" (%ds)"):format(secs) or ""
    )
  end
  table.sort(out)
  return out
end

---@type table<string, integer> operation -> log buffer
local logs = {}
M.last_op = nil

local function log_buf(op)
  local buf = logs[op]
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "nvim-al://" .. op)
    vim.bo[buf].bufhidden = "hide"
    logs[op] = buf
  end
  return buf
end

--- Replace the log of an operation.
---@param op string publish, build, compile, symbols, test
---@param lines string[]
---@return integer bufnr
function M.log(op, lines)
  local buf = log_buf(op)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  M.last_op = op
  return buf
end

--- Append one line to the log of an operation.
function M.append(op, line)
  local buf = log_buf(op)
  vim.bo[buf].modifiable = true
  local n = vim.api.nvim_buf_line_count(buf)
  local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  if n == 1 and first == "" then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { line })
  else
    vim.api.nvim_buf_set_lines(buf, n, n, false, { line })
  end
  vim.bo[buf].modifiable = false
end

--- Open the log of an operation (default: the most recent) in a split.
---@param op? string
function M.open(op)
  op = (op and op ~= "") and op or M.last_op
  local buf = op and logs[op]
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return util.notify("no output yet" .. (op and (" for " .. op) or ""), vim.log.levels.WARN)
  end
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.cmd("normal! G")
end

---@return string[] operations that have a log
function M.ops()
  local out = {}
  for op, buf in pairs(logs) do
    if vim.api.nvim_buf_is_valid(buf) then
      out[#out + 1] = op
    end
  end
  table.sort(out)
  return out
end

local GENERIC = { "Check the output for details", "See Visual Studio Code" }

local function generic(line)
  for _, g in ipairs(GENERIC) do
    if line:find(g, 1, true) then
      return true
    end
  end
  return false
end

--- The lines that explain a failure: server reasons, `error CODE:` lines,
--- `Error:` lines. altool's generic "check the output" lines are left out.
---@param lines string[]
---@return string[]
function M.reasons(lines)
  local out, seen = {}, {}
  for _, l in ipairs(lines) do
    local t = vim.trim(l)
    local hit = t:find("Reason:", 1, true)
      or t:match("error %u+%d+:")
      or t:match("^[Ee]rror:")
      or t:find("failed with code", 1, true)
    if hit and not generic(t) then
      local r = t:match("Reason:%s*(.*)$") or t
      r = r:gsub("^Publishing failed due to '", "")
        :gsub("'%. The original extensions have been restored%.$", "")
      if r ~= "" and not seen[r] then
        seen[r] = true
        out[#out + 1] = r
      end
    end
  end
  return out
end

--- Report a failure: progress marked failed, one ERROR notification with the
--- reason(s), a pointer to quickfix and to :AL log.
---@param p nvim_al.Progress|nil
---@param what string e.g. "publish of FO Base Application"
---@param lines string[] full output
---@param code integer exit code
---@param qf_count? integer issues put into quickfix
function M.fail(p, what, lines, code, qf_count)
  if p then
    p:finish(false, (what:match("^(%S+)") or what) .. " failed")
  end
  local reasons = M.reasons(lines)
  local head = reasons[1]
  if not head then
    for i = #lines, 1, -1 do
      local t = vim.trim(lines[i])
      if t ~= "" and not generic(t) then
        head = t
        break
      end
    end
  end
  local msg = { what .. " failed: " .. (head or ("exit code " .. tostring(code))) }
  for i = 2, math.min(4, #reasons) do
    msg[#msg + 1] = "  " .. reasons[i]
  end
  if #reasons > 4 then
    msg[#msg + 1] = ("  … %d more"):format(#reasons - 4)
  end
  local where = ":AL log for the full output"
  if qf_count and qf_count > 0 then
    where = ("%d issue(s) in quickfix, %s"):format(qf_count, where)
  end
  msg[#msg + 1] = where
  util.notify(table.concat(msg, "\n"), vim.log.levels.ERROR)
end

return M
