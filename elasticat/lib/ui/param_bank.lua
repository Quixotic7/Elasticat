local ParamBank = {}

function ParamBank.new(items)
  return setmetatable({items = items or {}}, {__index = ParamBank})
end

function ParamBank:pair_count()
  return math.max(1, math.ceil(#self.items / 2))
end

function ParamBank:clamp_group(group)
  return util.clamp(group or 1, 1, self:pair_count())
end

function ParamBank:group_items(group)
  group = self:clamp_group(group)
  local start_index = ((group - 1) * 2) + 1
  return self.items[start_index], self.items[start_index + 1]
end

return ParamBank
