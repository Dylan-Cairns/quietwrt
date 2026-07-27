local helper = require("test_helper")
local lu = require("luaunit")
local platform = require("quietwrt.platform")

TestPlatform = {}

function TestPlatform:test_prepare_enables_and_persists_bridge_netfilter()
  local fixture = helper.make_context()
  os.remove(fixture.paths.bridge_netfilter_config_path)
  helper.write_file(fixture.paths.bridge_netfilter_runtime_path, "0\n")

  local ok, snapshot = platform.prepare({
    env = fixture.env,
    paths = fixture.paths,
  })

  lu.assertTrue(ok)
  lu.assertFalse(snapshot.config_present)
  lu.assertEquals(snapshot.runtime_value, "0")
  lu.assertEquals(
    helper.read_file(fixture.paths.bridge_netfilter_config_path),
    platform.BRIDGE_SYSCTL_CONTENT
  )
  lu.assertEquals(helper.read_file(fixture.paths.bridge_netfilter_runtime_path), "1\n")
  fixture.cleanup()
end

function TestPlatform:test_restore_returns_platform_to_pre_install_state()
  local fixture = helper.make_context()
  os.remove(fixture.paths.bridge_netfilter_config_path)
  helper.write_file(fixture.paths.bridge_netfilter_runtime_path, "0\n")
  local context = {
    env = fixture.env,
    paths = fixture.paths,
  }

  local ok, snapshot = platform.prepare(context)
  lu.assertTrue(ok)
  lu.assertEquals(platform.restore(context, snapshot), {})
  lu.assertNil(helper.read_file(fixture.paths.bridge_netfilter_config_path))
  lu.assertEquals(helper.read_file(fixture.paths.bridge_netfilter_runtime_path), "0\n")
  fixture.cleanup()
end

function TestPlatform:test_prepare_rejects_a_different_board_without_changes()
  local fixture = helper.make_context({
    capture_map = {
      [platform.CAPTURE_COMMANDS.board] = '{ "board_name": "other,router" }',
    },
  })
  local original_config = helper.read_file(fixture.paths.bridge_netfilter_config_path)
  local original_runtime = helper.read_file(fixture.paths.bridge_netfilter_runtime_path)

  local ok, err = platform.prepare({
    env = fixture.env,
    paths = fixture.paths,
  })

  lu.assertFalse(ok)
  lu.assertStrContains(err, "glinet,mt3000-snand")
  lu.assertEquals(helper.read_file(fixture.paths.bridge_netfilter_config_path), original_config)
  lu.assertEquals(helper.read_file(fixture.paths.bridge_netfilter_runtime_path), original_runtime)
  lu.assertEquals(#fixture.commands, 0)
  fixture.cleanup()
end

function TestPlatform:test_readiness_requires_eth1_on_br_lan_and_physdev()
  local fixture = helper.make_context({
    capture_map = {
      [platform.CAPTURE_COMMANDS.bridge] = "br-guest",
    },
  })
  local context = {
    env = fixture.env,
    paths = fixture.paths,
  }

  lu.assertEquals(platform.readiness_error(context), "eth1 is not attached to br-lan.")

  fixture.env.capture = function(command)
    if command == platform.CAPTURE_COMMANDS.physdev then
      return ""
    end
    return helper.PLATFORM_CAPTURE[command] or ""
  end
  lu.assertEquals(platform.readiness_error(context), "The iptables physdev match is unavailable.")
  fixture.cleanup()
end
