#!/usr/bin/lua

local function add_package_path()
  local script_name = (arg and arg[0]) or ""
  local script_dir = script_name:match("^(.*)[/\\][^/\\]+$") or "."
  package.path = table.concat({
    script_dir .. "/focuslib/?.lua",
    script_dir .. "/focuslib/?/init.lua",
    "/usr/lib/lua/?.lua",
    "/usr/lib/lua/?/init.lua",
    package.path,
  }, ";")
end

add_package_path()

local app = require("focuslib.app")
os.exit(app.run_cli(arg or {}))
