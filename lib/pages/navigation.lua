local PageModel = include("lib/pages/model")
local ParamBank = include("lib/ui/param_bank")

local CATEGORY_ORDER = {"master", "file", "pattern", "trig", "source", "filter", "amp", "fx", "mod"}

local Navigation = {}
Navigation.__index = Navigation

Navigation.CATEGORY_ORDER = CATEGORY_ORDER

-- Owns which category/page/K2-K3 pair/settings-item is currently selected, and
-- the index arithmetic for moving between them. Does not resolve *what items*
-- a page shows (that needs MachineRegistry/WarpRegistry/params, so it stays
-- with the caller-supplied page_items_for callback) -- this module is purely
-- the selection state machine, matching the GridSequencer.new() dependency
-- style already used elsewhere in this script.
function Navigation.new(opts)
  opts = opts or {}
  return setmetatable({
    page_items_for = opts.page_items_for,
    show_message = opts.show_message,
    request_redraw = opts.request_redraw,
    on_navigate = opts.on_navigate or function() end,
    category_index = 1,
    page_index_by_category = {},
    group_index_by_page = {},
    settings_layer = false,
    settings_category_index = 1,
    settings_item_index = {},
    -- Multi-page settings support (PRD §7.3, in-script Project page): which
    -- settings page is showing per category. Only "master" has more than one
    -- today (see lib/pages/model.lua); every other category's settings_pages()
    -- resolves to a single implicit page, so this index just stays at 1 for
    -- them.
    settings_page_index = {}
  }, Navigation)
end

function Navigation:category_position(category)
  for i, name in ipairs(CATEGORY_ORDER) do
    if name == category then
      return i
    end
  end
  return 1
end

function Navigation:category_model(category)
  return PageModel[category or CATEGORY_ORDER[self.category_index]] or PageModel.master
end

function Navigation:current_category()
  return CATEGORY_ORDER[self.category_index] or "master"
end

