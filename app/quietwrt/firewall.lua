local context_helpers = require("quietwrt.context")
local platform = require("quietwrt.platform")
local schema = require("quietwrt.schema")
local util = require("quietwrt.util")

local M = {}

M.RUNTIME_MANAGED_CHECK_COMMAND = "iptables-save 2>/dev/null | grep -E 'QuietWrt-(Intercept-DNS|Deny-DoT|Internet-Curfew)'"
M.NAMES = {
  dns = "QuietWrt-Intercept-DNS",
  dot = "QuietWrt-Deny-DoT",
  curfew = "QuietWrt-Internet-Curfew",
}

local function uci_unquote(value)
  local text = util.trim(value)
  if text:sub(1, 1) == "'" and text:sub(-1) == "'" then
    return (text:sub(2, -2):gsub("'\\''", "'"))
  end

  return text
end

local function capture_section(context, section_name)
  local output = context.env.capture("uci -q show firewall." .. section_name)
  if output == nil or output == "" then
    return nil
  end

  local snapshot = {}
  for _, line in ipairs(util.split_lines(output)) do
    local section_type = line:match("^firewall%." .. section_name .. "=([^%s]+)$")
    if section_type then
      snapshot._type = uci_unquote(section_type)
    else
      local option_name, option_value = line:match("^firewall%." .. section_name .. "%.([%w_]+)=(.+)$")
      if option_name then
        snapshot[option_name] = uci_unquote(option_value)
      end
    end
  end

  if snapshot._type == nil then
    return nil
  end

  return snapshot
end

local function build_commands(snapshot, paths)
  local commands = {}

  for _, section_name in ipairs(schema.MANAGED_FIREWALL_SECTIONS) do
    table.insert(commands, "uci -q delete firewall." .. section_name .. " >/dev/null 2>&1 || true")
  end

  for _, section_name in ipairs(schema.MANAGED_FIREWALL_SECTIONS) do
    local section = snapshot[section_name]
    if section ~= nil then
      table.insert(commands, "uci set firewall." .. section_name .. "='" .. tostring(section._type) .. "'")

      local option_names = {}
      for option_name, _ in pairs(section) do
        if option_name ~= "_type" then
          table.insert(option_names, option_name)
        end
      end
      table.sort(option_names)

      for _, option_name in ipairs(option_names) do
        table.insert(
          commands,
          "uci set firewall." .. section_name .. "." .. option_name .. "='" .. tostring(section[option_name]) .. "'"
        )
      end
    end
  end

  table.insert(commands, "uci commit firewall")
  table.insert(commands, paths.restart_firewall_command)
  return commands
end

function M.hardening_status(context)
  local dns_name = context.env.capture("uci -q get firewall.quietwrt_dns_int.name")
  local dns_extra = context.env.capture("uci -q get firewall.quietwrt_dns_int.extra")
  local dns_dport = context.env.capture("uci -q get firewall.quietwrt_dns_int.dest_port")
  local dot_name = context.env.capture("uci -q get firewall.quietwrt_dot_fwd.name")
  local dot_extra = context.env.capture("uci -q get firewall.quietwrt_dot_fwd.extra")
  local overnight_name = context.env.capture("uci -q get firewall.quietwrt_curfew.name")
  local curfew_extra = context.env.capture("uci -q get firewall.quietwrt_curfew.extra")

  local wired_dns = dns_name == "QuietWrt-Intercept-DNS"
    and dns_extra == platform.DNS_EXTRA
    and dns_dport == "3053"
  local wired_dot = dot_name == "QuietWrt-Deny-DoT"
    and dot_extra == platform.DOT_EXTRA
  local wired_curfew = overnight_name == "QuietWrt-Internet-Curfew"
    and curfew_extra == platform.CURFEW_EXTRA

  return {
    dns_intercept = wired_dns,
    dot_block = wired_dot,
    overnight_rule = overnight_name ~= nil and overnight_name ~= "",
    wired_curfew = wired_curfew,
    bridge_netfilter = platform.is_ready(context),
  }
end

function M.capture_snapshot(context)
  local snapshot = {}

  for _, section_name in ipairs(schema.MANAGED_FIREWALL_SECTIONS) do
    snapshot[section_name] = capture_section(context, section_name)
  end

  return snapshot
