local helper = require("test_helper")
local lu = require("luaunit")
local service = require("quietwrt.service")

TestServiceIntegration = {}

function TestServiceIntegration:test_bootstraps_lists_from_existing_adguard_rules()
  local fixture = helper.make_context()
  helper.write_config(fixture.paths.config_path, {
    "||example.com^",
    "@@||allowed.com^",
  })

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local state, err = service.load_view_state(context)
  lu.assertNil(err)
  lu.assertEquals(state.always_hosts, { "example.com" })
  lu.assertEquals(state.workday_hosts, {})
  lu.assertEquals(state.active_rules, {
    "@@||allowed.com^",
    "||example.com^",
  })
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "example.com\n")
  fixture.cleanup()
end

function TestServiceIntegration:test_add_entry_moves_host_to_always_and_updates_config()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "")
  helper.write_file(fixture.paths.workday_list_path, "example.com\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local result = service.add_entry(context, "always", "example.com")
  lu.assertTrue(result.ok)
  lu.assertStrContains(result.message, "Moved example.com")
  lu.assertEquals(helper.read_file(fixture.paths.always_list_path), "example.com\n")
  lu.assertEquals(helper.read_file(fixture.paths.workday_list_path), "")
  lu.assertStrContains(helper.read_file(fixture.paths.config_path), "||example.com^")
  fixture.cleanup()
end

function TestServiceIntegration:test_restart_failure_restores_previous_config()
  local attempts = 0
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "1",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
    },
    execute = function(log, command)
      table.insert(log, command)
      if command == "restart-adguard" then
        attempts = attempts + 1
        if attempts == 1 then
          return 1
        end
      end
      return 0
    end,
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local original = helper.read_file(fixture.paths.config_path)
  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, err = service.apply_current_mode(context)
  lu.assertFalse(ok)
  lu.assertStrContains(err, "restart failed")
  lu.assertEquals(helper.read_file(fixture.paths.config_path), original)
  fixture.cleanup()
end

function TestServiceIntegration:test_install_writes_cron_backup_and_managed_firewall_rules()
  local fixture = helper.make_context({
    now = function()
      return { hour = 19, min = 0 }
    end,
  })
  helper.write_config(fixture.paths.config_path, {
    "||example.com^",
  })
  helper.write_file(fixture.paths.cgi_path, "#!/bin/sh\n")
  helper.write_file(fixture.paths.quietwrtctl_path, "#!/usr/bin/lua\n")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.install(context)
  lu.assertTrue(ok)
  lu.assertEquals(result.mode.code, "internet_off")
  lu.assertEquals(helper.read_file(fixture.paths.config_backup_path), helper.read_file(fixture.paths.config_path))
  lu.assertStrContains(helper.read_file(fixture.paths.crontab_path), "30 16 * * * /usr/bin/quietwrtctl sync")

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "uci set quietwrt.settings.always_enabled='1'")
  lu.assertStrContains(joined, "uci set firewall.quietwrt_dns_int='redirect'")
  lu.assertStrContains(joined, "uci set firewall.quietwrt_dot_fwd='rule'")
  lu.assertStrContains(joined, "uci set firewall.quietwrt_curfew.enabled='1'")
  fixture.cleanup()
end

function TestServiceIntegration:test_status_json_reports_flags_counts_and_hardening()
  local fixture = helper.make_context({
    capture_map = {
      ["uci -q get quietwrt.settings.always_enabled"] = "1",
      ["uci -q get quietwrt.settings.workday_enabled"] = "0",
      ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
      ["uci -q get firewall.quietwrt_dns_int.name"] = "QuietWrt-Intercept-DNS",
      ["uci -q get firewall.quietwrt_dot_fwd.name"] = "QuietWrt-Deny-DoT",
      ["uci -q get firewall.quietwrt_curfew.name"] = "QuietWrt-Internet-Curfew",
    },
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")
  helper.write_file(fixture.paths.cgi_path, "#!/bin/sh\n")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, output = service.status(context, {
    json = true,
  })
  lu.assertTrue(ok)
  lu.assertStrContains(output, '"always_enabled":true')
  lu.assertStrContains(output, '"workday_enabled":false')
  lu.assertStrContains(output, '"always_count":1')
  lu.assertStrContains(output, '"dns_intercept":true')
  fixture.cleanup()
end

function TestServiceIntegration:test_set_toggle_updates_settings_and_reapplies()
  local capture_state = {
    ["uci -q get quietwrt.settings.always_enabled"] = "1",
    ["uci -q get quietwrt.settings.workday_enabled"] = "1",
    ["uci -q get quietwrt.settings.overnight_enabled"] = "1",
  }

  local fixture = helper.make_context({
    capture = function(command)
      return capture_state[command] or ""
    end,
    execute = function(log, command)
      table.insert(log, command)
      local option, value = command:match("^uci set quietwrt%.settings%.([%w_]+)='([01])'$")
      if option and value then
        capture_state["uci -q get quietwrt.settings." .. option] = value
      end
      return 0
    end,
  })

  helper.write_config(fixture.paths.config_path, {})
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.set_toggle(context, "workday", false)
  lu.assertTrue(ok)
  lu.assertEquals(result.settings.workday_enabled, false)

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "uci set quietwrt.settings.workday_enabled='0'")
  fixture.cleanup()
end

function TestServiceIntegration:test_remove_cleans_managed_state_and_restores_backup()
  local fixture = helper.make_context()
  helper.write_config(fixture.paths.config_path, {
    "||example.com^",
  })
  helper.write_file(fixture.paths.config_backup_path, "protection_enabled: true\nuser_rules: []\n")
  helper.write_file(fixture.paths.always_list_path, "example.com\n")
  helper.write_file(fixture.paths.workday_list_path, "work.com\n")
  helper.write_file(fixture.paths.passthrough_rules_path, "")

  local context = service.new_context({
    env = fixture.env,
    paths = fixture.paths,
  })

  local ok, result = service.remove(context)
  lu.assertTrue(ok)
  lu.assertTrue(result.restored_backup)
  lu.assertEquals(helper.read_file(fixture.paths.config_path), "protection_enabled: true\nuser_rules: []\n")

  local joined = table.concat(fixture.commands, "\n")
  lu.assertStrContains(joined, "uci -q delete firewall.quietwrt_dns_int")
  lu.assertStrContains(joined, "rm -rf")
  fixture.cleanup()
end
