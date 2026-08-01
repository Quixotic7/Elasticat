local WavReader = {}

local function read_u16_le(bytes, offset)
  local b1, b2 = bytes:byte(offset, offset + 1)
  if b2 == nil then
    return nil
  end
  return b1 + (b2 * 256)
end

local function read_u32_le(bytes, offset)
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  if b4 == nil then
    return nil
  end
  return b1 + (b2 * 256) + (b3 * 65536) + (b4 * 16777216)
end

local function read_wav_sample(bytes, offset, bits_per_sample)
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  if bits_per_sample == 8 and b1 ~= nil then
    return math.abs((b1 - 128) / 128)
  elseif bits_per_sample == 16 and b2 ~= nil then
    local value = b1 + (b2 * 256)
    if value >= 32768 then
      value = value - 65536
    end
    return math.abs(value / 32768)
  elseif bits_per_sample == 24 and b3 ~= nil then
    local value = b1 + (b2 * 256) + (b3 * 65536)
    if value >= 8388608 then
      value = value - 16777216
    end
    return math.abs(value / 8388608)
  elseif bits_per_sample == 32 and b4 ~= nil then
    local value = b1 + (b2 * 256) + (b3 * 65536) + (b4 * 16777216)
    if value >= 2147483648 then
      value = value - 4294967296
    end
    return math.abs(value / 2147483648)
  end
  return 0
end

local function read_f32_le(bytes, offset)
  local raw = read_u32_le(bytes, offset)
  if raw == nil then
    return 0
  end

  local sign = raw >= 0x80000000 and -1 or 1
  local exponent = math.floor(raw / 0x800000) % 0x100
  local mantissa = raw % 0x800000
  if exponent == 0xff then
    return 0
  elseif exponent == 0 then
    return sign * (mantissa / 0x800000) * (2 ^ -126)
  end
  return sign * (1 + (mantissa / 0x800000)) * (2 ^ (exponent - 127))
end

local function read_wav_value(bytes, offset, bits_per_sample, audio_format)
  if audio_format == 3 and bits_per_sample == 32 then
    return math.abs(util.clamp(read_f32_le(bytes, offset), -1, 1))
  end
  return read_wav_sample(bytes, offset, bits_per_sample)
end

-- SIGNED sample value (-1..1) of one channel, for zero-crossing search (where the
-- sign is the whole point, unlike the abs peak the display path wants).
local function read_wav_signed(bytes, offset, bits_per_sample, audio_format)
  if audio_format == 3 and bits_per_sample == 32 then
    return util.clamp(read_f32_le(bytes, offset), -1, 1)
  end
  local b1, b2, b3, b4 = bytes:byte(offset, offset + 3)
  if bits_per_sample == 8 and b1 ~= nil then
    return (b1 - 128) / 128
  elseif bits_per_sample == 16 and b2 ~= nil then
    local v = b1 + (b2 * 256)
    if v >= 32768 then v = v - 65536 end
    return v / 32768
  elseif bits_per_sample == 24 and b3 ~= nil then
    local v = b1 + (b2 * 256) + (b3 * 65536)
    if v >= 8388608 then v = v - 16777216 end
    return v / 8388608
  elseif bits_per_sample == 32 and b4 ~= nil then
    local v = b1 + (b2 * 256) + (b3 * 65536) + (b4 * 16777216)
    if v >= 2147483648 then v = v - 4294967296 end
    return v / 2147483648
  end
  return 0
end

-- Parse the RIFF/WAVE header + fmt/data chunks from an open file handle. Returns
-- a format table with the data-chunk location and frame geometry, or nil for an
-- unsupported file. Shared by the waveform, transient and zero-cross passes.
local function parse_wav_header(file)
  local header = file:read(12)
  if header == nil or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
    return nil
  end
  local audio_format, channels, sample_rate, block_align, bits_per_sample, data_start, data_size
  while true do
    local chunk_header = file:read(8)
    if chunk_header == nil or #chunk_header < 8 then break end
    local chunk_id = chunk_header:sub(1, 4)
    local chunk_size = read_u32_le(chunk_header, 5)
    local chunk_start = file:seek()
    if chunk_size == nil then break end
    if chunk_id == "fmt " then
      local fmt = file:read(math.min(chunk_size, 64))
      if fmt ~= nil and #fmt >= 16 then
        audio_format = read_u16_le(fmt, 1)
        channels = read_u16_le(fmt, 3)
        sample_rate = read_u32_le(fmt, 5)
        block_align = read_u16_le(fmt, 13)
        bits_per_sample = read_u16_le(fmt, 15)
        if audio_format == 65534 and #fmt >= 40 then
          local subformat = read_u16_le(fmt, 25)
          if subformat == 1 or subformat == 3 then audio_format = subformat end
        end
      end
    elseif chunk_id == "data" then
      data_start = chunk_start
      data_size = chunk_size
      break
    end
    file:seek("set", chunk_start + chunk_size + (chunk_size % 2))
  end
  if (audio_format ~= 1 and audio_format ~= 3) or channels == nil or block_align == nil
    or bits_per_sample == nil or data_start == nil or data_size == nil then
    return nil
  end
  local bytes_per_sample = bits_per_sample / 8
  if bytes_per_sample < 1 or bytes_per_sample > 4 then return nil end
  local frame_count = math.floor(data_size / block_align)
  if frame_count <= 0 then return nil end
  return {
    audio_format = audio_format, channels = channels,
    sample_rate = (sample_rate ~= nil and sample_rate > 0) and sample_rate or 44100,
    block_align = block_align, bits_per_sample = bits_per_sample,
    bytes_per_sample = bytes_per_sample, data_start = data_start, frame_count = frame_count
  }