end

function M.desired_snapshot(curfew_enabled)
  local value = curfew_enabled and "1" or "0"
  return {
    quietwrt_dns_int = {
      _type = "redirect",
      dest_port = "3053",
      extra = platform.DNS_EXTRA,
      family = "ipv4",
      name = "QuietWrt-Intercept-DNS",
      proto = "tcp udp",
      src = "lan",
      src_dport = "53",
      target = "DNAT",
    },
    quietwrt_dot_fwd = {
      _type = "rule",
      dest = "wan",
      dest_port = "853",
      extra = platform.DOT_EXTRA,
      family = "ipv4",
      name = "QuietWrt-Deny-DoT",
      proto = "tcp udp",
      src = "lan",
      target = "REJECT",
    },
    quietwrt_curfew = {
      _type = "rule",
      dest = "wan",
      enabled = value,
      extra = platform.CURFEW_EXTRA,
      family = "ipv4",
      name = "QuietWrt-Internet-Curfew",
      proto = "all",
      src = "lan",
      target = "REJECT",
    },
  }
end

function M.snapshots_equal(left, right)
  return util.json_encode(left or {}) == util.json_encode(right or {})
end

function M.commit_snapshot(context, snapshot)
  local ok, failed_command = context_helpers.run_commands(context.env, build_commands(snapshot, context.paths))
  if ok then
    return true, nil
  end

  return false, "Firewall update failed while running: " .. failed_command
end

local function runtime_output(context)
  return context.env.capture(M.RUNTIME_MANAGED_CHECK_COMMAND) or ""
end

function M.runtime_matches_snapshot(context, snapshot)
  snapshot = snapshot or {}
  local output = runtime_output(context)
  local lines_by_name = {}
  for _, name in pairs(M.NAMES) do
    lines_by_name[name] = {}
  end
  for _, line in ipairs(util.split_lines(output)) do
    for _, name in pairs(M.NAMES) do
      if line:find(name, 1, true) then
        table.insert(lines_by_name[name], line)
      end
    end
  end

  local function require_lines(name, expected, validator)
    local lines = lines_by_name[name]
    if expected ~= (#lines > 0) then
      return false
    end
    if expected then
      for _, line in ipairs(lines) do
        if not validator(line) then
          return false
        end
      end
    end
    return true
  end

  local wired_match = "--physdev-in " .. platform.LAN_DEVICE
  if not require_lines(M.NAMES.dns, snapshot.quietwrt_dns_int ~= nil, function(line)
    return line:find(wired_match, 1, true) ~= nil
      and line:find("--dport 53", 1, true) ~= nil
      and line:find("-j REDIRECT", 1, true) ~= nil
      and line:find("--to-ports 3053", 1, true) ~= nil
  end) then
    return false
  end

  if not require_lines(M.NAMES.dot, snapshot.quietwrt_dot_fwd ~= nil, function(line)
    return line:find(wired_match, 1, true) ~= nil
      and line:find("--physdev-is-bridged", 1, true) ~= nil
      and line:find("853", 1, true) ~= nil
      and line:upper():find("REJECT", 1, true) ~= nil
  end) then
    return false
  end

  local curfew_expected = snapshot.quietwrt_curfew ~= nil
    and tostring(snapshot.quietwrt_curfew.enabled or "1") ~= "0"
  if not require_lines(M.NAMES.curfew, curfew_expected, function(line)
    return line:find(wired_match, 1, true) ~= nil
      and line:find("--physdev-is-bridged", 1, true) ~= nil
      and line:upper():find("REJECT", 1, true) ~= nil
  end) then
    return false
  end

  return true
end

function M.runtime_managed_present(context)
  local output = runtime_output(context)
  return util.trim(output) ~= ""
end

function M.clear_managed(context)
  local current = M.capture_snapshot(context)
  if M.snapshots_equal(current, {}) and not M.runtime_managed_present(context) then
    return true, nil, false
  end

  local ok, err = M.commit_snapshot(context, {})
  if not ok then
    return false, err, false
  end

  return true, nil, true
end

return M
