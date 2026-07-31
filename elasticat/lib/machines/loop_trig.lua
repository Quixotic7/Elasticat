local Machine = include("lib/machines/loop")

local LoopTrig = {}
for key, value in pairs(Machine) do
  LoopTrig[key] = value
end

LoopTrig.id = 2
LoopTrig.name = "loop_trig"

return LoopTrig
