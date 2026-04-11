local adguard = require("quietwrt.adguard")
local rules = require("quietwrt.rules")
local schedule = require("quietwrt.schedule")
local util = require("quietwrt.util")

local M = {}

local function default_ensure_dir(path)
  return util.command_succeeded(os.execute("mkdir -p " .. util.shell_quote(path)))
end

local function default_capture(command)
  local handle = io.popen(command .. " 2>/dev/null", "r")
  if not handle then
    return nil
  end

  local output = handle:read("*a") or ""
  handle:close()
  return util.trim(output)
end

local function default_file_exists(path)
  local handle = io.open(path, "rb")
  if handle then
    handle:close()
    return true
  end
  return false
end

local function default_paths()
  local data_dir = "/etc/quietwrt"
  return {
    config_path = "/etc/AdGuardHome/config.yaml",
    config_backup_path = "/etc/AdGuardHome/config.yaml.bak",
    data_dir = data_dir,
    always_list_path = data_dir .. "/always-blocked.txt",
    workday_list_path = data_dir .. "/workday-blocked.txt",
    passthrough_rules_path = data_dir .. "/passthrough-rules.txt",
    restart_adguard_command = "/etc/init.d/adguardhome restart >/tmp/quietwrt-adguard-restart.log 2>&1",
    crontab_path = "/etc/crontabs/root",
    quietwrtctl_path = "/usr/bin/quietwrtctl",
    cgi_path = "/www/cgi-bin/quietwrt",
    module_dir = "/usr/lib/lua/quietwrt",
    quietwrt_config_path = "/etc/config/quietwrt",
    restart_cron_command = "/etc/init.d/cron restart >/tmp/quietwrt-cron-restart.log 2>&1",
    restart_firewall_command = "service firewall restart >/tmp/quietwrt-firewall-restart.log 2>&1",
  }
end

local function default_env(overrides)
  local env = {
    read_file = util.read_file,
    write_file = util.write_file,
    rename_file = os.rename,
    remove_file = os.remove,
    execute = os.execute,
    capture = default_capture,
    ensure_dir = default_ensure_dir,
    file_exists = default_file_exists,
    now = function()
      return os.date("*t")
    end,
  }

  for key, value in pairs(overrides or {}) do
    env[key] = value
  end

  return env
end

local function bool_to_uci(value)
  return value and "1" or "0"
end

local function uci_to_bool(value, fallback)
  if value == "1" or value == "true" or value == "on" then
    return true
  end

  if value == "0" or value == "false" or value == "off" then
    return false
  end

  return fallback
end

local function write_atomic(env, path, content)
  local temp_path = path .. ".tmp"
  if not env.write_file(temp_path, content) then
    return false, "Could not write a temporary file for " .. path .. "."
  end

  if env.rename_file(temp_path, path) then
    return true, nil
  end

  env.remove_file(path)
  if env.rename_file(temp_path, path) then
    return true, nil
  end

  env.remove_file(temp_path)
  return false, "Could not replace " .. path .. "."
end

local function run_commands(env, commands)
  for _, command in ipairs(commands or {}) do
    if not util.command_succeeded(env.execute(command)) then
      return false, command
    end
  end
  return true, nil
end

local function ensure_data_dir(env, paths)
  if env.ensure_dir(paths.data_dir) then
    return true, nil
  end
  return false, "Could not create " .. paths.data_dir .. "."
end

local function read_adguard_state(env, paths)
  local content = env.read_file(paths.config_path)
  if not content then
    return nil, "Could not read " .. paths.config_path .. "."
  end

  local parsed = adguard.parse_config(content)
  parsed.content = content
  return parsed, nil
end

local function read_lists(env, paths)
  return {
    always_content = env.read_file(paths.always_list_path),
    workday_content = env.read_file(paths.workday_list_path),
    passthrough_content = env.read_file(paths.passthrough_rules_path),
  }
end

