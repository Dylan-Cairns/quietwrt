local archive_ops = require("quietwrt.archive_ops")
local context_helpers = require("quietwrt.context")
local install_ops = require("quietwrt.install_ops")
local list_ops = require("quietwrt.list_ops")
local reconciler = require("quietwrt.reconciler")
local recovery = require("quietwrt.recovery")
local settings_ops = require("quietwrt.settings_ops")
local status_ops = require("quietwrt.status_ops")

local M = {}

local function failsafe_mutation_error(context)
  local marker = recovery.read_marker(context)
  if marker.active then
    return "QuietWrt is latched in failsafe-open mode for this boot: " .. marker.reason
      .. " Use authenticated `quietwrtctl recover` to attempt recovery now, or reboot."
  end

  return nil
end

local function locked(context, callback)
  return context_helpers.with_lock(context, callback)
end

local function locked_result(context, callback)
  local result, lock_error = context_helpers.with_lock(context, callback)
  if result == false then
    return {
      ok = false,
      kind = "error",
      message = lock_error,
    }
  end

  return result
end

function M.load_view_state(context)
  return status_ops.load_view_state(context)
end

function M.apply_current_mode(context)
  return locked(context, function()
    return reconciler.reconcile(context)
  end)
end

function M.add_entry(context, destination, raw_value)
  return locked_result(context, function()
    local marker_error = failsafe_mutation_error(context)
    if marker_error then
      return {
        ok = false,
        kind = "error",
        message = marker_error,
      }
    end

    return list_ops.add_entry(context, destination, raw_value)
  end)
end

function M.download_blocklists_archive(context, format)
  return archive_ops.download_blocklists_archive(context, format)
end

function M.install(context)
  return locked(context, function()
    local ok, result = install_ops.install(context)
    if ok then
      local marker_ok, marker_error = recovery.clear_marker(context)
      if not marker_ok then
        local reason = "QuietWrt was installed, but failsafe-open could not be cleared: " .. marker_error
        local opened, failsafe_result = recovery.enter_failsafe_open(context, reason)
        if not opened then
          return false, reason .. " Safe-open enforcement also failed: " .. tostring(failsafe_result)
        end

        return false, reason .. " QuietWrt restrictions were removed to preserve access."
      end
    end

    return ok, result
  end)
end

function M.boot_check(context)
  return locked(context, function()
    return reconciler.reconcile(context, {
      boot = true,
    })
  end)
end

function M.recover(context)
  return locked(context, function()
    return reconciler.reconcile(context, {
      force_recovery = true,
    })
  end)
end

function M.set_toggle(context, toggle_name, enabled)
  return locked(context, function()
    local marker_error = failsafe_mutation_error(context)
    if marker_error then
      return false, marker_error
    end

    return settings_ops.set_toggle(context, toggle_name, enabled)
  end)
end

function M.enable_toggle(context, toggle_name)
  return locked(context, function()
    local marker_error = failsafe_mutation_error(context)
    if marker_error then
      return false, marker_error
    end

    return settings_ops.enable_toggle(context, toggle_name)
  end)
end

function M.set_schedule(context, schedule_name, start_value, end_value)
  return locked(context, function()
    local marker_error = failsafe_mutation_error(context)
    if marker_error then
      return false, marker_error
    end

    return settings_ops.set_schedule(context, schedule_name, start_value, end_value)
  end)
end

function M.restore_lists(context, restore_paths)
  return locked(context, function()
    local marker_error = failsafe_mutation_error(context)
    if marker_error then
      return false, marker_error
    end

    return list_ops.restore_lists(context, restore_paths)
  end)
end

function M.import_blocklists_archive(context, content)
  return locked(context, function()
    local marker_error = failsafe_mutation_error(context)
    if marker_error then
      return false, marker_error
    end

    return list_ops.import_blocklists_archive(context, content)
  end)
end

function M.status(context, options)
  return status_ops.status(context, options)
end

return M
