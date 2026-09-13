local adguard = require("quietwrt.adguard")
local lu = require("luaunit")

TestAdGuard = {}

function TestAdGuard:test_replaces_upstream_and_preserves_other_dns_settings()
  local parsed = adguard.parse_config(table.concat({
    "protection_enabled: true",
    "dns:",
    "  port: 3053",
    "  upstream_dns:",
    "  - 'https://dns.example/dns-query'",
    "  bootstrap_dns:",
    "  - 9.9.9.9",
    "user_rules:",
    "  - '||old.example^'",
  }, "\n") .. "\n")

  local updated = adguard.serialize_config(parsed, { "||new.example^" }, adguard.DNSMASQ_UPSTREAM)
  local reparsed = adguard.parse_config(updated)

  lu.assertTrue(adguard.has_dnsmasq_upstream(reparsed))
  lu.assertEquals(reparsed.rules, { "||new.example^" })
  lu.assertStrContains(updated, "  port: 3053")
  lu.assertStrContains(updated, "  bootstrap_dns:")
  lu.assertStrContains(updated, "  - 9.9.9.9")
  lu.assertNil(updated:find("dns.example", 1, true))
end

function TestAdGuard:test_adds_missing_dns_section()
  local parsed = adguard.parse_config("protection_enabled: true\nuser_rules: []\n")
  local updated = adguard.serialize_config(parsed, {}, adguard.DNSMASQ_UPSTREAM)
  local reparsed = adguard.parse_config(updated)

  lu.assertTrue(adguard.has_dnsmasq_upstream(reparsed))
  lu.assertStrContains(updated, "dns:\n  upstream_dns:\n    - '127.0.0.1:53'")
end

function TestAdGuard:test_requires_only_dnsmasq_as_upstream()
  local parsed = adguard.parse_config(table.concat({
    "dns:",
    "  upstream_dns:",
    "  - '127.0.0.1:53'",
    "  - '9.9.9.9'",
    "user_rules: []",
  }, "\n") .. "\n")

  lu.assertFalse(adguard.has_dnsmasq_upstream(parsed))
end
