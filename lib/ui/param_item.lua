local ParamItem = {}

-- Builds a page item. COPIES `opts` rather than mutating it: this used to hand
-- back the very table it was given, so passing one shared opts table to several
-- item() calls aliased them into a single item (every cell showed the last id).
-- Copying makes a shared "spec" table safe to reuse across items.
function ParamItem.item(param_id, short, opts)
  local item = {}
  for k, v in pairs(opts or {}) do
    item[k] = v
  end
  item.id = param_id
  item.short = short
  item.lock_id = item.lock_id or param_id
  return item
end

function ParamItem.blank()
  return {blank = true, short = "---", lockable = false}
end

return ParamItem