function Navigation:current_page()
  local category = self:current_category()
  local model = self:category_model(category)
  local pages = model.pages or {}
  local index = util.clamp(self.page_index_by_category[category] or 1, 1, math.max(1, #pages))
  self.page_index_by_category[category] = index
  return pages[index] or {title = model.title, items = {}}, index, model
end

function Navigation:current_page_items()
  local category = self:current_category()
  local page, page_index = self:current_page()
  return self.page_items_for(category, page, page_index)
end

function Navigation:current_pair_count()
  return ParamBank.new(self:current_page_items()):pair_count()
end

function Navigation:current_group_key()
  local _, page_index = self:current_page()
  return self:current_category() .. ":" .. page_index
end

-- Each page remembers its own last-selected K2/K3 parameter pair for the
-- session, so switching pages doesn't reset the pair back to the first one.
-- This is intentionally not a norns param and is not saved with the pset.
function Navigation:clamp_current_group()
  local key = self:current_group_key()
  local clamped = ParamBank.new(self:current_page_items()):clamp_group(self.group_index_by_page[key])
  self.group_index_by_page[key] = clamped
  return clamped
end

function Navigation:current_group_items()
  local group = self:clamp_current_group()
  return ParamBank.new(self:current_page_items()):group_items(group)
end

-- Advance the selected K2/K3 pair by one, SKIPPING pairs whose two items are
-- both blank. The FILTER MIX page (and future Mode-Parameter pages) reserve
-- empty cells between a real param and the trailing mode banner; the owner wants
-- B2/B3 to jump straight between the real params, never parking on dead cells.
-- Called only with delta = +/-1, so stepping one pair at a time is exact. If a
-- page were somehow all-blank the loop completes a full lap and leaves the pair
-- where it started (a safe no-op).
function Navigation:cycle_group(delta)
  local bank = ParamBank.new(self:current_page_items())
  local pair_count = bank:pair_count()
  local key = self:current_group_key()
  local current = self.group_index_by_page[key] or 1
  local step = (delta or 1) >= 0 and 1 or -1
  local next_group = current
  for _ = 1, pair_count do
    next_group = ((next_group - 1 + step) % pair_count) + 1
    local a, b = bank:group_items(next_group)
    if (a ~= nil and not a.blank) or (b ~= nil and not b.blank) then
      break
    end
  end
  self.group_index_by_page[key] = next_group
end

function Navigation:select_category(category)
  self.on_navigate()
  if category == self:current_category() then
    local model = self:category_model(category)
    local pages = model.pages or {}
    self.page_index_by_category[category] = ((self.page_index_by_category[category] or 1) % math.max(1, #pages)) + 1
  else
    self.category_index = self:category_position(category)
  end
  local page = self:current_page()
  self.show_message(page.title or self:category_model(category).title)
  self.request_redraw()
end

function Navigation:select_page_delta(delta)
  self.on_navigate()
  local category = self:current_category()
  local model = self:category_model(category)
  local pages = model.pages or {}
  local count = math.max(1, #pages)
  self.page_index_by_category[category] = (((self.page_index_by_category[category] or 1) - 1 + delta) % count) + 1
  local page = self:current_page()
  self.show_message(page.title or model.title)
  self.request_redraw()
end

function Navigation:select_global_page_delta(delta)
  self.on_navigate()
  local category = self:current_category()
  local model = self:category_model(category)
  local pages = model.pages or {}
  local page_index = self.page_index_by_category[category] or 1

  page_index = page_index + delta
  while page_index < 1 do
    self.category_index = ((self.category_index - 2) % #CATEGORY_ORDER) + 1
    category = self:current_category()
    model = self:category_model(category)
    pages = model.pages or {}
    page_index = math.max(1, #pages)
  end
  while page_index > math.max(1, #pages) do
    self.category_index = (self.category_index % #CATEGORY_ORDER) + 1
    category = self:current_category()
    model = self:category_model(category)
    pages = model.pages or {}
    page_index = 1
  end

  self.page_index_by_category[category] = page_index
  local page = self:current_page()
  self.show_message(page.title or model.title)
  self.request_redraw()
end

function Navigation:current_settings_category()
  return CATEGORY_ORDER[self.settings_category_index] or self:current_category()
end

-- Multi-page settings (PRD §7.3): a category's `settings` field is either a
-- flat list of items (every category except master today -- unchanged shape,
-- unchanged behavior) or a list of {title=?, items=...} pages (master, which
-- gained a second "PROJECT" page). An item table never has an `.items` key,
-- so checking for one on the first entry distinguishes the two shapes without
-- needing every category's model.lua entry to opt in.
function Navigation:settings_pages(category)
  local raw = self:category_model(category).settings or {}
  if #raw > 0 and raw[1].items ~= nil then
    return raw
  end
  return {{items = raw}}
end

function Navigation:settings_page_count(category)
  return math.max(1, #self:settings_pages(category))
end

function Navigation:current_settings_page_index()
  local category = self:current_settings_category()
  local count = self:settings_page_count(category)
  local index = util.clamp(self.settings_page_index[category] or 1, 1, count)
  self.settings_page_index[category] = index
  return index
end

function Navigation:current_settings_page()
  local category = self:current_settings_category()
  local pages = self:settings_pages(category)
  return pages[self:current_settings_page_index()] or {items = {}}
end

function Navigation:settings_items()
  return self:current_settings_page().items or {}
end

function Navigation:open_param_settings(category)
  self.on_navigate()
  self.settings_layer = true
  local position = self:category_position(category or self:current_category())
  self.category_index = position
  self.settings_category_index = position
  local settings_category = self:current_settings_category()
  self.settings_item_index[settings_category] = self.settings_item_index[settings_category] or 1
  self.settings_page_index[settings_category] = self.settings_page_index[settings_category] or 1
  self.show_message(self:category_model(settings_category).title .. " SETTINGS")
  self.request_redraw()
end

function Navigation:close_param_settings()
  self.on_navigate()
  self.settings_layer = false
  self.show_message((self:current_page()).title)
  self.request_redraw()
end

function Navigation:return_to_param_category(category)
  self.on_navigate()
  self.settings_layer = false
  self.category_index = self:category_position(category or self:current_category())
  self.settings_category_index = self.category_index
  local page = self:current_page()
  self.show_message(page.title or self:category_model(self:current_category()).title)
  self.request_redraw()
end

-- Scrolling the item cursor past the last item of the current settings page
-- advances to the first item of the next settings page; scrolling before the
-- first item goes back to the last item of the previous page (wrapping
-- circularly). This is the ONLY page-advance mechanism (PRD §7.3's "scroll to
-- last setting, auto-advance") and every input path that already calls this
-- function gets it for free: the K2/K3 screen keys and E2 encoder
-- (elasticat.lua's key(n,z)/enc(n,d)) and the grid's up/down arrow buttons
-- (grid_sequencer.lua's param_settings_select_delta wiring) -- none of those
-- call sites need to change. Categories with only one settings page (i.e.
-- every category except master) see settings_page_count() == 1, so this is a
-- no-op change for them: behavior clamps exactly as before.
-- Category-key page cycling: advance to the next settings page (wrapping),
-- landing on its first item -- the same repeat-press gesture as cycling a
-- category's main pages. No-op for single-page settings categories.
function Navigation:settings_page_cycle(category)
  category = category or self:current_settings_category()
  local count = self:settings_page_count(category)
  if count < 2 then
    return
  end
  local index = (self:current_settings_page_index() % count) + 1
  self.settings_page_index[category] = index
  self.settings_item_index[category] = 1
  local page = self:settings_pages(category)[index] or {}
  self.show_message((page.title or self:category_model(category).title) .. " SETTINGS")
  self.request_redraw()
end

function Navigation:settings_select_delta(delta)
  local category = self:current_settings_category()
  local items = self:settings_items()
  local count = math.max(1, #items)
  local current = self.settings_item_index[category] or 1
  local target = current + delta
  local page_count = self:settings_page_count(category)

  if page_count > 1 and (target > count or target < 1) then
    local page_index = self:current_settings_page_index()
    if target > count then
      page_index = (page_index % page_count) + 1
      self.settings_page_index[category] = page_index
      self.settings_item_index[category] = 1
    else
      page_index = ((page_index - 2) % page_count) + 1
      self.settings_page_index[category] = page_index
      self.settings_item_index[category] = math.max(1, #self:settings_items())
    end
    self.request_redraw()
    return
  end

  self.settings_item_index[category] = util.clamp(target, 1, count)
  self.request_redraw()
end

function Navigation:settings_category_delta(delta)
  self.settings_category_index = ((self.settings_category_index - 1 + delta) % #CATEGORY_ORDER) + 1
  self.category_index = self.settings_category_index
  local settings_category = self:current_settings_category()
  self.settings_item_index[settings_category] = self.settings_item_index[settings_category] or 1
  self.settings_page_index[settings_category] = self.settings_page_index[settings_category] or 1
  self.show_message(self:category_model(settings_category).title .. " SETTINGS")
  self.request_redraw()
end

-- E1 walks EVERY settings page across ALL categories linearly, so a norns-only
-- user can reach every page (notably master's PROJECT page). It advances the
-- page within the current category; past the last page it rolls into the next
-- category's first page, and before the first into the previous category's
-- last page. (Grid users have the category-key shortcuts instead.)
function Navigation:settings_page_or_category_delta(delta)
  delta = (delta or 0) >= 0 and 1 or -1
  local category = self:current_settings_category()
  local page_count = self:settings_page_count(category)
  local next_page = self:current_settings_page_index() + delta
  if next_page >= 1 and next_page <= page_count then
    self.settings_page_index[category] = next_page
    self.settings_item_index[category] = 1
  else
    self.settings_category_index = ((self.settings_category_index - 1 + delta) % #CATEGORY_ORDER) + 1
    self.category_index = self.settings_category_index
    category = self:current_settings_category()
    self.settings_page_index[category] = delta > 0 and 1 or self:settings_page_count(category)
    self.settings_item_index[category] = 1
  end
  local page = self:current_settings_page()
  self.show_message((page.title or self:category_model(category).title) .. " SETTINGS")
  self.request_redraw()
end

return Navigation