end

function WavReader.fallback_waveform(path, buckets)
  local seed = 0
  path = tostring(path or "")
  for i = 1, #path do
    seed = (seed + (path:byte(i) * i)) % 9973
  end

  local peaks = {}
  for i = 1, buckets do
    local a = math.sin((i + seed) * 0.19)
    local b = math.sin((i * 0.47) + (seed * 0.01))
    peaks[i] = util.clamp(0.18 + (math.abs(a * b) * 0.82), 0.05, 1)
  end
  return peaks
end

function WavReader.read_wav_waveform(path, buckets)
  local file = io.open(path, "rb")
  if file == nil then
    return nil
  end

  local fmt = parse_wav_header(file)
  if fmt == nil then
    file:close()
    return nil
  end
  local audio_format = fmt.audio_format
  local channels = fmt.channels
  local block_align = fmt.block_align
  local bits_per_sample = fmt.bits_per_sample
  local bytes_per_sample = fmt.bytes_per_sample
  local data_start = fmt.data_start
  local frame_count = fmt.frame_count

  local peaks = {}
  for bucket = 1, buckets do
    local start_frame = math.floor(((bucket - 1) / buckets) * frame_count)
    local end_frame = math.max(start_frame, math.floor((bucket / buckets) * frame_count) - 1)
    local span = math.max(1, end_frame - start_frame + 1)
    local reads = math.min(32, span)
    local stride = math.max(1, math.floor(span / reads))
    local peak = 0
    local frame = start_frame

    while frame <= end_frame do
      file:seek("set", data_start + (frame * block_align))
      local frame_bytes = file:read(block_align)
      if frame_bytes == nil or #frame_bytes < block_align then
        break
      end

      for channel = 1, math.min(channels, 2) do
        local offset = 1 + ((channel - 1) * bytes_per_sample)
        if offset + bytes_per_sample - 1 <= #frame_bytes then
          peak = math.max(peak, read_wav_value(frame_bytes, offset, bits_per_sample, audio_format))
        end
      end
      frame = frame + stride
    end

    peaks[bucket] = util.clamp(peak, 0, 1)
  end

  file:close()

  -- Normalize for display: a quiet sample with no loud transients should
  -- still show a readable waveform, not a near-flat line at true scale.
  local max_peak = 0
  for _, value in ipairs(peaks) do
    max_peak = math.max(max_peak, value)
  end
  if max_peak > 0.001 and max_peak < 1 then
    local scale = 1 / max_peak
    for i, value in ipairs(peaks) do
      peaks[i] = util.clamp(value * scale, 0, 1)
    end
  end

  return peaks
end

-- The RAW onset analysis of a sample: a per-window positive energy-rise envelope
-- plus the stats pick_transients needs. Computed once (a full-file traversal) and
-- cached at sample load; the THRESHOLD is applied later by pick_transients, so the
-- on-device sensitivity knob re-picks onsets without re-reading the file. Returns
-- nil for an unreadable/empty file.
function WavReader.read_wav_onsets(path, windows)
  windows = windows or 512
  local file = io.open(path, "rb")
  if file == nil then return nil end
  local fmt = parse_wav_header(file)
  if fmt == nil then file:close(); return nil end

  local energy = {}
  for w = 1, windows do
    local start_frame = math.floor(((w - 1) / windows) * fmt.frame_count)
    local end_frame = math.max(start_frame, math.floor((w / windows) * fmt.frame_count) - 1)
    local span = math.max(1, end_frame - start_frame + 1)
    local reads = math.min(8, span)
    local stride = math.max(1, math.floor(span / reads))
    local sum, n = 0, 0
    local frame = start_frame
    while frame <= end_frame do
      file:seek("set", fmt.data_start + (frame * fmt.block_align))
      local fb = file:read(fmt.block_align)
      if fb == nil or #fb < fmt.block_align then break end
      if fmt.bytes_per_sample <= #fb then
        sum = sum + read_wav_value(fb, 1, fmt.bits_per_sample, fmt.audio_format)
        n = n + 1
      end
      frame = frame + stride
    end
    energy[w] = n > 0 and (sum / n) or 0
  end
  file:close()

  local rise, max_rise, sum_rise = {}, 0, 0
  for w = 1, windows do
    local d = (w > 1) and (energy[w] - energy[w - 1]) or energy[w]
    if d < 0 then d = 0 end
    rise[w] = d
    if d > max_rise then max_rise = d end
    sum_rise = sum_rise + d
  end
  return {
    rise = rise, windows = windows, max_rise = max_rise,
    mean_rise = sum_rise / windows,
    frame_count = fmt.frame_count, sample_rate = fmt.sample_rate
  }
