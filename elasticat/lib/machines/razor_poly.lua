-- Razor Poly: the razor_slice machine, but POLYPHONIC. Identical arbitrary
-- per-slice start/end points and pages as Razor (4) -- only the voicing differs
-- (no mono steal). Mono/poly is the MACHINE selector now, so Razor (mono) and
-- Razor Poly (poly) share everything but their id/name.
local RazorSlice = include("lib/machines/razor_slice")

local Machine = {}
for key, value in pairs(RazorSlice) do
  Machine[key] = value
end

Machine.id = 6
Machine.name = "razor_poly"

return Machine
