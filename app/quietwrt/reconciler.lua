local apply_engine = require("quietwrt.apply_engine")
local enforcement = require("quietwrt.enforcement")
local lists_store = require("quietwrt.lists_store")
local platform = require("quietwrt.platform")
local recovery = require("quietwrt.recovery")
local settings_store = require("quietwrt.settings_store")

local M = {}

local function enter_failsafe(context, reason)
  local opened, result = recovery.enter_failsafe_open(context, reason)
  if not opened then
    return false, result
  end

  result.reconciliation_state = "failsafe_open"
  return true, result
end

local function load_desired_state(context, overrides)
  overrides = overrides or {}
  local install_state = settings_store.read_install_state(context)
  if not install_state.installed then
    if install_state.settings_path_present then
      return nil, "QuietWrt settings are incomplete or use an unsupported schema version."
    end

    return {
      uninstalled = true,
    }, nil
  end

  local settings = overrides.settings
  local settings_error = nil
  if settings == nil then
    settings, settings_error = settings_store.read_settings(context, true)
  end
  if not settings then
    return nil, settings_error
  end

  local parsed_config = overrides.parsed_config
  local config_error = nil
  if parsed_config == nil then
    parsed_config, config_error = enforcement.read_state(context)
  end
  if not parsed_config then
    return nil, config_error
  end

  local enforcement_ok, enforcement_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return nil, enforcement_error
  end

  local lists = overrides.lists
  local list_error = nil
  if lists == nil then
    lists, list_error = lists_store.load(context, parsed_config, {
      installed = true,
      allow_bootstrap = false,
    })
  end
  if not lists then
    return nil, list_error
  end

  return {
    settings = settings,
    parsed_config = parsed_config,
    lists = lists,
  }, nil
end

local function prepare_platform(context, options)
  local attempts = 1
  local delay_seconds = 5
  if options.boot == true then
    attempts = tonumber(options.platform_attempts) or 7
    delay_seconds = tonumber(options.platform_retry_seconds) or 5
  end

  local last_error = nil
  for attempt = 1, attempts do
    local ok, result = platform.prepare(context)
    if ok then
      return true, nil
    end

    last_error = result
    if attempt >= attempts or not platform.is_retryable_error(result) then
      break
    end

    context.env.sleep(delay_seconds)
  end

  return false, last_error
end

function M.reconcile(context, options)
  options = options or {}
  local marker = recovery.read_marker(context)

  if marker.active
      and options.force_recovery ~= true
      and recovery.is_latched_for_current_boot(context, marker) then
    return enter_failsafe(context, marker.reason)
  end

  local desired, desired_error = load_desired_state(context, options.desired)
  if not desired then
    return enter_failsafe(context, desired_error)
  end

  if desired.uninstalled then
    if marker.active then
      local marker_ok, marker_error = recovery.clear_marker(context)
      if not marker_ok then
        return enter_failsafe(
          context,
          "QuietWrt is not installed, but failsafe-open could not be cleared: " .. marker_error
        )
      end
    end

    return true, {
      healthy = true,
      uninstalled = true,
      recovered = marker.active == true,
      reconciliation_state = "uninstalled",
    }
  end

  local platform_ok, platform_error = prepare_platform(context, options)
  if not platform_ok then
    return enter_failsafe(context, platform_error)
  end

  local applied, apply_result = apply_engine.apply_mode(context, {
    parsed_config = desired.parsed_config,
    lists = desired.lists,
    settings = desired.settings,
  })
  if not applied then
    return enter_failsafe(context, apply_result)
  end

  local marker_ok, marker_error = recovery.clear_marker(context)
  if not marker_ok then
    return enter_failsafe(
      context,
      "Desired policy was applied, but failsafe-open could not be cleared: " .. marker_error
    )
  end

  apply_result.healthy = true
  apply_result.recovered = marker.active == true
  apply_result.reconciliation_state = "applied"
  return true, apply_result
end

return M
