local Step = {}

local function table_count(t)
  local count = 0
  for _, value in pairs(t or {}) do
    if value then
      count = count + 1
    end
  end
  return count
end

function Step.new()
  return {
    trig = false,
    slices = {},
    pitch = nil,
    length = nil,
    velocity = nil,
    param_locks = {}
  }
end

function Step.has_content(record)
  if record == nil then
    return false
  end
  return record.trig == true
    or record.pitch ~= nil
    or record.length ~= nil
    or record.velocity ~= nil
    or table_count(record.param_locks) > 0
    or table_count(record.slices) > 0
end

return Step
