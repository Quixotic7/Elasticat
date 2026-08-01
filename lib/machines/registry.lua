local Registry = {}

local machines = {
  [1] = include("lib/machines/loop"),
  [2] = include("lib/machines/loop_trig"),
  [3] = include("lib/machines/grid_slice"),
  [4] = include("lib/machines/razor_slice"),
  [5] = include("lib/machines/slice_poly"),
  [6] = include("lib/machines/razor_poly")
}

function Registry.get(machine_id)
  return machines[math.floor((tonumber(machine_id) or 1) + 0.5)] or machines[1]
end

function Registry.source_items(machine_id, Item)
  return Registry.get(machine_id).source_items(Item)
end

function Registry.source_page2_items(machine_id, Item)
  local machine = Registry.get(machine_id)
  return machine.source_page2_items ~= nil and machine.source_page2_items(Item) or nil
end

function Registry.machine_items(machine_id, Item)
  local machine = Registry.get(machine_id)
  return machine.machine_items ~= nil and machine.machine_items(Item) or {}
end

function Registry.is_slice(machine_id)
  return Registry.get(machine_id).is_slice == true
end

return Registry