local function persist_lists(env, paths, data)
  local ok, err = ensure_data_dir(env, paths)
  if not ok then
    return false, err
  end

  local writes = {
    {
      path = paths.always_list_path,
      content = rules.serialize_hosts_file(data.always_hosts),
    },
    {
      path = paths.workday_list_path,
      content = rules.serialize_hosts_file(data.workday_hosts),
    },
    {
      path = paths.passthrough_rules_path,
      content = rules.serialize_rules_file(data.passthrough_rules),
    },
  }

  for _, item in ipairs(writes) do
    local saved, save_error = write_atomic(env, item.path, item.content)
    if not saved then
      return false, save_error
    end
  end

  return true, nil
end

local function load_lists(env, paths, parsed_config, allow_bootstrap)
  local existing = read_lists(env, paths)
  local have_all_lists = existing.always_content ~= nil
    and existing.workday_content ~= nil
    and existing.passthrough_content ~= nil

  if have_all_lists then
    return {
      always_hosts = rules.parse_hosts_file(existing.always_content),
      workday_hosts = rules.parse_hosts_file(existing.workday_content),
      passthrough_rules = rules.parse_rules_file(existing.passthrough_content),
      bootstrapped = false,
    }, nil
  end

  if allow_bootstrap == false then
    return {
      always_hosts = {},
      workday_hosts = {},
      passthrough_rules = {},
      bootstrapped = false,
    }, nil
  end

  local always_hosts, passthrough_rules = rules.partition_user_rules(parsed_config.rules)
  local bootstrapped = {
    always_hosts = always_hosts,
    workday_hosts = {},
    passthrough_rules = passthrough_rules,
    bootstrapped = true,
  }

  local saved, save_error = persist_lists(env, paths, bootstrapped)
  if not saved then
    return nil, save_error
  end

  return bootstrapped, nil
end

local function read_settings(env, fallback_enabled)
  local fallback = fallback_enabled == true
  return {
    always_enabled = uci_to_bool(env.capture("uci -q get quietwrt.settings.always_enabled"), fallback),
    workday_enabled = uci_to_bool(env.capture("uci -q get quietwrt.settings.workday_enabled"), fallback),
    overnight_enabled = uci_to_bool(env.capture("uci -q get quietwrt.settings.overnight_enabled"), fallback),
  }
end

local function write_settings(env, settings)
  return run_commands(env, {
    "uci -q delete quietwrt.settings",
    "uci set quietwrt.settings='settings'",
    "uci set quietwrt.settings.always_enabled='" .. bool_to_uci(settings.always_enabled) .. "'",
    "uci set quietwrt.settings.workday_enabled='" .. bool_to_uci(settings.workday_enabled) .. "'",
    "uci set quietwrt.settings.overnight_enabled='" .. bool_to_uci(settings.overnight_enabled) .. "'",
    "uci commit quietwrt",
  })
end

local function ensure_settings(env, settings)
  local current = read_settings(env, true)
  local desired = {
    always_enabled = settings and settings.always_enabled,
    workday_enabled = settings and settings.workday_enabled,
    overnight_enabled = settings and settings.overnight_enabled,
  }

  if desired.always_enabled == nil then
    desired.always_enabled = current.always_enabled
  end

  if desired.workday_enabled == nil then
    desired.workday_enabled = current.workday_enabled
  end

  if desired.overnight_enabled == nil then
    desired.overnight_enabled = current.overnight_enabled
  end

  local ok, failed_command = write_settings(env, desired)
  if ok then
    return true, desired
  end

  return false, "QuietWrt settings update failed while running: " .. failed_command
end

local function ensure_backup(env, paths, parsed_config)
  if env.file_exists(paths.config_backup_path) then
    return true, nil
  end

  if env.write_file(paths.config_backup_path, parsed_config.content) then
    return true, nil
  end

  return false, "Could not create " .. paths.config_backup_path .. "."
end

local function build_active_hosts(lists, settings, scheduled_mode)
  local always_hosts = {}
  local workday_hosts = {}

  if settings.always_enabled then
    always_hosts = lists.always_hosts
  end

  if scheduled_mode.code == "always_and_workday" and settings.workday_enabled then
    workday_hosts = lists.workday_hosts
  end

  return always_hosts, workday_hosts
end