end

-- Peak-pick onset positions (0-128, ascending) from a cached read_wav_onsets
-- result at a given sensitivity (0..1, higher = more onsets). Local maxima of the
-- energy rise above a mean-gated relative threshold, debounced ~30ms. Cheap (one
-- pass over the envelope), so it can run every time the sensitivity knob moves.
function WavReader.pick_transients(onsets, sensitivity)
  if onsets == nil or onsets.max_rise == nil or onsets.max_rise <= 0 then
    return {}
  end
  sensitivity = util.clamp(sensitivity or 0.5, 0, 1)
  local rise = onsets.rise
  local windows = onsets.windows
  -- Higher sensitivity lowers the bar; the mean gate keeps a noisy floor from
  -- registering as onsets.
  local threshold = math.max(onsets.mean_rise * 3,
    onsets.max_rise * (0.05 + (1 - sensitivity) * 0.3))
  local seconds_per_window = (onsets.frame_count / windows) / onsets.sample_rate
  local min_gap = math.max(1, math.ceil(0.03 / math.max(seconds_per_window, 1e-6)))

  local transients, last = {}, -min_gap
  for w = 2, windows - 1 do
    if rise[w] >= threshold and rise[w] >= rise[w - 1] and rise[w] > rise[w + 1]
      and (w - last) >= min_gap then
      transients[#transients + 1] = ((w - 1) / windows) * 128
      last = w
    end
  end
  return transients
end

-- Convenience: read + pick in one call (used by tests / one-shot callers). The
-- coordinator caches read_wav_onsets and calls pick_transients with the live
-- sensitivity instead, so the on-device knob works without re-reading the file.
function WavReader.read_wav_transients(path, opts)
  opts = opts or {}
  return WavReader.pick_transients(
    WavReader.read_wav_onsets(path, opts.windows), opts.sensitivity)
end

-- The 0-128 position of the nearest zero crossing (channel 1) to `pos01`, or
-- pos01 unchanged when the file can't be read or no crossing is within the
-- window. Reads one signed window around the target frame and picks the crossing
-- whose frame is closest to the target. window_seconds caps the search radius.
function WavReader.nearest_zero_cross(path, pos01, window_seconds)
  local file = io.open(path, "rb")
  if file == nil then return pos01 end
  local fmt = parse_wav_header(file)
  if fmt == nil then file:close(); return pos01 end
  local target01 = util.clamp(pos01 or 0, 0, 128) / 128
  local target_frame = math.floor(target01 * fmt.frame_count + 0.5)
  local half = math.max(4, math.floor((window_seconds or 0.01) * fmt.sample_rate))
  local lo = math.max(0, target_frame - half)
  local hi = math.min(fmt.frame_count - 1, target_frame + half)
  file:seek("set", fmt.data_start + (lo * fmt.block_align))
  local block = file:read((hi - lo + 1) * fmt.block_align)
  file:close()
  if block == nil or #block < fmt.block_align then return pos01 end

  local prev_v, prev_frame, best_frame, best_dist
  for i = 0, (hi - lo) do
    local offset = 1 + (i * fmt.block_align)
    if offset + fmt.bytes_per_sample - 1 > #block then break end
    local v = read_wav_signed(block, offset, fmt.bits_per_sample, fmt.audio_format)
    local frame = lo + i
    if prev_v ~= nil and ((prev_v < 0 and v >= 0) or (prev_v >= 0 and v < 0)) then
      -- Crossing between prev_frame and frame; the sub-sample nearer zero wins.
      local cross = (math.abs(v) <= math.abs(prev_v)) and frame or prev_frame
      local dist = math.abs(cross - target_frame)
      if best_dist == nil or dist < best_dist then
        best_frame, best_dist = cross, dist
      end
    end
    prev_v, prev_frame = v, frame
  end
  if best_frame == nil then return pos01 end
  return (best_frame / fmt.frame_count) * 128
end

return WavReader
