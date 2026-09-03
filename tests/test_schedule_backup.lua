local lu = require("luaunit")
local schedule_backup = require("quietwrt.schedule_backup")

TestScheduleBackup = {}

local function sample_settings()
  return {
    always_enabled = true,
    workday_enabled = false,
    after_work_enabled = true,
    password_vault_enabled = false,
    overnight_enabled = true,
    saturday_blockout_enabled = true,
    workday_start = "0400",
    workday_end = "1630",
    after_work_start = "1700",
    after_work_end = "1930",
    password_vault_start = "0945",
    password_vault_end = "0930",
    overnight_start = "1930",
    overnight_end = "0500",
    schema_version = "5",
  }
end

function TestScheduleBackup:test_serialize_writes_only_versioned_schedule_timings()
  local content, err = schedule_backup.serialize(sample_settings())

  lu.assertNil(err)
  lu.assertEquals(content, table.concat({
    "format=quietwrt-schedules",
    "version=1",
    "workday_start=0400",
    "workday_end=1630",
    "after_work_start=1700",
    "after_work_end=1930",
    "password_vault_start=0945",
    "password_vault_end=0930",
    "overnight_start=1930",
    "overnight_end=0500",
    "",
  }, "\n"))
  lu.assertNil(content:find("enabled", 1, true))
end

function TestScheduleBackup:test_parse_accepts_crlf_and_normalizes_timings()
  local content = assert(schedule_backup.serialize(sample_settings())):gsub("\n", "\r\n")
  local timings, err = schedule_backup.parse(content)

  lu.assertNil(err)
  lu.assertEquals(timings.workday_start, "0400")
  lu.assertEquals(timings.after_work_end, "1930")
  lu.assertEquals(timings.overnight_end, "0500")
end

function TestScheduleBackup:test_parse_rejects_enabled_unknown_duplicate_missing_and_invalid_values()
  local valid = assert(schedule_backup.serialize(sample_settings()))

  local unknown, unknown_error = schedule_backup.parse(valid .. "overnight_enabled=1\n")
  lu.assertNil(unknown)
  lu.assertStrContains(unknown_error, "unexpected setting")

  local duplicate, duplicate_error = schedule_backup.parse(valid .. "workday_start=0500\n")
  lu.assertNil(duplicate)
  lu.assertStrContains(duplicate_error, "duplicate setting")

  local unsupported, unsupported_error = schedule_backup.parse(valid:gsub("version=1", "version=2"))
  lu.assertNil(unsupported)
  lu.assertStrContains(unsupported_error, "version is missing or unsupported")

  local missing, missing_error = schedule_backup.parse(valid:gsub("overnight_end=0500\n", ""))
  lu.assertNil(missing)
  lu.assertStrContains(missing_error, "missing overnight_end")

  local invalid, invalid_error = schedule_backup.parse(valid:gsub("after_work_end=1930", "after_work_end=2500"))
  lu.assertNil(invalid)
  lu.assertStrContains(invalid_error, "valid 24-hour time")
end

function TestScheduleBackup:test_overlay_preserves_enable_states_and_other_settings()
  local current = sample_settings()
  local restored = schedule_backup.overlay(current, {
    workday_start = "0500",
    workday_end = "1500",
    after_work_start = "1500",
    after_work_end = "1800",
    password_vault_start = "1000",
    password_vault_end = "0900",
    overnight_start = "1800",
    overnight_end = "0500",
  })

  lu.assertFalse(restored.workday_enabled)
  lu.assertTrue(restored.after_work_enabled)
  lu.assertFalse(restored.password_vault_enabled)
  lu.assertTrue(restored.overnight_enabled)
  lu.assertTrue(restored.saturday_blockout_enabled)
  lu.assertEquals(restored.schema_version, "5")
  lu.assertEquals(restored.workday_start, "0500")
  lu.assertEquals(current.workday_start, "0400")
end
