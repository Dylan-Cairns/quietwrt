local archive = require("quietwrt.archive")
local cron = require("quietwrt.cron")
local enforcement = require("quietwrt.enforcement")
local lists_store = require("quietwrt.lists_store")
local reconciler = require("quietwrt.reconciler")
local rules = require("quietwrt.rules")
local schedule_backup = require("quietwrt.schedule_backup")
local schema = require("quietwrt.schema")
local settings_store = require("quietwrt.settings_store")
local util = require("quietwrt.util")

local M = {}

local function append_rollback_errors(message, rollback_errors)
  if #rollback_errors == 0 then
    return message
  end

  return message .. " Rollback issues: " .. table.concat(rollback_errors, " | ")
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

local function load_current_state(context)
  if not settings_store.detect_installed(context) then
    return nil, "QuietWrt is not installed."
  end

  local parsed_config, config_error = enforcement.read_state(context)
  if not parsed_config then
    return nil, config_error
  end

  local enforcement_ok, enforcement_error = enforcement.require_ready(context, parsed_config)
  if not enforcement_ok then
    return nil, enforcement_error
  end

  local settings, settings_error = settings_store.read_settings(context, true)
  if not settings then
    return nil, settings_error
  end

  local lists, list_error = lists_store.load(context, parsed_config, {
    installed = true,
    allow_bootstrap = false,
  })
  if not lists then
    return nil, list_error
  end

  return {
    parsed_config = parsed_config,
    settings = settings,
    lists = lists,
    crontab = context.env.read_file(context.paths.crontab_path),
  }, nil
end

local function apply_desired(context, parsed_config, lists, settings)
  local ok, result = reconciler.reconcile(context, {
    desired = {
      parsed_config = parsed_config,
      lists = lists,
      settings = settings,
    },
  })
  if not ok then
    return false, result
  end
  if result.failsafe_open then
    return false, "QuietWrt entered failsafe-open mode: " .. tostring(result.reason)
  end

  return true, result
end

local function rollback_restore(context, current, changed, restore_runtime)
  local errors = {}

  if changed.lists then
    local saved, save_error = lists_store.persist(context, current.lists)
    if not saved then
      table.insert(errors, save_error)
    end
  end

  if changed.settings then
    local saved, save_error = settings_store.persist_settings(context, current.settings)
    if not saved then
      table.insert(errors, save_error)
    end
  end

  if changed.schedule then
    local restored, restore_error = cron.restore_schedule(context, current.crontab)
    if not restored then
      table.insert(errors, restore_error)
    end
  end

  if restore_runtime then
    local parsed_config, config_error = enforcement.read_state(context)
    if not parsed_config then
      table.insert(errors, config_error)
    else
      local restored, restore_error = apply_desired(
        context,
        parsed_config,
        current.lists,
        current.settings
      )
      if not restored then
        table.insert(errors, restore_error)
      end
    end
  end

  return errors
end

local function apply_restore(context, current, next_lists, next_settings, changed)
  if changed.lists then
    local saved, save_error = lists_store.persist(context, next_lists)
    if not saved then
      local rollback_errors = rollback_restore(context, current, {
        lists = true,
        settings = false,
        schedule = false,
      }, false)
      return false, append_rollback_errors(save_error, rollback_errors)
    end
  end

  if changed.schedule then
    local installed, install_error = cron.install_schedule(context, next_settings)
    if not installed then
      local rollback_errors = rollback_restore(context, current, {
        lists = changed.lists,
        settings = false,
        schedule = true,
      }, false)
      return false, append_rollback_errors(install_error, rollback_errors)
    end
  end

  local applied, apply_result = apply_desired(
    context,
    current.parsed_config,
    next_lists,
    next_settings
  )
  if not applied then
    local rollback_errors = rollback_restore(context, current, {
      lists = changed.lists,
      settings = false,
      schedule = changed.schedule,
    }, false)
    return false, append_rollback_errors(apply_result, rollback_errors)
  end

  if changed.schedule then
    local saved, save_result = settings_store.persist_settings(context, next_settings)
    if not saved then
      local rollback_errors = rollback_restore(context, current, {
        lists = changed.lists,
        settings = true,
        schedule = true,
      }, true)
      return false, append_rollback_errors(save_result, rollback_errors)
    end
  end

  return true, apply_result
end

local function load_schedule_file(context, path)
  if path == nil then
    return nil, nil, false
  end

  local content = context.env.read_file(path)
  if content == nil then
    return nil, "Could not read " .. path .. ".", true
  end

  local timings, timing_error = schedule_backup.parse(content)
  if not timings then
    return nil, timing_error, true
  end

  return timings, nil, true
end

