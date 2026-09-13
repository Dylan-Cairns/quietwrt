local context_helpers = require("quietwrt.context")
local util = require("quietwrt.util")

local M = {}

local function normalized(value)
  return util.trim(value or "")
end

local function snapshots_equal(left, right)
  left = left or {}
  right = right or {}
  return normalized(left.server) == normalized(right.server)
    and normalized(left.noresolv) == normalized(right.noresolv)
end

local function has_adguard_forwarder(server)
  for item in normalized(server):gmatch("%S+") do
    if item == "127.0.0.1#3053" then
      return true
    end
  end
  return false
end

function M.readiness_error(context)
  local server = context.env.capture("uci -q get dhcp.@dnsmasq[0].server") or ""
  if has_adguard_forwarder(server) then
    return "Dnsmasq is forwarding queries to AdGuard Home (port 3053). Wi-Fi DNS cannot be unfiltered."
  end

  local noresolv = util.trim(context.env.capture("uci -q get dhcp.@dnsmasq[0].noresolv") or "")
  if noresolv ~= "0" then
    return "Dnsmasq noresolv must be set to 0 for direct WAN resolution."
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

function M.capture_snapshot(context)
  return {
    server = context.env.capture("uci -q get dhcp.@dnsmasq[0].server"),
    noresolv = context.env.capture("uci -q get dhcp.@dnsmasq[0].noresolv"),
  }
end

function M.apply_unfiltered_dnsmasq(context)
  if M.is_ready(context) then
    return true, nil, false
  end

  local snapshot = M.capture_snapshot(context)

  local commands = {
    "uci -q delete dhcp.@dnsmasq[0].server >/dev/null 2>&1 || true",
    "uci set dhcp.@dnsmasq[0].noresolv='0'",
    "uci commit dhcp",
    context.paths.restart_dnsmasq_command,
  }

  local ok, failed_command = context_helpers.run_commands(context.env, commands)
  if not ok then
    local restored, restore_error = M.restore_snapshot(context, snapshot)
    local message = "Dnsmasq update failed while running: " .. failed_command
    if restored then
      return false, message .. ". The previous dnsmasq state was restored.", false
    end
    return false, message .. ". Rollback issue: " .. restore_error, true
  end

  local ready_err = M.readiness_error(context)
  if ready_err then
    local restored, restore_error = M.restore_snapshot(context, snapshot)
    if restored then
      return false, ready_err .. " The previous dnsmasq state was restored.", false
    end
    return false, ready_err .. " Rollback issue: " .. restore_error, true
  end

  return true, nil, true
end

function M.restore_snapshot(context, snapshot)
  if snapshot == nil then
    return true, nil
  end

  local commands = {
    "uci -q delete dhcp.@dnsmasq[0].server >/dev/null 2>&1 || true",
  }

  if snapshot.server ~= nil and util.trim(snapshot.server) ~= "" then
    for item in snapshot.server:gmatch("%S+") do
      table.insert(commands, "uci add_list dhcp.@dnsmasq[0].server='" .. item .. "'")
    end
  end

  if snapshot.noresolv ~= nil and util.trim(snapshot.noresolv) ~= "" then
    table.insert(commands, "uci set dhcp.@dnsmasq[0].noresolv='" .. util.trim(snapshot.noresolv) .. "'")
  else
    table.insert(commands, "uci -q delete dhcp.@dnsmasq[0].noresolv >/dev/null 2>&1 || true")
  end

  table.insert(commands, "uci commit dhcp")
  table.insert(commands, context.paths.restart_dnsmasq_command)

  local ok, failed_command = context_helpers.run_commands(context.env, commands)
  if not ok then
    return false, "Dnsmasq restore failed while running: " .. failed_command
  end

  if not snapshots_equal(M.capture_snapshot(context), snapshot) then
    return false, "Dnsmasq restore completed, but the restored UCI state did not match the snapshot."
  end

  return true, nil
end

return M
