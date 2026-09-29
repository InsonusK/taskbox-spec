-- TaskBox contract, Redis: the one way every TaskBox script formats a time.
-- Timestamps in a task hash are RFC 3339 UTC with milliseconds, fixed width:
--   YYYY-MM-DDTHH:MM:SS.mmmZ   (e.g. 2026-09-29T10:00:00.123Z)
-- Fixed width + always "Z" make string comparison equal time comparison, so scripts
-- compare run_at / locked_until with iso_now() as plain strings.
-- "Now" is Redis's TIME, never a worker's clock. Paste these functions into every script that needs them.

-- iso_from_ms formats Unix epoch milliseconds (days-from-civil inverse, H. Hinnant).
local function iso_from_ms(ms)
  local secs = math.floor(ms / 1000)
  local milli = ms - secs * 1000
  local days = math.floor(secs / 86400)
  local rem = secs - days * 86400
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return string.format('%04d-%02d-%02dT%02d:%02d:%02d.%03dZ', y, m, d,
    math.floor(rem / 3600), math.floor((rem % 3600) / 60), rem % 60, milli)
end

-- now_ms is Redis's clock in Unix epoch milliseconds (also the score of …:delayed and …:dead).
local function now_ms()
  local t = redis.call('TIME')
  return tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
end

local function iso_now() return iso_from_ms(now_ms()) end
