local util = require("quietwrt.util")

local M = {}

M.DNSMASQ_UPSTREAM = "127.0.0.1:53"

local function yaml_unquote(value)
  local text = util.trim(value)
  if text:sub(1, 1) == "'" and text:sub(-1) == "'" then
    return (text:sub(2, -2):gsub("''", "'"))
  end

  if text:sub(1, 1) == '"' and text:sub(-1) == '"' then
    text = text:sub(2, -2)
    text = text:gsub('\\"', '"')
    text = text:gsub("\\\\", "\\")
    return text
  end

  return text
end

local function yaml_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

function M.parse_config(content)
  local lines = util.split_lines(content)
  local rules = {}
  local upstream_dns = {}
  local protection_enabled = nil
  local user_rules_start = nil
  local user_rules_end = nil
  local dns_start = nil
  local dns_end = nil
  local upstream_start = nil
  local upstream_end = nil
  local upstream_indent = nil

  for i, line in ipairs(lines) do
    local enabled_value = line:match("^%s*protection_enabled:%s*(%S+)%s*$")
    if enabled_value ~= nil then
      protection_enabled = (enabled_value == "true")
    end

    if user_rules_start == nil and line:match("^user_rules:%s*$") then
      user_rules_start = i
      user_rules_end = #lines

      for j = i + 1, #lines do
        if lines[j]:match("^[^%s]") then
          user_rules_end = j - 1
          break
        end
      end

      for j = i + 1, user_rules_end do
        local item = lines[j]:match("^%s*-%s*(.-)%s*$")
        if item ~= nil and item ~= "" then
          table.insert(rules, yaml_unquote(item))
        end
      end
    end

    if user_rules_start == nil and line:match("^user_rules:%s*%[%s*%]%s*$") then
      user_rules_start = i
      user_rules_end = i
    end
  end

  for i, line in ipairs(lines) do
    if dns_start == nil and line:match("^dns:%s*$") then
      dns_start = i
      dns_end = #lines
      for j = i + 1, #lines do
        if lines[j]:match("^[^%s]") then
          dns_end = j - 1
          break
        end
      end

      for j = i + 1, dns_end do
        local indent, inline = lines[j]:match("^(%s+)upstream_dns:%s*(.-)%s*$")
        if indent then
          upstream_start = j
          upstream_end = dns_end
          upstream_indent = indent

          if inline ~= "" and inline ~= "[]" then
            local inline_items = inline:match("^%[(.*)%]$")
            if inline_items then
              for item in inline_items:gmatch("[^,]+") do
                table.insert(upstream_dns, yaml_unquote(item))
              end
            else
              table.insert(upstream_dns, yaml_unquote(inline))
            end
          end

          for k = j + 1, dns_end do
            local next_line = lines[k]
            local next_indent = next_line:match("^(%s*)") or ""
            local is_sequence_item = #next_indent == #indent
              and next_line:sub(#indent + 1):match("^%-%s*") ~= nil
            if next_line:match("^%s*$") then
              upstream_end = k
            elseif #next_indent > #indent or is_sequence_item then
              upstream_end = k
              local item = next_line:match("^%s*%-%s*(.-)%s*$")
              if item ~= nil and item ~= "" then
                table.insert(upstream_dns, yaml_unquote(item))
              end
            else
              upstream_end = k - 1
              break
            end
          end
          break
        end
      end
      break
    end
  end

  return {
    lines = lines,
    rules = rules,
    protection_enabled = protection_enabled,
    user_rules_start = user_rules_start,
    user_rules_end = user_rules_end,
    dns_start = dns_start,
    dns_end = dns_end,
    upstream_dns = upstream_dns,
    upstream_start = upstream_start,
    upstream_end = upstream_end,
    upstream_indent = upstream_indent,
  }
end

local function replace_range(lines, first, last, replacement)
  local output = {}
  for i = 1, first - 1 do
    table.insert(output, lines[i])
  end
  for _, line in ipairs(replacement) do
    table.insert(output, line)
  end
  for i = last + 1, #lines do
    table.insert(output, lines[i])
  end
  return output
end

function M.has_dnsmasq_upstream(parsed)
  return parsed ~= nil
    and #parsed.upstream_dns == 1
    and util.trim(parsed.upstream_dns[1]) == M.DNSMASQ_UPSTREAM
end

function M.serialize_config(parsed, rules, upstream)
  local lines = parsed.lines
  if upstream ~= nil then
    local upstream_block
    if parsed.upstream_start then
      local indent = parsed.upstream_indent or "  "
      upstream_block = {
        indent .. "upstream_dns:",
        indent .. "  - " .. yaml_quote(upstream),
      }
      lines = replace_range(lines, parsed.upstream_start, parsed.upstream_end, upstream_block)
    elseif parsed.dns_start then
      upstream_block = {
        "  upstream_dns:",
        "    - " .. yaml_quote(upstream),
      }
      lines = replace_range(lines, parsed.dns_end + 1, parsed.dns_end, upstream_block)
    else
      lines = replace_range(lines, #lines + 1, #lines, {
        "dns:",
        "  upstream_dns:",
        "    - " .. yaml_quote(upstream),
      })
    end

    parsed = M.parse_config(table.concat(lines, "\n") .. "\n")
  end

  local block = { "user_rules:" }
  for _, rule in ipairs(rules or {}) do
    table.insert(block, "  - " .. yaml_quote(rule))
  end

  local output = {}

  if parsed.user_rules_start then
    for i = 1, parsed.user_rules_start - 1 do
      table.insert(output, parsed.lines[i])
    end
    for _, line in ipairs(block) do
      table.insert(output, line)
    end
    for i = parsed.user_rules_end + 1, #parsed.lines do
      table.insert(output, parsed.lines[i])
    end
  else
    for _, line in ipairs(parsed.lines) do
      table.insert(output, line)
    end
    if output[#output] ~= "" then
      table.insert(output, "")
    end
    for _, line in ipairs(block) do
      table.insert(output, line)
    end
  end

  return table.concat(output, "\n") .. "\n"
end

return M
