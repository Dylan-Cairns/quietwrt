local context_helpers = require("quietwrt.context")
local util = require("quietwrt.util")

local M = {}

M.BOARD_NAME = "glinet,mt3000-snand"
M.BRIDGE_DEVICE = "br-lan"
M.LAN_DEVICE = "eth1"
M.CURFEW_EXTRA = "-m physdev --physdev-in eth1 ! --physdev-is-bridged"
M.BRIDGE_SYSCTL_CONTENT = "net.bridge.bridge-nf-call-iptables=1\n"

M.CAPTURE_COMMANDS = {
  board = "ubus call system board",
  bridge = "basename \"$(readlink -f /sys/class/net/eth1/brport/bridge 2>/dev/null)\"",
  firewall = "command -v fw3 >/dev/null 2>&1 && iptables -V 2>/dev/null",
  physdev = "iptables -m physdev -h >/dev/null 2>&1 && echo ready",
}

local RETRYABLE_ERRORS = {
  [M.LAN_DEVICE .. " is not attached to " .. M.BRIDGE_DEVICE .. "."] = true,
  ["The iptables physdev match is unavailable."] = true,
  ["Could not enable bridge iptables processing."] = true,
}

local function platform_error(context)
  local board_output = context.env.capture(M.CAPTURE_COMMANDS.board) or ""
  local board_name = board_output:match('"board_name"%s*:%s*"([^"]+)"')
  if board_name ~= M.BOARD_NAME then
    return "QuietWrt requires GL-MT3000 board " .. M.BOARD_NAME .. "."
  end

  local bridge_name = util.trim(context.env.capture(M.CAPTURE_COMMANDS.bridge) or "")
  if bridge_name ~= M.BRIDGE_DEVICE then
    return M.LAN_DEVICE .. " is not attached to " .. M.BRIDGE_DEVICE .. "."
  end

  local firewall_version = context.env.capture(M.CAPTURE_COMMANDS.firewall) or ""
  if not firewall_version:find("legacy", 1, true) then
    return "QuietWrt requires the GL-MT3000 fw3/iptables legacy firewall."
  end

  if not context.env.file_exists(context.paths.iptables_physdev_extension_path) then
    return "Missing " .. context.paths.iptables_physdev_extension_path .. "."
  end

  local physdev_status = util.trim(context.env.capture(M.CAPTURE_COMMANDS.physdev) or "")
  if physdev_status ~= "ready" then
    return "The iptables physdev match is unavailable."
  end

  return nil
end

function M.readiness_error(context)
  local err = platform_error(context)
  if err then
    return err
  end

  local bridge_value = util.trim(context.env.read_file(context.paths.bridge_netfilter_runtime_path) or "")
  if bridge_value ~= "1" then
    return "Bridge iptables processing is not enabled."
  end

  local config_content = context.env.read_file(context.paths.bridge_netfilter_config_path)
  if config_content ~= M.BRIDGE_SYSCTL_CONTENT then
    return "QuietWrt bridge-netfilter persistence is missing or incorrect."
  end

  return nil
end

function M.is_ready(context)
  return M.readiness_error(context) == nil
end

function M.require_ready(context)
  local err = M.readiness_error(context)
  if err then
    return false, err
  end

  return true, nil
end

function M.is_retryable_error(err)
  local message = tostring(err or "")
  if RETRYABLE_ERRORS[message] then
    return true
  end

  return message:find("Could not enable bridge iptables processing.", 1, true) == 1
end

local function restore_config_file(context, snapshot)
  if snapshot.config_present then
    return context_helpers.write_atomic(
      context.env,
      context.paths.bridge_netfilter_config_path,
      snapshot.config_content or ""
    )
  end

  context.env.remove_file(context.paths.bridge_netfilter_config_path)
  if context.env.file_exists(context.paths.bridge_netfilter_config_path) then
    return false, "Could not remove " .. context.paths.bridge_netfilter_config_path .. "."
  end

  return true, nil
end

function M.prepare(context)
  local err = platform_error(context)
  if err then
    return false, err
  end

  local snapshot = {
    config_present = context.env.file_exists(context.paths.bridge_netfilter_config_path),
    config_content = context.env.read_file(context.paths.bridge_netfilter_config_path),
    runtime_value = util.trim(context.env.read_file(context.paths.bridge_netfilter_runtime_path) or ""),
  }

  if snapshot.config_content ~= M.BRIDGE_SYSCTL_CONTENT then
    local config_ok, config_error = context_helpers.write_atomic(
      context.env,
      context.paths.bridge_netfilter_config_path,
      M.BRIDGE_SYSCTL_CONTENT
    )
    if not config_ok then
      return false, config_error
    end
  end

  if snapshot.runtime_value ~= "1"
      and not context.env.write_file(context.paths.bridge_netfilter_runtime_path, "1\n") then
    local _, restore_error = restore_config_file(context, snapshot)
    if restore_error then
      return false, "Could not enable bridge iptables processing. " .. restore_error
    end
    return false, "Could not enable bridge iptables processing."
  end

  local ready_error = M.readiness_error(context)
  if ready_error then
    local restore_errors = M.restore(context, snapshot)
    if #restore_errors > 0 then
      return false, ready_error .. " Rollback issues: " .. table.concat(restore_errors, " | ")
    end
    return false, ready_error
  end

  return true, snapshot
end

function M.restore(context, snapshot)
  local errors = {}
  snapshot = snapshot or {}

  local config_ok, config_error = restore_config_file(context, snapshot)
  if not config_ok then
    table.insert(errors, config_error)
  end

  local runtime_value = tostring(snapshot.runtime_value or "0")
  if runtime_value ~= "1" then
    runtime_value = "0"
  end
  if not context.env.write_file(context.paths.bridge_netfilter_runtime_path, runtime_value .. "\n") then
    table.insert(errors, "Could not restore bridge iptables processing.")
  end

  return errors
end

return M
