local jsonc = require("nvim-al.jsonc")
local eq = MiniTest.expect.equality
local T = MiniTest.new_set()

T["decodes BOM, comments and trailing commas"] = function()
  local text = "\239\187\191" -- UTF-8 BOM
    .. [[{
  // line comment
  "a": 1, /* block
  comment */
  "list": [1, 2, 3,],
  "obj": { "x": true, },
}]]
  local v, err = jsonc.decode(text)
  eq(err, nil)
  eq(v, { a = 1, list = { 1, 2, 3 }, obj = { x = true } })
end

T["keeps comment markers inside strings"] = function()
  local v =
    jsonc.decode([[{ "url": "http://x/y", "s": "a // b", "c": "/* no */", "q": "say \"//\"" }]])
  eq(v.url, "http://x/y")
  eq(v.s, "a // b")
  eq(v.c, "/* no */")
  eq(v.q, 'say "//"')
end

T["keeps commas followed by text inside strings"] = function()
  local v = jsonc.decode([[{ "s": ",]", "t": [ ",}" ] }]])
  eq(v.s, ",]")
  eq(v.t, { ",}" })
end

T["null becomes nil"] = function()
  local v = jsonc.decode([[{ "a": null, "b": [null, 1] }]])
  eq(v.a, nil)
end

T["invalid JSON returns nil and an error"] = function()
  local v, err = jsonc.decode("{ nope }")
  eq(v, nil)
  eq(type(err), "string")
end

T["read: missing file"] = function()
  local v, err = jsonc.read("/nonexistent/x.json")
  eq(v, nil)
  eq(err, "not found")
end

T["read: existing file"] = function()
  local p = vim.fn.tempname()
  vim.fn.writefile({ '{ "a": 1, }' }, p)
  eq(jsonc.read(p), { a = 1 })
end

return T
