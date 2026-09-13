local helper = require("test_helper")
local lu = require("luaunit")
local dns = require("quietwrt.dns")

TestDns = {}

function TestDns:test_readiness_checks_server_and_noresolv()
  local context = {
    env = {
      capture = function(cmd)
        if cmd == "uci -q get dhcp.@dnsmasq[0].server" then
          return "127.0.0.1#3053"
        elseif cmd == "uci -q get dhcp.@dnsmasq[0].noresolv" then
          return "1"
        end
        return ""
      end,
    },
  }

  lu.assertFalse(dns.is_ready(context))
  local err = dns.readiness_error(context)
  lu.assertStrContains(err, "forwarding queries to AdGuard Home")

  context.env.capture = function(cmd)
    if cmd == "uci -q get dhcp.@dnsmasq[0].server" then
      return ""
    elseif cmd == "uci -q get dhcp.@dnsmasq[0].noresolv" then
      return "0"
    end
    return ""
  end

  lu.assertTrue(dns.is_ready(context))
  lu.assertNil(dns.readiness_error(context))
end

function TestDns:test_apply_unfiltered_dnsmasq_runs_commands_and_restarts_dnsmasq()
  local state = {
    server = "127.0.0.1#3053",
    noresolv = "1",
  }
  local executed = {}

  local context = {
    paths = {
      restart_dnsmasq_command = "restart-dnsmasq",
    },
    env = {
      capture = function(cmd)
        if cmd == "uci -q get dhcp.@dnsmasq[0].server" then
          return state.server
        elseif cmd == "uci -q get dhcp.@dnsmasq[0].noresolv" then
          return state.noresolv
        end
        return ""
      end,
      execute = function(cmd)
        table.insert(executed, cmd)
        if cmd:find("uci -q delete dhcp.@dnsmasq[0].server", 1, true) then
          state.server = ""
        elseif cmd:find("uci set dhcp.@dnsmasq[0].noresolv='0'", 1, true) then
          state.noresolv = "0"
        end
        return 0
      end,
    },
  }

  local ok, err, changed = dns.apply_unfiltered_dnsmasq(context)
  lu.assertTrue(ok)
  lu.assertNil(err)
  lu.assertTrue(changed)
  lu.assertTrue(dns.is_ready(context))
  lu.assertStrContains(table.concat(executed, "\n"), "restart-dnsmasq")

  -- Running again when already ready does nothing and reports changed = false
  executed = {}
  local ok2, err2, changed2 = dns.apply_unfiltered_dnsmasq(context)
  lu.assertTrue(ok2)
  lu.assertNil(err2)
  lu.assertFalse(changed2)
  lu.assertEquals(#executed, 0)
end

function TestDns:test_capture_and_restore_snapshot()
  local state = {
    server = "",
    noresolv = "0",
  }
  local executed = {}

  local context = {
    paths = {
      restart_dnsmasq_command = "restart-dnsmasq",
    },
    env = {
      capture = function(cmd)
        if cmd == "uci -q get dhcp.@dnsmasq[0].server" then
          return state.server
        elseif cmd == "uci -q get dhcp.@dnsmasq[0].noresolv" then
          return state.noresolv
        end
        return ""
      end,
      execute = function(cmd)
        table.insert(executed, cmd)
        if cmd:find("uci -q delete dhcp.@dnsmasq[0].server", 1, true) then
          state.server = ""
        else
          local server = cmd:match("^uci add_list dhcp%.@dnsmasq%[0%]%.server='([^']+)'$")
          if server then
            state.server = state.server == "" and server or (state.server .. " " .. server)
          end
        end
        local noresolv = cmd:match("^uci set dhcp%.@dnsmasq%[0%]%.noresolv='([^']+)'$")
        if noresolv then
          state.noresolv = noresolv
        end
        return 0
      end,
    },
  }

  local snapshot = {
    server = "127.0.0.1#3053",
    noresolv = "1",
  }

  local ok, err = dns.restore_snapshot(context, snapshot)
  lu.assertTrue(ok)
  lu.assertNil(err)

  local command_log = table.concat(executed, "\n")
  lu.assertStrContains(command_log, "uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#3053'")
  lu.assertStrContains(command_log, "uci set dhcp.@dnsmasq[0].noresolv='1'")
  lu.assertStrContains(command_log, "restart-dnsmasq")
  lu.assertEquals(state, snapshot)
end

function TestDns:test_apply_restores_snapshot_when_restart_fails()
  local state = {
    server = "127.0.0.1#3053 9.9.9.9",
    noresolv = "1",
  }
  local restart_attempts = 0

  local context = {
    paths = { restart_dnsmasq_command = "restart-dnsmasq" },
    env = {
      capture = function(cmd)
        if cmd:find(".server", 1, true) then
          return state.server
        end
        if cmd:find(".noresolv", 1, true) then
          return state.noresolv
        end
        return ""
      end,
      execute = function(cmd)
        if cmd:find("delete dhcp.@dnsmasq[0].server", 1, true) then
          state.server = ""
        else
          local server = cmd:match("^uci add_list dhcp%.@dnsmasq%[0%]%.server='([^']+)'$")
          if server then
            state.server = state.server == "" and server or (state.server .. " " .. server)
          end
        end
        local noresolv = cmd:match("^uci set dhcp%.@dnsmasq%[0%]%.noresolv='([^']+)'$")
        if noresolv then
          state.noresolv = noresolv
        end
        if cmd == "restart-dnsmasq" then
          restart_attempts = restart_attempts + 1
          if restart_attempts == 1 then
            return 1
          end
        end
        return 0
      end,
    },
  }

  local ok, err, changed = dns.apply_unfiltered_dnsmasq(context)
  lu.assertFalse(ok)
  lu.assertFalse(changed)
  lu.assertStrContains(err, "previous dnsmasq state was restored")
  lu.assertEquals(state.server, "127.0.0.1#3053 9.9.9.9")
  lu.assertEquals(state.noresolv, "1")
  lu.assertEquals(restart_attempts, 2)
end
