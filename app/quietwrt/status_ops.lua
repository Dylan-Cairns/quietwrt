local enforcement = require("quietwrt.enforcement")
local firewall = require("quietwrt.firewall")
local lists_store = require("quietwrt.lists_store")
local platform = require("quietwrt.platform")
local recovery = require("quietwrt.recovery")
local runtime = require("quietwrt.runtime")
local settings_store = require("quietwrt.settings_store")
local status_render = require("quietwrt.status_render")
local util = require("quietwrt.util")

local M = {}

local function warning_list(...)
  local warnings = {}
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil and value ~= "" then
      table.insert(warnings, value)
    end
  end
  return warnings
end

local function degraded_snapshot(context, now_table, install_state, failsafe, warnings)
  local snapshot = runtime.uninstalled_snapshot(now_table)
  snapshot.installed = install_state.installed
  snapshot.schema_version = install_state.schema_version
  snapshot.install_state = install_state
  snapshot.hardening = firewall.hardening_status(context)
  snapshot.warnings = warnings or {}
  snapshot.failsafe = failsafe
  snapshot.reconciliation_state = failsafe.active and "failsafe_open" or "degraded"
  snapshot.desired_active_rule_count = 0
  snapshot.effective_active_rule_count = 0
  return snapshot
end

local function status_snapshot(context)
  local install_state = settings_store.read_install_state(context)
  local now_table = context.env.now()
  local failsafe = recovery.read_marker(context)

  if not install_state.installed then
    local snapshot = runtime.uninstalled_snapshot(now_table)
    snapshot.schema_version = install_state.schema_version
    snapshot.install_state = install_state
    snapshot.failsafe = failsafe
    snapshot.reconciliation_state = failsafe.active and "failsafe_open" or "uninstalled"
    snapshot.desired_active_rule_count = 0
    snapshot.effective_active_rule_count = 0
    return snapshot, nil
  end

  local settings, settings_error = settings_store.read_settings(context, true)
  if not settings then
    return degraded_snapshot(context, now_table, install_state, failsafe, warning_list(settings_error)), nil
  end

  local activity, activity_error = runtime.build_runtime_activity(settings, now_table)
  if not activity then
    return degraded_snapshot(context, now_table, install_state, failsafe, warning_list(activity_error)), nil
  end

  local parsed_config, config_error = enforcement.read_state(context)
  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    lists = lists_store.empty_state()
  end

  local warnings = {}
  if config_error then
    table.insert(warnings, config_error)
  else
    local enforcement_warning = enforcement.enforcement_error(context, parsed_config)
    if enforcement_warning then
      table.insert(warnings, enforcement_warning)
    end
  end

  if list_error then
    table.insert(warnings, list_error)
  end

  local platform_warning = platform.readiness_error(context)
  if platform_warning then
    table.insert(warnings, platform_warning)
  end

  local enforcement_ready = parsed_config ~= nil
    and enforcement.is_ready(context, parsed_config)
    and platform_warning == nil
    or false
  local hardening = firewall.hardening_status(context)
  local snapshot = runtime.build_view_state(
    parsed_config,
    lists,
    settings,
    activity,
    hardening,
    true,
    enforcement_ready
  )
  snapshot.router_time = runtime.format_router_time(now_table)
  snapshot.schema_version = install_state.schema_version or snapshot.schema_version
  snapshot.install_state = install_state
  snapshot.warnings = warnings
  snapshot.failsafe = failsafe
  snapshot.desired_active_rule_count = snapshot.active_rule_count
  snapshot.effective_active_rule_count = parsed_config and #(parsed_config.rules or {}) or 0

  local desired_firewall = firewall.desired_snapshot(
    activity.overnight_active or activity.saturday_blockout_active
  )
  local adguard_applied = parsed_config ~= nil
    and util.arrays_equal(parsed_config.rules, snapshot.active_rules)
  local firewall_applied = firewall.snapshots_equal(
    firewall.capture_snapshot(context),
    desired_firewall
  ) and firewall.runtime_matches_snapshot(context, desired_firewall)
  snapshot.reconciliation_state = failsafe.active and "failsafe_open"
    or adguard_applied and firewall_applied and "applied"
    or "degraded"
  return snapshot, nil
end

function M.load_view_state(context)
  local snapshot, err = status_snapshot(context)
  if not snapshot then
    return nil, err
  end

  if not snapshot.installed then
    return nil, "QuietWrt is not installed."
  end

  return snapshot, nil
end

function M.status(context, options)
  local snapshot, err = status_snapshot(context)
  if not snapshot then
    return false, err
  end

  if options and options.json then
    return true, status_render.render_json(snapshot)
  end

  return true, status_render.render_text(snapshot)
end

return M
