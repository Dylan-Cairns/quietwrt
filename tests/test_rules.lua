local helper = require("test_helper")
local lu = require("luaunit")
local rules = require("quietwrt.rules")

TestRules = {}

function TestRules:test_normalize_url_input()
  local host = rules.normalize_host_input("HTTPS://User@www.Example.com:443/path?q=1")
  lu.assertEquals(host, "www.example.com")
end

function TestRules:test_reject_ip_input()
  local host, err = rules.normalize_host_input("8.8.8.8")
  lu.assertNil(host)
  lu.assertStrContains(err, "IP addresses")
end

function TestRules:test_scheduled_lists_reject_existing_always_host()
  local result = rules.apply_addition({ "example.com" }, {
    workday = {},
    after_work = {},
  }, "workday", "example.com")
  lu.assertFalse(result.ok)
  lu.assertEquals(result.kind, "error")
  lu.assertStrContains(result.message, "already always blocked")
end

function TestRules:test_addition_preserves_existing_membership()
  for _, source in ipairs({"always", "workday", "after_work", "password_vault"}) do
    for _, destination in ipairs({"always", "workday", "after_work", "password_vault"}) do
      local lists = {always={}, workday={}, after_work={}, password_vault={}}
      lists[source] = {"example.com"}
      local result = rules.apply_addition(lists.always, lists, destination, "example.com")
      lu.assertFalse(result.ok)
      for name, hosts in pairs(lists) do
        lu.assertEquals(result[name .. "_hosts"], hosts)
      end
    end
  end
end

function TestRules:test_addition_enforces_unique_domain_limit()
  local hosts = {}
  for i = 1, rules.MAX_HOSTS_PER_LIST - 1 do hosts[i] = "host" .. i .. ".example" end
  for _, destination in ipairs({"always", "workday", "after_work", "password_vault"}) do
    local lists = {always={}, workday={}, after_work={}, password_vault={}}
    lists[destination] = hosts
    local result = rules.apply_addition(lists.always, lists, destination, "last.example")
    lu.assertTrue(result.ok)
    lists[destination] = result[destination .. "_hosts"]
    local duplicate = rules.apply_addition(lists.always, lists, destination, "last.example")
    lu.assertEquals(duplicate.kind, "info")
    result = rules.apply_addition(lists.always, lists, destination, "overflow.example")
    lu.assertFalse(result.ok)
    lu.assertStrContains(result.message, "limited")
    lu.assertEquals(#result[destination .. "_hosts"], rules.MAX_HOSTS_PER_LIST)
  end
end

function TestRules:test_compile_active_rules_unions_always_and_scheduled_lists()
  local compiled = rules.compile_active_rules(
    { "always.com" },
    { "workday.com", "afterwork.com" },
    { "@@||allowed.com^" }
  )

  lu.assertEquals(compiled, {
    "@@||allowed.com^",
    "||afterwork.com^",
    "||always.com^",
    "||workday.com^",
  })
end

function TestRules:test_partition_user_rules_preserves_passthrough()
  local always_hosts, passthrough_rules = rules.partition_user_rules({
    "||example.com^",
    "@@||allowed.com^",
    "# comment",
  })

  lu.assertEquals(always_hosts, { "example.com" })
  lu.assertEquals(passthrough_rules, {
    "@@||allowed.com^",
    "# comment",
  })
end

function TestRules:test_load_hosts_file_requires_canonical_hostnames()
  local hosts, err = rules.load_hosts_file("Example.com\n", "always.txt")
  lu.assertNil(hosts)
  lu.assertStrContains(err, "canonical lowercase")
end

function TestRules:test_load_rules_file_rejects_block_rules()
  local parsed, err = rules.load_rules_file("||example.com^\n", "passthrough.txt")
  lu.assertNil(parsed)
  lu.assertStrContains(err, "passthrough")
end

function TestRules:test_validate_lists_passes_for_clean_lists()
  local ok, err = rules.validate_lists(
    { "always.com" },
    { workday = { "work.com" }, after_work = {}, password_vault = {} }
  )
  lu.assertTrue(ok)
  lu.assertNil(err)
end

function TestRules:test_validate_lists_rejects_host_in_always_and_workday()
  local ok, err = rules.validate_lists(
    { "example.com" },
    { workday = { "example.com" }, after_work = {}, password_vault = {} }
  )
  lu.assertFalse(ok)
  lu.assertStrContains(err, "example.com")
  lu.assertStrContains(err, "Always blocked")
  lu.assertStrContains(err, "Workday blocked")
end

function TestRules:test_validate_lists_rejects_host_in_always_and_after_work()
  local ok, err = rules.validate_lists(
    { "example.com" },
    { workday = {}, after_work = { "example.com" }, password_vault = {} }
  )
  lu.assertFalse(ok)
  lu.assertStrContains(err, "example.com")
  lu.assertStrContains(err, "After work blocked")
end

function TestRules:test_validate_lists_rejects_host_in_multiple_scheduled_lists()
  local ok, err = rules.validate_lists(
    {},
    { workday = { "example.com" }, after_work = { "example.com" }, password_vault = {} }
  )
  lu.assertFalse(ok)
  lu.assertStrContains(err, "example.com")
  lu.assertStrContains(err, "Workday blocked")
  lu.assertStrContains(err, "After work blocked")
end
