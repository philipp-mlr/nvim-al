local eq = MiniTest.expect.equality

local env

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["nvim-al.feedback"] = nil
      env = { echos = {} }
      env.orig_echo = vim.api.nvim_echo
      vim.api.nvim_echo = function(chunks, history, opts)
        table.insert(env.echos, {
          text = chunks[1] and chunks[1][1] or "",
          history = history,
          status = opts and opts.status,
          kind = opts and opts.kind,
          id = opts and opts.id,
          title = opts and opts.title,
        })
        return opts and opts.id or 7
      end
      env.now = 1000
      env.orig_now = vim.uv.now
      vim.uv.now = function()
        return env.now
      end
    end,
    post_case = function()
      vim.api.nvim_echo = env.orig_echo
      vim.uv.now = env.orig_now
    end,
  },
})

T["progress shows phase and elapsed time, updates in place"] = function()
  local fb = require("nvim-al.feedback")
  local p = fb.progress("AL publish", "Email", "building")
  env.now = env.now + 12000
  p:tick()
  p:phase("publishing to main-de")
  env.now = env.now + 19000
  p:finish(true, "published")
  local texts = vim.tbl_map(function(e)
    return e.text
  end, env.echos)
  eq(texts[1], "Email: building")
  eq(texts[2], "Email: building (12s)")
  eq(texts[3], "Email: publishing to main-de (12s)")
  eq(texts[#texts], "Email: published in 31s")
  eq(env.echos[#env.echos].status, "success")
  eq(env.echos[#env.echos].history, true)
  -- every update targets the same message id
  for i = 2, #env.echos do
    eq(env.echos[i].id, 7)
  end
end

T["detail lines are throttled and never contain compiler noise"] = function()
  local fb = require("nvim-al.feedback")
  local p = fb.progress("AL build", "Email", "compiling FO Base Application")
  local n = #env.echos
  for _ = 1, 50 do
    p:tick() -- same second: no new echo
  end
  eq(#env.echos, n)
end

T["failure keeps the phase and is marked failed"] = function()
  local fb = require("nvim-al.feedback")
  local p = fb.progress("AL publish", "Email", "publishing to main-de")
  env.now = env.now + 3000
  p:finish(false, "publish failed")
  eq(env.echos[#env.echos].text, "Email: publish failed after 3s")
  eq(env.echos[#env.echos].status, "failed")
end

T["reasons: server reason and error lines, generic lines dropped"] = function()
  local fb = require("nvim-al.feedback")
  local r = fb.reasons({
    "Publishing package to tenant 'default'",
    "The request for path /x failed with code UnprocessableEntity. Reason: Publishing failed due to 'Extension compilation failed",
    "error AL1024: A package with publisher 'FOND OF Solutions', name 'FO Telemetry' could not be loaded.",
    "src/A.al(3,14): error AL0791: The namespace 'AI' is unknown.",
    "Publish failed: Publish operation failed. Check the output for details.",
  })
  eq(r[1], "Extension compilation failed")
  eq(
    r[2],
    "error AL1024: A package with publisher 'FOND OF Solutions', name 'FO Telemetry' could not be loaded."
  )
  eq(#vim.tbl_filter(function(x)
    return x:find("Check the output", 1, true) ~= nil
  end, r), 0)
end

return T