local function build_view_state(parsed_config, lists, settings, current_mode, scheduled_mode, hardening_status, installed)
  local active_always_hosts, active_workday_hosts = build_active_hosts(lists, settings, scheduled_mode)
  local active_rules = rules.compile_active_rules(
    active_always_hosts,
    active_workday_hosts,
    lists.passthrough_rules,
    { code = "always_and_workday" }
  )

  return {
    installed = installed,
    protection_enabled = parsed_config and parsed_config.protection_enabled or nil,
    current_mode = current_mode,
    settings = settings,
    always_hosts = lists.always_hosts,
    workday_hosts = lists.workday_hosts,
    passthrough_rules = lists.passthrough_rules,
    active_rules = active_rules,
    active_rule_count = #active_rules,
    hardening = hardening_status,
    warnings = {},
  }
end

local function detect_installed(env, paths)
  return env.file_exists(paths.cgi_path)
    or env.file_exists(paths.quietwrtctl_path)
    or env.file_exists(paths.quietwrt_config_path)
    or env.file_exists(paths.always_list_path)
end

local function current_effective_mode(settings, now_table)
  local scheduled_mode = schedule.mode_at(now_table)

  if scheduled_mode.code == "internet_off" and not settings.overnight_enabled then
    return {
      code = "disabled_overnight",
      label = "Overnight block disabled",
      description = "Internet remains available because overnight blocking is disabled.",
    }, scheduled_mode
  end

  if scheduled_mode.code == "always_only" and not settings.always_enabled then
    return {
      code = "lists_disabled",
      label = "Lists disabled",
      description = "No blocklists are currently active.",
    }, scheduled_mode
  end

  if scheduled_mode.code == "always_and_workday" then
    if settings.always_enabled and settings.workday_enabled then
      return {
        code = "always_and_workday",
        label = "Always + Workday",
        description = "Both Always blocked and Workday blocked are active.",
      }, scheduled_mode
    end

    if settings.always_enabled then
      return {
        code = "always_only",
        label = "Always only",
        description = "Only the Always blocked list is active.",
      }, scheduled_mode
    end

    if settings.workday_enabled then
      return {
        code = "workday_only",
        label = "Workday only",
        description = "Only the Workday blocked list is active.",
      }, scheduled_mode
    end

    return {
      code = "lists_disabled",
      label = "Lists disabled",
      description = "No blocklists are currently active.",
    }, scheduled_mode
  end

  return scheduled_mode, scheduled_mode
end

local function hardening_status(env)
  return {
    dns_intercept = env.capture("uci -q get firewall.quietwrt_dns_int.name") ~= nil and env.capture("uci -q get firewall.quietwrt_dns_int.name") ~= "",
    dot_block = env.capture("uci -q get firewall.quietwrt_dot_fwd.name") ~= nil and env.capture("uci -q get firewall.quietwrt_dot_fwd.name") ~= "",
    overnight_rule = env.capture("uci -q get firewall.quietwrt_curfew.name") ~= nil and env.capture("uci -q get firewall.quietwrt_curfew.name") ~= "",
  }
end

local function ensure_firewall_rules(env, paths, curfew_enabled)
  local value = curfew_enabled and "1" or "0"
  local commands = {
    "uci -q delete firewall.quietwrt_dns_int",
    "uci set firewall.quietwrt_dns_int='redirect'",
    "uci set firewall.quietwrt_dns_int.name='QuietWrt-Intercept-DNS'",
    "uci set firewall.quietwrt_dns_int.family='ipv4'",
    "uci set firewall.quietwrt_dns_int.proto='tcp udp'",
    "uci set firewall.quietwrt_dns_int.src='lan'",
    "uci set firewall.quietwrt_dns_int.src_dport='53'",
    "uci set firewall.quietwrt_dns_int.target='DNAT'",
    "uci -q delete firewall.quietwrt_dot_fwd",
    "uci set firewall.quietwrt_dot_fwd='rule'",
    "uci set firewall.quietwrt_dot_fwd.name='QuietWrt-Deny-DoT'",
    "uci set firewall.quietwrt_dot_fwd.family='ipv4'",
    "uci set firewall.quietwrt_dot_fwd.src='lan'",
    "uci set firewall.quietwrt_dot_fwd.dest='wan'",
    "uci set firewall.quietwrt_dot_fwd.dest_port='853'",
    "uci set firewall.quietwrt_dot_fwd.proto='tcp udp'",
    "uci set firewall.quietwrt_dot_fwd.target='REJECT'",
    "uci -q delete firewall.quietwrt_curfew",
    "uci set firewall.quietwrt_curfew='rule'",
    "uci set firewall.quietwrt_curfew.name='QuietWrt-Internet-Curfew'",
    "uci set firewall.quietwrt_curfew.family='ipv4'",
    "uci set firewall.quietwrt_curfew.src='lan'",
    "uci set firewall.quietwrt_curfew.dest='wan'",
    "uci set firewall.quietwrt_curfew.proto='all'",
    "uci set firewall.quietwrt_curfew.target='REJECT'",
    "uci set firewall.quietwrt_curfew.enabled='" .. value .. "'",
    "uci commit firewall",
    paths.restart_firewall_command,
  }

  local ok, failed_command = run_commands(env, commands)
  if ok then
    return true, nil
  end

  return false, "Firewall update failed while running: " .. failed_command
