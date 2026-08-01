-- Slice Poly: the grid_slice machine, but POLYPHONIC. Identical slicing (equal
-- divisions of the trim window) and source/machine pages -- only the voicing
-- differs (no mono steal on a new trig). The mono/poly split is encoded in the
-- MACHINE selector now, so Slice (3, mono) and Slice Poly (5, poly) share
-- everything but their id/name; the coordinator resolves mono from the machine.
local GridSlice = include("lib/machines/grid_slice")

local Machine = {}
for key, value in pairs(GridSlice) do
  Machine[key] = value
end

Machine.id = 5
Machine.name = "slice_poly"

return Machine
