local enforcement = require("quietwrt.enforcement")
local lists_store = require("quietwrt.lists_store")
local reconciler = require("quietwrt.reconciler")
local rules = require("quietwrt.rules")
local schema = require("quietwrt.schema")
local settings_store = require("quietwrt.settings_store")

local M = {}

local function apply_current_mode(context)
  local ok, result = reconciler.reconcile(context)
  if not ok then
    return false, result
  end

  if result.failsafe_open then
    return false, "QuietWrt entered failsafe-open mode: " .. tostring(result.reason)
  end

  return true, result
end

local function restore_previous_lists(context, previous_lists)
  local rollback_errors = {}

  local saved, save_error = lists_store.persist(context, previous_lists)
  if not saved then
    table.insert(rollback_errors, save_error)
    return rollback_errors
  end

  local restored, restore_error = apply_current_mode(context)
  if not restored then
    table.insert(rollback_errors, restore_error)
  end

  return rollback_errors
end

local function scheduled_lists(lists)
  local scheduled = {}

  for _, definition in ipairs(schema.HOST_LISTS) do
    if definition.name ~= "always" then
      scheduled[definition.name] = lists[definition.key]
    end
  end

  return scheduled
end

local function save_lists(context, result, passthrough_rules)
  local data = {
    passthrough_rules = passthrough_rules,
  }

  for _, definition in ipairs(schema.HOST_LISTS) do
    data[definition.key] = result[definition.key]
  end

  return lists_store.persist(context, data)
end

function M.add_entry(context, destination, raw_value)
  if not settings_store.detect_installed(context) then
    return {
      ok = false,
      kind = "error",
      message = "QuietWrt is not installed.",
    }
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return {
      ok = false,
      kind = "error",
      message = config_error,
    }
  end

  local enforcement_ok, enforcement_check_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return {
      ok = false,
      kind = "error",
      message = enforcement_check_error,
    }
  end

  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return {
      ok = false,
      kind = "error",
      message = list_error,
    }
  end

  local previous_lists = lists_store.clone(lists)
  local result = rules.apply_addition(
    lists.always_hosts,
    scheduled_lists(lists),
    destination,
    raw_value
  )

  if not result.ok then
    return result
  end

  local saved, save_error = save_lists(context, result, lists.passthrough_rules)
  if not saved then
    return {
      ok = false,
      kind = "error",
      message = save_error,
    }
  end

  local applied, apply_result = apply_current_mode(context)
  if not applied then
    local rollback_errors = restore_previous_lists(context, previous_lists)
    local message = apply_result
    if #rollback_errors > 0 then
      message = message .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
    end

    return {
      ok = false,
      kind = "error",
      message = message,
    }
  end

  result.active_rule_count = apply_result.active_rule_count
  return result
end

return M