end

local function build_cron_block(paths)
  return table.concat({
    "# BEGIN quietwrt schedule",
    "0 4 * * * " .. paths.quietwrtctl_path .. " sync",
    "30 16 * * * " .. paths.quietwrtctl_path .. " sync",
    "30 18 * * * " .. paths.quietwrtctl_path .. " sync",
    "# END quietwrt schedule",
    "",
  }, "\n")
end

local function strip_cron_block(original)
  return original
    :gsub("\n?# BEGIN quietwrt schedule\n.-\n# END quietwrt schedule", "")
    :gsub("^# BEGIN quietwrt schedule\n.-\n# END quietwrt schedule\n?", "")
    :gsub("%s+$", "")
end

local function install_schedule(env, paths)
  local original = env.read_file(paths.crontab_path) or ""
  local without_existing = strip_cron_block(original)

  local updated
  if without_existing == "" then
    updated = build_cron_block(paths)
  else
    updated = without_existing .. "\n\n" .. build_cron_block(paths)
  end

  local saved, save_error = write_atomic(env, paths.crontab_path, updated)
  if not saved then
    return false, save_error
  end

  if util.command_succeeded(env.execute(paths.restart_cron_command)) then
    return true, nil
  end

  return false, "Cron restart failed after updating " .. paths.crontab_path .. "."
end

local function remove_schedule(env, paths)
  local original = env.read_file(paths.crontab_path) or ""
  local updated = strip_cron_block(original)
  if updated ~= "" then
    updated = updated .. "\n"
  end

  local saved, save_error = write_atomic(env, paths.crontab_path, updated)
  if not saved then
    return false, save_error
  end

  if util.command_succeeded(env.execute(paths.restart_cron_command)) then
    return true, nil
  end

  return false, "Cron restart failed after updating " .. paths.crontab_path .. "."
end

local function remove_firewall_rules(env, paths)
  local ok, failed_command = run_commands(env, {
    "uci -q delete firewall.quietwrt_dns_int",
    "uci -q delete firewall.quietwrt_dot_fwd",
    "uci -q delete firewall.quietwrt_curfew",
    "uci commit firewall",
    paths.restart_firewall_command,
  })

  if ok then
    return true, nil
  end

  return false, "Firewall cleanup failed while running: " .. failed_command
end

local function status_snapshot(context, allow_bootstrap)
  local installed = detect_installed(context.env, context.paths)
  local settings = read_settings(context.env, true)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  local lists = {
    always_hosts = {},
    workday_hosts = {},
    passthrough_rules = {},
    bootstrapped = false,
  }
  local warnings = {}

  if not parsed_config then
    table.insert(warnings, config_error)
  else
    local loaded_lists, list_error = load_lists(context.env, context.paths, parsed_config, allow_bootstrap)
    if not loaded_lists then
      table.insert(warnings, list_error)
    else
      lists = loaded_lists
    end
  end

  local effective_mode, scheduled_mode = current_effective_mode(settings, context.env.now())
  local hardening = hardening_status(context.env)
  local snapshot = build_view_state(parsed_config, lists, settings, effective_mode, scheduled_mode, hardening, installed)
  snapshot.scheduled_mode = scheduled_mode
  snapshot.warnings = warnings
  return snapshot
