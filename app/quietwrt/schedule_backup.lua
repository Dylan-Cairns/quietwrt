local schedule = require("quietwrt.schedule")
local schema = require("quietwrt.schema")
local util = require("quietwrt.util")

local M = {}

M.FILE_NAME = "quietwrt-schedules.txt"
M.FORMAT = "quietwrt-schedules"
M.VERSION = "1"

local function expected_keys()
  local keys = {
    format = true,
    version = true,
  }

  for _, definition in ipairs(schema.SCHEDULES) do
    keys[definition.start_key] = true
    keys[definition.end_key] = true
  end

  return keys
end

local function validated_timings(values)
  local timings = {}

  for _, definition in ipairs(schema.SCHEDULES) do
    local start_value = values[definition.start_key]
    local end_value = values[definition.end_key]
    if start_value == nil then
      return nil, "Schedule backup is missing " .. definition.start_key .. "."
    end
    if end_value == nil then
      return nil, "Schedule backup is missing " .. definition.end_key .. "."
    end

    local window, window_error = schedule.build_window(
      definition.name,
      start_value,
      end_value
    )
    if not window then
      return nil, window_error
    end

    timings[definition.start_key] = window.start
    timings[definition.end_key] = window["end"]
  end

  return timings, nil
end

function M.serialize(settings)
  local timings, timing_error = validated_timings(settings or {})
  if not timings then
    return nil, timing_error
  end

  local lines = {
    "format=" .. M.FORMAT,
    "version=" .. M.VERSION,
  }

  for _, definition in ipairs(schema.SCHEDULES) do
    table.insert(lines, definition.start_key .. "=" .. timings[definition.start_key])
    table.insert(lines, definition.end_key .. "=" .. timings[definition.end_key])
  end

  return table.concat(lines, "\n") .. "\n", nil
end

function M.parse(content)
  content = tostring(content or "")
  if util.trim(content) == "" then
    return nil, "Schedule backup is empty."
  end

  local allowed = expected_keys()
  local values = {}
  local line_number = 0

  for raw_line in (content .. "\n"):gmatch("(.-)\n") do
    line_number = line_number + 1
    local line = raw_line:gsub("\r$", "")
    if util.trim(line) ~= "" then
      local key, value = line:match("^([%w_]+)=([^=]*)$")
      if key == nil then
        return nil, "Schedule backup line " .. tostring(line_number) .. " is invalid."
      end
      if allowed[key] ~= true then
        return nil, "Schedule backup contains an unexpected setting: " .. key .. "."
      end
      if values[key] ~= nil then
        return nil, "Schedule backup contains a duplicate setting: " .. key .. "."
      end

      values[key] = util.trim(value)
    end
  end

  if values.format ~= M.FORMAT then
    return nil, "Schedule backup format is missing or unsupported."
  end
  if values.version ~= M.VERSION then
    return nil, "Schedule backup version is missing or unsupported."
  end

  return validated_timings(values)
end

function M.overlay(settings, timings)
  local updated = {}
  for key, value in pairs(settings or {}) do
    updated[key] = value
  end

  for _, definition in ipairs(schema.SCHEDULES) do
    updated[definition.start_key] = timings[definition.start_key]
    updated[definition.end_key] = timings[definition.end_key]
  end

  return updated
end

return M
