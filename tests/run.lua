package.path = table.concat({
  "tests/?.lua",
  package.path,
}, ";")

require("test_helper")

local lu = require("luaunit")

dofile("tests/test_rules.lua")
dofile("tests/test_schedule.lua")
dofile("tests/test_service_integration.lua")
dofile("tests/test_view.lua")

os.exit(lu.LuaUnit.run())