end

local function render_status_text(snapshot)
  local lines = {
    "Installed: " .. (snapshot.installed and "yes" or "no"),
    "Mode: " .. snapshot.current_mode.label,
    "Protection: " .. (
      snapshot.protection_enabled == true and "enabled"
      or snapshot.protection_enabled == false and "disabled"
      or "unknown"
    ),
    "Always enabled: " .. (snapshot.settings.always_enabled and "yes" or "no"),
    "Workday enabled: " .. (snapshot.settings.workday_enabled and "yes" or "no"),
    "Overnight enabled: " .. (snapshot.settings.overnight_enabled and "yes" or "no"),
    "Always blocked: " .. tostring(#snapshot.always_hosts),
    "Workday blocked: " .. tostring(#snapshot.workday_hosts),
    "Active rules: " .. tostring(snapshot.active_rule_count),
    "DNS intercept hardening: " .. (snapshot.hardening.dns_intercept and "yes" or "no"),
    "DoT block hardening: " .. (snapshot.hardening.dot_block and "yes" or "no"),
    "Overnight rule present: " .. (snapshot.hardening.overnight_rule and "yes" or "no"),
  }

  if #snapshot.warnings > 0 then
    table.insert(lines, "Warnings: " .. table.concat(snapshot.warnings, " | "))
  end

  return table.concat(lines, "\n")
end

local function render_status_json(snapshot)
  return util.json_encode({
    installed = snapshot.installed,
    mode = snapshot.current_mode.code,
    mode_label = snapshot.current_mode.label,
    scheduled_mode = snapshot.scheduled_mode.code,
    protection_enabled = snapshot.protection_enabled,
    always_enabled = snapshot.settings.always_enabled,
    workday_enabled = snapshot.settings.workday_enabled,
    overnight_enabled = snapshot.settings.overnight_enabled,
    always_count = #snapshot.always_hosts,
    workday_count = #snapshot.workday_hosts,
    active_rule_count = snapshot.active_rule_count,
    hardening = snapshot.hardening,
    warnings = snapshot.warnings,
  })
end

function M.new_context(options)
  options = options or {}
  return {
    env = default_env(options.env),
    paths = options.paths or default_paths(),
  }
end

function M.load_view_state(context)
  local snapshot = status_snapshot(context, true)
  if snapshot.protection_enabled == nil and #snapshot.warnings > 0 then
    return nil, snapshot.warnings[1]
  end
  snapshot.bootstrapped = false
  return snapshot, nil
end

function M.apply_current_mode(context)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return false, config_error
  end

  local lists, list_error = load_lists(context.env, context.paths, parsed_config, true)
  if not lists then
    return false, list_error
  end

  local settings = read_settings(context.env, true)
  local effective_mode, scheduled_mode = current_effective_mode(settings, context.env.now())
  local active_always_hosts, active_workday_hosts = build_active_hosts(lists, settings, scheduled_mode)
  local compiled_rules = rules.compile_active_rules(
    active_always_hosts,
    active_workday_hosts,
    lists.passthrough_rules,
    { code = "always_and_workday" }
  )

  local updated_config = adguard.serialize_config(parsed_config, compiled_rules)
  local original_config = parsed_config.content

  if updated_config ~= original_config then
    local saved, save_error = write_atomic(context.env, context.paths.config_path, updated_config)
    if not saved then
      return false, save_error
    end

    if not util.command_succeeded(context.env.execute(context.paths.restart_adguard_command)) then
      write_atomic(context.env, context.paths.config_path, original_config)
      context.env.execute(context.paths.restart_adguard_command)
      return false, "AdGuard Home restart failed. The previous config was restored."
    end
  end

  local curfew_enabled = scheduled_mode.code == "internet_off" and settings.overnight_enabled
  local firewall_ok, firewall_error = ensure_firewall_rules(context.env, context.paths, curfew_enabled)
  if not firewall_ok then
    return false, firewall_error
  end

  return true, {
    mode = effective_mode,
    scheduled_mode = scheduled_mode,
    active_rule_count = #compiled_rules,
    bootstrapped = lists.bootstrapped,
  }
end

function M.add_entry(context, destination, raw_value)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return {
      ok = false,
      kind = "error",
      message = config_error,
    }
  end

  local lists, list_error = load_lists(context.env, context.paths, parsed_config, true)
  if not lists then
    return {
      ok = false,
      kind = "error",
      message = list_error,
    }
  end

  local result = rules.apply_addition(
    lists.always_hosts,
    lists.workday_hosts,
    destination,
    raw_value
  )

  if not result.ok then
    return result
  end

  local saved, save_error = persist_lists(context.env, context.paths, {
    always_hosts = result.always_hosts,
    workday_hosts = result.workday_hosts,
    passthrough_rules = lists.passthrough_rules,
  })

  if not saved then
    return {
      ok = false,
      kind = "error",
      message = save_error,
    }
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    return {
      ok = false,
      kind = "error",
      message = apply_result,
    }
  end

  result.mode = apply_result.mode
  result.active_rule_count = apply_result.active_rule_count
  return result
end

function M.install(context)
  local parsed_config, config_error = read_adguard_state(context.env, context.paths)
  if not parsed_config then
    return false, config_error
  end

  local backup_ok, backup_error = ensure_backup(context.env, context.paths, parsed_config)
  if not backup_ok then
    return false, backup_error
  end

  local settings_ok, settings_result = ensure_settings(context.env, {
    always_enabled = true,
    workday_enabled = true,
    overnight_enabled = true,
  })
  if not settings_ok then
    return false, settings_result
  end

  local schedule_ok, schedule_error = install_schedule(context.env, context.paths)
  if not schedule_ok then
    return false, schedule_error
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    return false, apply_result
  end

  return true, {
    mode = apply_result.mode,
    settings = settings_result,
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.set_toggle(context, toggle_name, enabled)
  local settings = read_settings(context.env, true)

  if toggle_name == "always" then
    settings.always_enabled = enabled
  elseif toggle_name == "workday" then
    settings.workday_enabled = enabled
  elseif toggle_name == "overnight" then
    settings.overnight_enabled = enabled
  else
    return false, "Unknown toggle: " .. tostring(toggle_name)
  end

  local settings_ok, settings_error = ensure_settings(context.env, settings)
  if not settings_ok then
    return false, settings_error
  end

  local applied, apply_result = M.apply_current_mode(context)
  if not applied then
    return false, apply_result
  end

  return true, {
    mode = apply_result.mode,
    settings = settings,
    active_rule_count = apply_result.active_rule_count,
  }
end

function M.remove(context)
  local restored_backup = false
  local backup_content = context.env.read_file(context.paths.config_backup_path)

  local schedule_ok, schedule_error = remove_schedule(context.env, context.paths)
  if not schedule_ok then
    return false, schedule_error
  end

  local firewall_ok, firewall_error = remove_firewall_rules(context.env, context.paths)
  if not firewall_ok then
    return false, firewall_error
  end

  local settings_ok, failed_command = run_commands(context.env, {
    "uci -q delete quietwrt.settings",
    "uci commit quietwrt",
    "rm -f " .. util.shell_quote(context.paths.quietwrt_config_path),
  })
  if not settings_ok then
    return false, "QuietWrt settings cleanup failed while running: " .. failed_command
  end

  if backup_content ~= nil then
    local saved, save_error = write_atomic(context.env, context.paths.config_path, backup_content)
    if not saved then
      return false, save_error
    end

    if not util.command_succeeded(context.env.execute(context.paths.restart_adguard_command)) then
      return false, "AdGuard Home restart failed after restoring the backup."
    end

    restored_backup = true
  end

  local data_removed, remove_error = run_commands(context.env, {
    "rm -rf " .. util.shell_quote(context.paths.data_dir),
  })
  if not data_removed then
    return false, "QuietWrt data cleanup failed while running: " .. remove_error
  end

  return true, {
    restored_backup = restored_backup,
  }
end

function M.status(context, options)
  local snapshot = status_snapshot(context, false)
  if options and options.json then
    return true, render_status_json(snapshot)
  end
  return true, render_status_text(snapshot)
end

return M
