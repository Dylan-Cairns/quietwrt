local context_helpers = require("quietwrt.context")
local enforcement = require("quietwrt.enforcement")
local firewall = require("quietwrt.firewall")
local lists_store = require("quietwrt.lists_store")
local rules = require("quietwrt.rules")
local util = require("quietwrt.util")

local M = {}

local function marker_path(context)
  return context.paths.failsafe_marker_path
end

local function marker_content(reason, warnings, boot_id)
  local lines = {
    "QuietWrt entered failsafe-open mode.",
    "Reason: " .. tostring(reason or "Unknown failure."),
  }

  if boot_id ~= nil and boot_id ~= "" then
    table.insert(lines, "Boot-ID: " .. tostring(boot_id))
  end

  for _, warning in ipairs(warnings or {}) do
    table.insert(lines, "Warning: " .. tostring(warning))
  end

  return table.concat(lines, "\n") .. "\n"
end

function M.read_marker(context)
  local path = marker_path(context)
  if path == nil or path == "" then
    return {
      active = false,
    }
  end

  local content = context.env.read_file(path)
  if content == nil then
    return {
      active = false,
    }
  end

  local reason = content:match("Reason:%s*([^\n]+)") or util.trim(content)
  local boot_id = content:match("Boot%-ID:%s*([^\n]+)")
  return {
    active = true,
    reason = reason ~= "" and reason or "QuietWrt entered failsafe-open mode.",
    boot_id = boot_id and util.trim(boot_id) or nil,
    content = content,
  }
end

function M.current_boot_id(context)
  return util.trim(context.env.read_file(context.paths.boot_id_path) or "")
end

function M.is_latched_for_current_boot(context, marker)
  marker = marker or M.read_marker(context)
  if not marker.active then
    return false
  end

  local current_boot_id = M.current_boot_id(context)
  if marker.boot_id == nil or marker.boot_id == "" or current_boot_id == "" then
    return true
  end

  return marker.boot_id == current_boot_id
end

function M.clear_marker(context)
  local path = marker_path(context)
  if path == nil or path == "" then
    return true, nil
  end

  context.env.remove_file(path)
  if context.env.file_exists(path) then
    return false, "Could not remove " .. path .. "."
  end

  return true, nil
end

function M.write_marker(context, reason, warnings, boot_id)
  local ok, err = context_helpers.ensure_data_dir(context.env, context.paths)
  if not ok then
    return false, err, false
  end

  local content = marker_content(reason, warnings, boot_id)
  if context.env.read_file(marker_path(context)) == content then
    return true, nil, false
  end

  local saved, save_error = context_helpers.write_atomic(context.env, marker_path(context), content)
  return saved, save_error, saved
end

local function clear_adguard_rules_if_readable(context)
  local parsed_config = enforcement.read_state(context)
  if parsed_config == nil then
    return true, nil, "skipped"
  end

  local _, parsed_passthrough_rules = rules.partition_user_rules(parsed_config.rules)
  local passthrough_rules = parsed_passthrough_rules or {}
  local lists = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if lists ~= nil then
    passthrough_rules = lists.passthrough_rules or {}
  end

  local compiled_rules = rules.compile_active_rules({}, {}, passthrough_rules)
  local ok, err, changed = enforcement.apply_rules(context, parsed_config, compiled_rules)
  if not ok then
    return false, err
  end

  return true, nil, changed and "cleared" or "unchanged"
end

function M.enter_failsafe_open(context, reason)
  local warnings = {}

  local firewall_ok, firewall_error, firewall_changed = firewall.clear_managed(context)
  if not firewall_ok then
    table.insert(warnings, firewall_error)
  end

  local adguard_ok, adguard_error, adguard_state = clear_adguard_rules_if_readable(context)
  if not adguard_ok then
    table.insert(warnings, adguard_error)
  end

  local marker_ok, marker_error, marker_changed = M.write_marker(
    context,
    reason,
    warnings,
    M.current_boot_id(context)
  )
  if not marker_ok then
    table.insert(warnings, marker_error)
  end

  if not firewall_ok then
    return false, table.concat(warnings, " | ")
  end

  return true, {
    failsafe_open = true,
    reason = reason,
    warnings = warnings,
    changed = firewall_changed == true or adguard_state == "cleared" or marker_changed == true,
    boot_id = M.current_boot_id(context),
  }
end

return M
