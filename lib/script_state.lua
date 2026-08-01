local ScriptState = {}
ScriptState.__index = ScriptState

function ScriptState.parent_folder(path)
  if path == nil or path == "" or path == "-" or path:sub(-1) == "/" then
    return nil
  end
  return path:match("^(.*[/\\])[^/\\]+$")
end

function ScriptState.normalize_folder(path)
  if path == nil or path == "" then
    return nil
  end
  if path:sub(-1) ~= "/" then
    return path .. "/"
  end
  return path
end

function ScriptState.folder_starts_with(folder, root)
  return folder ~= nil and root ~= nil and folder:sub(1, #root) == root
end

function ScriptState.new(opts)
  opts = opts or {}
  return setmetatable({
    id = opts.id,
    elasticat = opts.elasticat,
    browser_state_file = nil,
    last_sample_folder = nil
  }, ScriptState)
end

function ScriptState:state_file()
  self.browser_state_file = self.browser_state_file or (_path.data .. "elasticat/browser_state.data")
  return self.browser_state_file
end

function ScriptState:read_state()
  local data = tab.load(self:state_file())
  if type(data) == "table" then
    return data
  end
  return {}
end

function ScriptState:write_state(data)
  util.make_dir(_path.data .. "elasticat/")
  tab.save(data or {}, self:state_file())
end

function ScriptState:patch_state(values)
  local data = self:read_state()
  for key, value in pairs(values or {}) do
    data[key] = value
  end
  self:write_state(data)
end

function ScriptState:save_browser_folder(folder)
  folder = ScriptState.normalize_folder(folder)
  if folder == nil then
    return
  end

  self.last_sample_folder = folder
  self:patch_state({sample_folder = folder})
  print("elasticat: sample browser folder " .. folder)
end

function ScriptState:save_sample_pool_state(snapshot)
  self:patch_state({
    sample_pool = snapshot or (self.elasticat.pool_snapshot ~= nil and self.elasticat.pool_snapshot() or {}),
    sample_slot = self.elasticat.active_pool_slot ~= nil and self.elasticat.active_pool_slot() or 1
  })
end

function ScriptState:load_sample_pool_state()
  local data = self:read_state()
  local slot = data.sample_slot or (params:lookup_param(self.id("sample_slot")) ~= nil and params:get(self.id("sample_slot")) or 1)
  local paths = type(data.sample_pool) == "table" and data.sample_pool or {}
  local has_pool = false
  for _, entry in pairs(paths) do
    local path = type(entry) == "table" and entry.path or entry
    if path ~= nil and path ~= "" and path ~= "-" then
      has_pool = true
      break
    end
  end

  if has_pool and self.elasticat.load_pool_paths ~= nil then
    self.elasticat.load_pool_paths(paths, slot)
    return
  end

  local legacy_path = params:get(self.id("sample"))
  if legacy_path ~= nil and legacy_path ~= "-" and legacy_path ~= "" and legacy_path:sub(-1) ~= "/" then
    if self.elasticat.load_pool_slot ~= nil then
      self.elasticat.load_pool_slot(slot, legacy_path, true)
    end
  elseif self.elasticat.set_pool_slot ~= nil then
    self.elasticat.set_pool_slot(slot)
  end
end

function ScriptState:load_browser_folder()
  local sample_folder = ScriptState.normalize_folder(ScriptState.parent_folder(params:get(self.id("sample"))))
  if sample_folder ~= nil then
    self.last_sample_folder = sample_folder
    return
  end

  local data = self:read_state()
  self.last_sample_folder = ScriptState.normalize_folder(data.sample_folder)
end

function ScriptState:browser_folder()
  return ScriptState.normalize_folder(ScriptState.parent_folder(params:get(self.id("sample")))) or self.last_sample_folder or _path.audio
end

return ScriptState