local function load_restore_hosts(context, restore_paths, definition)
  local restore_path = restore_paths[definition.name .. "_path"]
  if restore_path == nil then
    return nil, nil, false
  end

  local content = context.env.read_file(restore_path)
  if content == nil then
    return nil, "Could not read " .. restore_path .. ".", true
  end

  local hosts, host_error = rules.load_hosts_file(content, restore_path)
  if not hosts then
    return nil, host_error, true
  end

  return hosts, nil, true
end

function M.restore_files(context, restore_paths)
  restore_paths = restore_paths or {}
  local current, current_error = load_current_state(context)
  if not current then
    return false, current_error
  end

  local next_lists = lists_store.clone(current.lists)
  local list_count = 0

  for _, definition in ipairs(schema.HOST_LISTS) do
    local hosts, host_error, selected = load_restore_hosts(context, restore_paths, definition)
    if host_error then
      return false, host_error
    end
    if selected then
      next_lists[definition.key] = hosts
      list_count = list_count + 1
    end
  end

  local timings, timing_error, schedule_selected = load_schedule_file(
    context,
    restore_paths.schedules_path
  )
  if timing_error then
    return false, timing_error
  end
  if list_count == 0 and not schedule_selected then
    return false, "Provide at least one restore file."
  end

  local valid, validation_error = rules.validate_lists(
    next_lists.always_hosts,
    scheduled_lists(next_lists)
  )
  if not valid then
    return false, validation_error
  end

  local next_settings = current.settings
  if schedule_selected then
    next_settings = schedule_backup.overlay(current.settings, timings)
  end

  local ok, result = apply_restore(context, current, next_lists, next_settings, {
    lists = list_count > 0,
    schedule = schedule_selected,
  })
  if not ok then
    return false, result
  end

  return true, {
    active_rule_count = result.active_rule_count,
    restored_list_count = list_count,
    schedules_restored = schedule_selected,
  }
end

function M.import_archive(context, content)
  local entries, archive_error = archive.unzip_stored(content)
  if not entries then
    return false, archive_error
  end

  local expected_files = {
    [schedule_backup.FILE_NAME] = true,
  }
  for _, definition in ipairs(schema.HOST_LISTS) do
    expected_files[definition.file_name] = true
  end

  for name, _ in pairs(entries) do
    if expected_files[name] == nil then
      return false, "ZIP archive contains an unexpected file: " .. name
    end
  end

  local current, current_error = load_current_state(context)
  if not current then
    return false, current_error
  end

  local next_lists = lists_store.clone(current.lists)
  local summary = {
    added_count = 0,
    duplicate_count = 0,
    imported_count = 0,
    lists = {},
    schedules_restored = false,
  }
  local list_count = 0

  for _, definition in ipairs(schema.HOST_LISTS) do
    local entry_content = entries[definition.file_name]
    if entry_content ~= nil then
      list_count = list_count + 1
      local imported_hosts, host_error = rules.load_hosts_file(entry_content, definition.file_name)
      if not imported_hosts then
        return false, host_error
      end

      local before = #(next_lists[definition.key] or {})
      local combined = {}
      for _, host in ipairs(next_lists[definition.key] or {}) do
        table.insert(combined, host)
      end
      for _, host in ipairs(imported_hosts) do
        table.insert(combined, host)
      end

      next_lists[definition.key] = util.sorted_unique(combined)
      local added = #next_lists[definition.key] - before
      local duplicates = #imported_hosts - added
      summary.added_count = summary.added_count + added
      summary.duplicate_count = summary.duplicate_count + duplicates
      summary.imported_count = summary.imported_count + #imported_hosts
      summary.lists[definition.name] = {
        added = added,
        duplicates = duplicates,
        imported = #imported_hosts,
      }
    end
  end

  local timings = nil
  local schedule_content = entries[schedule_backup.FILE_NAME]
  if schedule_content ~= nil then
    local timing_error
    timings, timing_error = schedule_backup.parse(schedule_content)
    if not timings then
      return false, timing_error
    end
    summary.schedules_restored = true
  end

  if list_count == 0 and not summary.schedules_restored then
    return false, "ZIP archive does not contain any QuietWrt backup files."
  end

  local valid, validation_error = rules.validate_lists(
    next_lists.always_hosts,
    scheduled_lists(next_lists)
  )
  if not valid then
    return false, validation_error
  end

  local next_settings = current.settings
  if summary.schedules_restored then
    next_settings = schedule_backup.overlay(current.settings, timings)
  end

  local ok, result = apply_restore(context, current, next_lists, next_settings, {
    lists = list_count > 0,
    schedule = summary.schedules_restored,
  })
  if not ok then
    return false, result
  end

  summary.active_rule_count = result.active_rule_count
  return true, summary
end

return M
