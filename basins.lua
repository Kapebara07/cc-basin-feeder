-- Basin Feeder for Create + CC: Tweaked
-- Keeps 16 Create basins supplied with nuggets + gravel (4 basins per nugget type).
-- Nuggets come from the main storage, gravel from the gravel storage.
-- Results go back to the main storage; everything above the limit
-- (default 1000 per item type) is moved to the resource storages:
-- every item type gets its own resource storage (assigned automatically,
-- the first free one). When that storage is full, more items of that type
-- are deleted (pushed into the trash, e.g. a Create chute above lava).
-- Nuggets are not stored: a crafty turtle on the same wired network turns
-- them into ingots (the feeder fills its crafting grid directly, the turtle
-- runs turtle.lua as its startup.lua). Ingots are never kept in the main
-- storage: all of them go to their own resource storage.
-- Crimsite, asurine, veridium and ochrum taken out of the basins go to the
-- stone storage instead (if it is set).
-- Zinc basins also get water from the water tanks.
-- Any monitor attached to the computer (next to it or over a modem) shows the
-- status screen.
--
-- Press START once: the feeder keeps working forever. It survives reboots,
-- server restarts and unloaded chunks (it waits until everything is loaded
-- again). The settings menu can be opened while it works.

local CONFIG_FILE = "basins.cfg"

local TYPES = {
  { id = "minecraft:iron_nugget", label = "Iron nugget" },
  { id = "minecraft:gold_nugget", label = "Gold nugget" },
  { id = "create:copper_nugget",  label = "Copper nugget" },
  { id = "create:zinc_nugget",    label = "Zinc nugget", water = true },
}
local GRAVEL = { id = "minecraft:gravel", label = "Gravel" }
local WATER = "minecraft:water"

-- Taken out of the basins into the stone storage (if set) instead of the main storage
local STONES = {
  { id = "create:crimsite", label = "Crimsite" },
  { id = "create:asurine",  label = "Asurine" },
  { id = "create:veridium", label = "Veridium" },
  { id = "create:ochrum",   label = "Ochrum" },
}
local IS_STONE = {}
for _, s in ipairs(STONES) do IS_STONE[s.id] = true end

local PER_TYPE = 4                       -- basins per nugget type (exactly)
local TOTAL_BASINS = #TYPES * PER_TYPE   -- 16
local INPUT_SLOTS = 9                    -- basin slots 1-9 = input, 10-18 = output

local cfg = {
  running = false,  -- true after START, survives reboots
  basins = {},      -- ordered list of basin peripheral names
  main = nil,       -- main storage: nuggets come from here, results go here
  gravel = nil,     -- gravel storage: gravel comes from here
  stone = nil,      -- stone storage: crimsite/asurine/veridium/ochrum from the basins go here
  overflow = {},    -- resource storages: one item type each
  assign = {},      -- assign[storage name] = item id kept in that resource storage
  trash = {},       -- inventories that delete items (e.g. a chute above lava)
  crafter = nil,    -- crafty turtle on the network (e.g. turtle_0): makes ingots from nuggets
  noCraft = {},     -- noCraft[id] = true: the turtle could not craft this nugget, store it as is
  tanks = {},       -- water tanks: water for the basins of types with water = true
  water = 1000,     -- water (mB) kept in each of those basins
  limit = 1000,     -- max items of one type kept in the main storage
  fill = 64,        -- max items of one type inside a basin (1..64)
  delay = 1,        -- seconds between cycles
  -- text typed into the menu fields
  basinFrom = "create:basin_0",
  basinTo = "create:basin_15",
  overFrom = "",
  overTo = "",
  trashFrom = "",
  trashTo = "",
  tankFrom = "",
  tankTo = "",
}

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------

local function loadConfig()
  if not fs.exists(CONFIG_FILE) then return end
  local f = fs.open(CONFIG_FILE, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  if type(data) == "table" then
    for k, v in pairs(data) do cfg[k] = v end
  end
end

local function saveConfig()
  local f = fs.open(CONFIG_FILE, "w")
  f.write(textutils.serialize(cfg))
  f.close()
end

-- startup.lua makes the computer open this program after every boot
local function installStartup()
  if fs.exists("startup.lua") then return end -- keep an existing launcher
  local f = fs.open("startup.lua", "w")
  f.write(("-- Basin Feeder autostart\nshell.run(%q)\n"):format(shell.getRunningProgram()))
  f.close()
end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function indexOf(list, value)
  for i, v in ipairs(list) do
    if v == value then return i end
  end
end

local function keysOf(map)
  local out = {}
  for k in pairs(map) do out[#out + 1] = k end
  return out
end

local function typeOf(index)
  return TYPES[math.floor((index - 1) / PER_TYPE) + 1]
end

local function isInventory(name)
  if not peripheral.isPresent(name) then return false end
  if peripheral.hasType then return peripheral.hasType(name, "inventory") end
  return peripheral.wrap(name).list ~= nil
end

local function isFluid(name)
  if not peripheral.isPresent(name) then return false end
  if peripheral.hasType then return peripheral.hasType(name, "fluid_storage") end
  return peripheral.wrap(name).tanks ~= nil
end

local function isTurtle(name)
  return peripheral.isPresent(name) and peripheral.getType(name) == "turtle"
end

local function turtleNames()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if isTurtle(name) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

local function fluidNames()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if isFluid(name) and not isInventory(name) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

local function inventoryNames()
  local names = {}
  for _, name in ipairs(peripheral.getNames()) do
    if isInventory(name) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

-- "create:basin_0" "create:basin_10"  ->  create:basin_0 ... create:basin_10
-- "create:basin_0" "10"               ->  same thing (short form)
-- "create:basin_3" ""                 ->  just that one
local function expandRange(first, last)
  if not first or first == "" then return nil, "'From' is empty" end
  if not last or last == "" then return { first } end
  local prefix, a = first:match("^(.-)(%d+)$")
  if not prefix then return nil, "'From' must end with a number" end
  local b
  if last:match("^%d+$") then
    b = last
  else
    local prefix2
    prefix2, b = last:match("^(.-)(%d+)$")
    if prefix2 ~= prefix then return nil, "'From' and 'To' must have the same prefix" end
  end
  a, b = tonumber(a), tonumber(b)
  local out = {}
  for n = a, b, (a <= b) and 1 or -1 do out[#out + 1] = prefix .. n end
  return out
end

local SINGLE_USES = {
  main = "main storage", gravel = "gravel storage", stone = "stone storage",
  crafter = "crafter turtle",
}
local LIST_USES = {
  basins = "basin list", overflow = "resource storage list", tanks = "water tank list", trash = "trash list",
}

-- Where else is this peripheral already used? (except = the slot being set)
-- Main and gravel may be the same inventory.
local function usedElsewhere(name, except)
  for key, label in pairs(SINGLE_USES) do
    local shared = (except == "main" or except == "gravel") and (key == "main" or key == "gravel")
    if key ~= except and not shared and cfg[key] == name then return label end
  end
  for key, label in pairs(LIST_USES) do
    if key ~= except and indexOf(cfg[key], name) then return label end
  end
end

local function addNames(key, first, last, max, check)
  check = check or isInventory
  local list = cfg[key]
  local names, err = expandRange(first, last)
  if not names then return "Error: " .. err end
  local added, skipped, reason = 0, 0, nil
  for _, name in ipairs(names) do
    local why
    local where = usedElsewhere(name, key)
    if max and #list >= max then
      why = "limit of " .. max .. " reached"
    elseif indexOf(list, name) then
      why = "already in the list"
    elseif where then
      why = "used as " .. where
    elseif not check(name) then
      why = "not found"
    end
    if why then
      skipped = skipped + 1
      reason = reason or (name .. " " .. why)
    else
      list[#list + 1] = name
      added = added + 1
    end
  end
  saveConfig()
  local msg = "Added " .. added .. ", total " .. #list .. (max and ("/" .. max) or "")
  if skipped > 0 then msg = msg .. ". Skipped " .. skipped .. ": " .. reason end
  return msg
end

local function removeNames(key, first, last)
  local list = cfg[key]
  local names, err = expandRange(first, last)
  if not names then return "Error: " .. err end
  local removed = 0
  for _, name in ipairs(names) do
    local i = indexOf(list, name)
    if i then
      table.remove(list, i)
      if key == "overflow" then cfg.assign[name] = nil end
      removed = removed + 1
    end
  end
  saveConfig()
  return "Removed " .. removed .. ", total " .. #list
end

local function checkConfig()
  local problems = {}
  if #cfg.basins ~= TOTAL_BASINS then
    problems[#problems + 1] = "need exactly " .. TOTAL_BASINS .. " basins, have " .. #cfg.basins
  end
  for _, name in ipairs(cfg.basins) do
    if not peripheral.isPresent(name) then problems[#problems + 1] = "basin missing: " .. name end
  end
  for _, key in ipairs({ "main", "gravel" }) do
    if not cfg[key] then
      problems[#problems + 1] = key .. " storage is not set"
    elseif not peripheral.isPresent(cfg[key]) then
      problems[#problems + 1] = key .. " storage missing: " .. cfg[key]
    end
  end
  if cfg.stone and not peripheral.isPresent(cfg.stone) then
    problems[#problems + 1] = "stone storage missing: " .. cfg.stone
  end
  for _, name in ipairs(cfg.overflow) do
    if not peripheral.isPresent(name) then problems[#problems + 1] = "resource storage missing: " .. name end
  end
  for _, name in ipairs(cfg.trash) do
    if not peripheral.isPresent(name) then problems[#problems + 1] = "trash missing: " .. name end
  end
  if cfg.crafter and not isTurtle(cfg.crafter) then
    problems[#problems + 1] = "crafter turtle missing: " .. cfg.crafter
  end
  for _, name in ipairs(cfg.tanks) do
    if not peripheral.isPresent(name) then problems[#problems + 1] = "water tank missing: " .. name end
  end
  return problems
end

---------------------------------------------------------------------------
-- Work
---------------------------------------------------------------------------

-- Reads a storage: stock[id] = { {slot, count}, ... }, totals[id] = sum
-- Returns nil if the storage is not loaded / not connected right now
local function snapshot(name)
  local storage = name and peripheral.wrap(name)
  if not storage then return nil end
  local ok, items = pcall(storage.list)
  if not ok or type(items) ~= "table" then return nil end
  local stock, totals = {}, {}
  for slot, it in pairs(items) do
    stock[it.name] = stock[it.name] or {}
    table.insert(stock[it.name], { slot = slot, count = it.count })
    totals[it.name] = (totals[it.name] or 0) + it.count
  end
  return { peripheral = storage, stock = stock, totals = totals }
end

-- Moves up to `need` items of `id` from a storage snapshot into a basin
local function supply(src, basinName, id, need)
  local moved = 0
  for _, s in ipairs(src.stock[id] or {}) do
    if need <= 0 then break end
    if s.count > 0 then
      local take = math.min(need, s.count)
      s.count = s.count - take -- reserve before yielding, other basins run in parallel
      local ok, n = pcall(src.peripheral.pushItems, basinName, s.slot, take)
      n = (ok and n) or 0
      s.count = s.count + (take - n)
      moved, need = moved + n, need - n
      if n < take then break end -- basin does not accept more
    end
  end
  src.totals[id] = (src.totals[id] or 0) - moved
  return moved
end

local function serviceBasin(index, name, main, gravel, stone, stats)
  local itemType = typeOf(index)
  local basin = peripheral.wrap(name)
  local ok, items = pcall(function() return basin.list() end)
  if not itemType or not basin or not ok then
    stats.warn[#stats.warn + 1] = "Basin not loaded: " .. name
    return
  end

  local have = {}
  local toCollect = {}
  for slot, it in pairs(items) do
    if slot > INPUT_SLOTS then
      toCollect[#toCollect + 1] = { slot = slot, id = it.name } -- finished product
    elseif it.name == itemType.id or it.name == GRAVEL.id then
      have[it.name] = (have[it.name] or 0) + it.count
    else
      toCollect[#toCollect + 1] = { slot = slot, id = it.name } -- foreign item in input, take it out
    end
  end

  -- 1. Results (and foreign items) go back to the main storage,
  --    crimsite/asurine/veridium/ochrum to the stone storage if it is set
  for _, c in ipairs(toCollect) do
    local toStone = stone and IS_STONE[c.id]
    local target = toStone and stone or main.peripheral
    local okPull, n = pcall(target.pullItems, name, c.slot)
    if okPull and n and n > 0 then
      if toStone then
        stats.stoned = stats.stoned + n
      else
        stats.collected = stats.collected + n
      end
    else
      stats.warn[#stats.warn + 1] = "Can't empty " .. name ..
        (toStone and " (stone storage full or not loaded?)" or " (main storage full?)")
    end
  end

  -- 2. Top up nuggets (from main) and gravel (from gravel storage), max cfg.fill
  for _, need in ipairs({ { itemType.id, main }, { GRAVEL.id, gravel } }) do
    local id, src = need[1], need[2]
    local missing = cfg.fill - (have[id] or 0)
    if missing > 0 then
      stats.fed = stats.fed + supply(src, name, id, missing)
      if (src.totals[id] or 0) <= 0 then stats.short[id] = true end
    end
  end

  -- 3. Water from the water tanks, up to cfg.water mB in the basin
  if itemType.water then
    if #cfg.tanks == 0 then
      stats.noTanks = true
      return
    end
    local okT, tanks = pcall(basin.tanks)
    local haveWater = 0
    if okT and type(tanks) == "table" then
      for _, t in pairs(tanks) do
        if t.name == WATER then haveWater = haveWater + t.amount end
      end
    end
    local missing = cfg.water - haveWater
    if missing > 0 then
      for _, tank in ipairs(cfg.tanks) do
        if missing <= 0 then break end
        local okP, n = pcall(peripheral.call, tank, "pushFluid", name, missing, WATER)
        n = (okP and n) or 0
        missing = missing - n
        stats.water = stats.water + n
      end
      if missing > 0 then stats.short[WATER] = true end
    end
  end
end

---------------------------------------------------------------------------
-- Resource storages: every item type has its own storage. What does not fit
-- there is deleted. Nuggets go to the crafty turtle and come back as ingots.
---------------------------------------------------------------------------

local function crafterSet()
  return cfg.crafter ~= nil
end

local function isNugget(id)
  return id:match("_nugget$") ~= nil
end

-- Nuggets that go to the turtle instead of a storage
local function craftable(id)
  return crafterSet() and isNugget(id) and not cfg.noCraft[id]
end

-- The resource storage of this item; a free one is assigned on first use:
-- first a free storage that already holds only this item, then an empty one.
-- res[name] = snapshot of every resource storage. Returns nil if none is free.
local function ownStorage(id, res)
  for _, name in ipairs(cfg.overflow) do
    if cfg.assign[name] == id then return name end
  end
  for pass = 1, 2 do
    for _, name in ipairs(cfg.overflow) do
      if not cfg.assign[name] then
        local holdsThis, holdsOther = false, false
        for other in pairs(res[name].totals) do
          if other == id then holdsThis = true else holdsOther = true end
        end
        if not holdsOther and (holdsThis or pass == 2) then
          cfg.assign[name] = id
          saveConfig()
          return name
        end
      end
    end
  end
end

-- Deletes items: pushes them into the trash inventories. Returns how many went.
local function toTrash(src, slot, count, stats)
  local left = count
  for _, t in ipairs(cfg.trash) do
    if left <= 0 then break end
    local ok, n = pcall(src.pushItems, t, slot, left)
    n = (ok and n) or 0
    left = left - n
    stats.trashed = stats.trashed + n
  end
  return count - left
end

-- Moves `count` items of `id` from `slot` of `src` (a peripheral) into the item's
-- own storage; what does not fit is deleted. Returns the number of items handled.
-- Does this resource storage still hold items of other types (= it is being sorted)?
local function hasForeign(name, res)
  local mine = cfg.assign[name]
  for id in pairs(res[name].totals) do
    if id ~= mine then return true end
  end
  return false
end

-- Gives every free resource storage a type: the item it already holds the most of
-- (greedy, the biggest pile first). Nuggets never get a storage.
local function autoAssign(res)
  local taken = {}
  for _, id in pairs(cfg.assign) do taken[id] = true end
  while true do
    local bestName, bestId, best = nil, nil, 0
    for _, name in ipairs(cfg.overflow) do
      if not cfg.assign[name] then
        for id, total in pairs(res[name].totals) do
          if total > best and not taken[id] and not isNugget(id) then
            bestName, bestId, best = name, id, total
          end
        end
      end
    end
    if not bestName then return end
    cfg.assign[bestName] = bestId
    taken[bestId] = true
    saveConfig()
  end
end

-- What does not fit is deleted only when the storage is full of its own item;
-- while it still holds other items (being sorted) nothing is deleted, the rest waits in main.
local function store(src, slot, id, count, res, stats)
  local own = ownStorage(id, res)
  if not own then
    stats.noRoom[id] = true
    return 0
  end
  local ok, n = pcall(src.pushItems, own, slot, count)
  n = (ok and n) or 0
  stats.sorted = stats.sorted + n
  if n < count and not hasForeign(own, res) then
    n = n + toTrash(src, slot, count - n, stats)
    if n < count then stats.full[id] = true end
  end
  return n
end

-- Everything above cfg.limit of one type leaves the main storage
-- (nuggets for the turtle are handled by feedCrafter)
-- Ingots are not kept in main at all: they all go to their resource storage.
-- evicted[id] = items moved out to main only to break a deadlock while sorting (see tidy):
-- they go back to their own storage as soon as it has room, whatever the limit says
local evicted = {}

local function sortMain(main, res, stats)
  for id, total in pairs(main.totals) do
    local back = math.min(evicted[id] or 0, total)
    local excess = math.max(total - (id:match("_ingot$") and 0 or cfg.limit), back)
    if excess > 0 and not isNugget(id) then -- nuggets never go to resource storages
      local done = 0
      for _, s in ipairs(main.stock[id]) do
        if excess <= 0 then break end
        local want = math.min(excess, s.count)
        local n = store(main.peripheral, s.slot, id, want, res, stats)
        excess, done = excess - n, done + n
        if n < want then break end
      end
      if back > 0 then evicted[id] = math.max(0, evicted[id] - done) end
    end
  end
end

-- The turtle is used as an inventory over the network (turtles expose their 16 slots).
-- Grid slots get the nuggets; the turtle crafts, puts the ingots into RESULT_SLOT and
-- nuggets it could not use into BACK_SLOT. Both are taken into the main storage
-- (ingots above the limit are then sorted into their own storage like everything else).
local GRID_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local OUT_SLOTS = { 4, 8, 12, 13, 14 } -- not used by the crafter: anything here is taken out
local RESULT_SLOT, BACK_SLOT = 16, 15
local BATCH_TIMEOUT = 30 -- seconds without an answer: empty the turtle and start over

-- crafter.batch = { id, since } while the turtle works on a batch;
-- crafter.reset = empty the whole turtle first (after a restart)
local crafter = { reset = true }

-- k nuggets of `id` into each grid slot (k <= 64). Returns false if there are fewer than 9.
local function sendToCrafter(src, id, avail, stats)
  local k = math.min(math.floor(avail / 9), 64)
  if k < 1 then return false end
  local moved = 0
  local stock = src.stock[id]
  local i = 1
  for _, g in ipairs(GRID_SLOTS) do
    local need = k
    while need > 0 and stock[i] do
      local s = stock[i]
      if s.count <= 0 then
        i = i + 1
      else
        local ok, n = pcall(src.peripheral.pushItems, cfg.crafter, s.slot, math.min(need, s.count), g)
        n = (ok and n) or 0
        s.count, need, moved = s.count - n, need - n, moved + n
        if n == 0 then i = i + 1 end
      end
    end
  end
  stats.toCrafter = stats.toCrafter + moved
  if moved > 0 then crafter.batch = { id = id, since = os.clock() } end
  return moved > 0
end

-- One batch at a time. Nuggets lying in the resource storages first, then the excess in main.
local function feedCrafter(main, res, stats)
  if not crafterSet() or crafter.batch or crafter.reset then return end
  for _, name in ipairs(cfg.overflow) do
    for id, total in pairs(res[name].totals) do
      if craftable(id) and sendToCrafter(res[name], id, total, stats) then return end
    end
  end
  for id, total in pairs(main.totals) do
    if craftable(id) and sendToCrafter(main, id, total - cfg.limit, stats) then return end
  end
end

local function pullFromTurtle(main, slot)
  local ok, n = pcall(main.peripheral.pullItems, cfg.crafter, slot)
  return (ok and n) or 0
end

-- Takes the ingots and returned nuggets into the main storage. A batch that came back
-- whole (no ingots, 9+ nuggets) = the turtle can't craft that nugget: stored as is from now on.
-- An empty slot of the main storage (by the snapshot), or nil
local function freeSlot(main)
  local ok, size = pcall(main.peripheral.size)
  if not ok or not size then return nil end
  local used = {}
  for _, slots in pairs(main.stock) do
    for _, s in ipairs(slots) do used[s.slot] = true end
  end
  for i = 1, size do
    if not used[i] then return i end
  end
end

-- The ingots: the turtle can't be listed, so they are pulled into an empty slot of the main
-- storage, looked at there and moved on to their own resource storage (deleted if it is full).
local function takeIngots(main, res, stats)
  local slot = freeSlot(main)
  local ok, n = pcall(main.peripheral.pullItems, cfg.crafter, RESULT_SLOT, nil, slot)
  n = (ok and n) or 0
  if n > 0 and slot and res then
    local okD, d = pcall(main.peripheral.getItemDetail, slot)
    if okD and d then store(main.peripheral, slot, d.name, d.count, res, stats) end
  end
  return n
end

local function collectCrafter(main, res, stats)
  if not crafterSet() then return end
  local timedOut = crafter.batch and os.clock() - crafter.batch.since > BATCH_TIMEOUT
  if crafter.reset or timedOut then
    for slot = 1, 16 do pullFromTurtle(main, slot) end
    crafter.reset, crafter.batch = false, nil
    if timedOut then stats.warn[#stats.warn + 1] = "Turtle did not answer - is it running turtle.lua?" end
    return
  end
  for _, slot in ipairs(OUT_SLOTS) do pullFromTurtle(main, slot) end
  local crafted = takeIngots(main, res, stats)
  local returned = pullFromTurtle(main, BACK_SLOT)
  stats.crafted = stats.crafted + crafted
  if crafter.batch and (crafted > 0 or returned > 0) then
    if crafted == 0 and returned >= 9 then
      cfg.noCraft[crafter.batch.id] = true
      saveConfig()
    end
    crafter.batch = nil
  end
end

local TIDY_MOVES = 48 -- stacks moved per cycle while sorting (keeps the basins served)

-- Items lying in the wrong resource storage move to their own one. Items without a storage
-- (and nuggets) go to the main storage. When nothing could move straight home this cycle
-- (storages full of each other's items), some stacks go to the main storage to make room.
-- Never deleted here. Nuggets: 9+ that the turtle can craft wait for it (feedCrafter takes them).
-- stats.sortLeft = stacks still lying in the wrong place.
local function tidy(res, stats)
  local moves, movedHome = 0, 0
  local blocked = {} -- stacks whose own storage had no room
  for _, name in ipairs(cfg.overflow) do
    local snap = res[name]
    for id, slots in pairs(snap.stock) do
      local nuggetWaits = isNugget(id) and craftable(id) and snap.totals[id] >= 9
      if id ~= cfg.assign[name] and not nuggetWaits then
        local own = (not isNugget(id)) and ownStorage(id, res) or nil
        for _, s in ipairs(slots) do
          if moves >= TIDY_MOVES then
            stats.sortLeft = stats.sortLeft + 1
          else
            moves = moves + 1
            local target = (own and own ~= name) and own or cfg.main
            local ok, n = pcall(snap.peripheral.pushItems, target, s.slot)
            n = (ok and n) or 0
            s.count = s.count - n
            if target == own then
              stats.sorted = stats.sorted + n
              movedHome = movedHome + n
            end
            if s.count > 0 then
              stats.sortLeft = stats.sortLeft + 1
              if target == own then blocked[#blocked + 1] = { snap = snap, slot = s.slot, id = id } end
            end
          end
        end
      end
    end
  end
  -- deadlock: everything is full of each other's items -> move some out to main
  if movedHome == 0 and #blocked > 0 then
    local outMoved = 0
    for i = 1, math.min(#blocked, TIDY_MOVES) do
      local b = blocked[i]
      local ok, n = pcall(b.snap.peripheral.pushItems, cfg.main, b.slot)
      n = (ok and n) or 0
      evicted[b.id] = (evicted[b.id] or 0) + n
      outMoved = outMoved + n
    end
    if outMoved == 0 then stats.stuck = true end
  end
end

local function sortResources(main, stats)
  if #cfg.overflow == 0 then return end
  local res = {}
  for _, name in ipairs(cfg.overflow) do
    res[name] = snapshot(name)
    if not res[name] then
      stats.warn[#stats.warn + 1] = "Resource storage not loaded: " .. name .. " (sorting paused)"
      return
    end
  end
  -- a storage that got assigned to nuggets earlier is freed: nuggets are not stored
  for name, id in pairs(cfg.assign) do
    if isNugget(id) then
      cfg.assign[name] = nil
      saveConfig()
    end
  end
  autoAssign(res)
  collectCrafter(main, res, stats)
  feedCrafter(main, res, stats)
  sortMain(main, res, stats)
  tidy(res, stats)
  for id in pairs(cfg.noCraft) do
    stats.warn[#stats.warn + 1] = "Turtle can't craft " .. id .. " (kept in main, see Retry in menu)"
  end
  -- while sorting, "no room" / "full" are expected: only the progress line is shown
  if stats.sortLeft > 0 then
    if stats.stuck then
      stats.warn[#stats.warn + 1] = "Sorting paused: main storage is full (no room to move items out)"
    end
    return
  end
  local noRoom = keysOf(stats.noRoom)
  if #noRoom > 0 then
    stats.warn[#stats.warn + 1] = "No storage left for " .. #noRoom .. " item type(s), kept in main: " ..
      table.concat(noRoom, ", ")
  end
  for id in pairs(stats.full) do
    stats.warn[#stats.warn + 1] = "Storage for " .. id .. " is full - " ..
      (#cfg.trash == 0 and "no trash set, nothing deleted" or "trash busy, retrying")
  end
end

-- Result of the last cycle, shown on the status screen
local last = { cycle = 0 }

local function doCycle()
  local stats = { fed = 0, collected = 0, stoned = 0, water = 0, warn = {}, short = {},
    sorted = 0, trashed = 0, toCrafter = 0, crafted = 0, noRoom = {}, full = {}, sortLeft = 0 }
  local main, gravel = snapshot(cfg.main), snapshot(cfg.gravel)
  if not main or not gravel then
    last.waiting = "Waiting for " .. (main and "gravel" or "main") .. " storage to load: " ..
      tostring(main and cfg.gravel or cfg.main)
    return
  end
  -- Stone storage is optional; if it is set but not loaded, wait like for the others
  -- (otherwise the stones would pile up in the basins).
  local stone = nil
  if cfg.stone then
    stone = peripheral.wrap(cfg.stone)
    local ok = stone and pcall(stone.size)
    if not ok then
      last.waiting = "Waiting for stone storage to load: " .. tostring(cfg.stone)
      return
    end
  end

  local basins = { table.unpack(cfg.basins) } -- copy: the menu may change the list meanwhile
  local tasks = {}
  for i, name in ipairs(basins) do
    tasks[#tasks + 1] = function() serviceBasin(i, name, main, gravel, stone, stats) end
  end
  parallel.waitForAll(table.unpack(tasks))

  -- fresh look after results came back
  main = snapshot(cfg.main) or main
  sortResources(main, stats)

  -- water left in the tanks, for the status screen
  local water = 0
  for _, tank in ipairs(cfg.tanks) do
    local okT, tanks = pcall(peripheral.call, tank, "tanks")
    if okT and type(tanks) == "table" then
      for _, t in pairs(tanks) do
        if t.name == WATER then water = water + t.amount end
      end
    end
  end

  last.waiting = nil
  last.main, last.gravel, last.water, last.stats = main.totals, gravel.totals, water, stats
end

-- Runs forever. While not started it just waits for the START button.
local function workerLoop()
  while true do
    if cfg.running then
      last.cycle = last.cycle + 1
      local ok, err = pcall(doCycle)
      if not ok then
        if err == "Terminated" then error(err, 0) end
        last.waiting = "Error (retrying): " .. tostring(err)
      end
      os.queueEvent("feeder_update")
      sleep(cfg.delay)
    else
      os.pullEvent("feeder_start")
    end
  end
end

---------------------------------------------------------------------------
-- Screen helpers
---------------------------------------------------------------------------

local W, H = term.getSize()
local LABEL_W = 18

local function fg(c) if term.isColour() then term.setTextColour(c) end end
local function bg(c) if term.isColour() then term.setBackgroundColour(c) end end

local function clearScreen()
  bg(colours.black)
  fg(colours.white)
  term.clear()
  term.setCursorPos(1, 1)
end

local function fit(text, width)
  text = tostring(text)
  if #text > width then return text:sub(1, width - 1) .. "~" end
  return text .. (" "):rep(width - #text)
end

local function writeAt(x, y, text, textColour, backColour)
  term.setCursorPos(x, y)
  fg(textColour or colours.white)
  bg(backColour or colours.black)
  term.write(text)
end

-- The status as a list of { text, colour [, back] } lines (terminal and monitors)
local function statusLines()
  local lines = {}
  local function add(text, colour, back) lines[#lines + 1] = { text, colour or colours.white, back } end
  if cfg.running then
    add(" Basin Feeder - WORKING, cycle " .. last.cycle, colours.black, colours.lime)
  else
    add(" Basin Feeder - STOPPED", colours.black, colours.red)
  end
  add("")
  if last.waiting then
    add(last.waiting, colours.orange)
    add("")
  end
  local stats = last.stats
  if stats then
    add("Main storage:")
    for _, t in ipairs(TYPES) do
      local mark = stats.short[t.id] and "  (ran short)" or ""
      add(("  %-14s %6d%s"):format(t.label, last.main[t.id] or 0, mark))
    end
    add("Gravel storage:")
    local mark = stats.short[GRAVEL.id] and "  (ran short)" or ""
    add(("  %-14s %6d%s"):format(GRAVEL.label, last.gravel[GRAVEL.id] or 0, mark))
    if #cfg.tanks > 0 then
      local wmark = stats.short[WATER] and "  (ran short)" or ""
      add(("  %-14s %6d mB%s"):format("Water (tanks)", last.water or 0, wmark))
    end
    add("")
    add(("Fed: %d  Collected: %d"):format(stats.fed, stats.collected))
    if #cfg.overflow > 0 then
      local used = 0
      for _, name in ipairs(cfg.overflow) do
        if cfg.assign[name] then used = used + 1 end
      end
      add(("Resource storages used: %d/%d"):format(used, #cfg.overflow))
      add(("Sorted: %d  Deleted: %d"):format(stats.sorted, stats.trashed))
      if stats.sortLeft > 0 then
        add(("Sorting storages... %d stacks left"):format(stats.sortLeft), colours.yellow)
      end
    end
    if crafterSet() then
      add(("Nuggets to turtle: %d  Crafted: %d"):format(stats.toCrafter, stats.crafted))
    end
    add(("Water to zinc basins: %d mB"):format(stats.water or 0))
    if cfg.stone then
      add(("Stones to stone storage: %d"):format(stats.stoned or 0))
    else
      add("Stone storage: not set (stones go to main)")
    end
    if #cfg.overflow == 0 then add("Resource storages: none (sorting disabled)") end
    if stats.noTanks then add("! No water tanks set (zinc basins need water)", colours.orange) end
    for _, msg in ipairs(stats.warn) do add("! " .. msg, colours.orange) end
  end
  return lines
end

local function drawStatus()
  W, H = term.getSize()
  clearScreen()
  for i, line in ipairs(statusLines()) do
    if i > H - 1 then break end
    writeAt(1, i, fit(line[1], W), line[2], line[3])
  end
  writeAt(1, H, fit("[M] or click = settings (feeder keeps working)", W), colours.lightGrey)
end

-- Draws the status on one monitor, with the largest text size that still fits
local function drawMonitor(mon)
  local lines = statusLines()
  local colour = mon.isColour()
  for _, scale in ipairs({ 1, 0.5 }) do
    mon.setTextScale(scale)
    local _, h = mon.getSize()
    if #lines <= h then break end
  end
  local w, h = mon.getSize()
  if colour then mon.setBackgroundColour(colours.black) end
  mon.clear()
  for i, line in ipairs(lines) do
    if i > h then break end
    mon.setCursorPos(1, i)
    if colour then
      mon.setTextColour(line[2])
      mon.setBackgroundColour(line[3] or colours.black)
    end
    mon.write(fit(line[1], w))
  end
end

-- Shows the status on every attached monitor: after each cycle, when a monitor
-- is attached / removed / resized, and every 2 seconds
local function monitorLoop()
  while true do
    for _, name in ipairs(peripheral.getNames()) do
      if peripheral.getType(name) == "monitor" then
        pcall(drawMonitor, peripheral.wrap(name))
      end
    end
    local timer = os.startTimer(2)
    while true do
      local event, a = os.pullEvent()
      if event == "feeder_update" or event == "peripheral" or event == "peripheral_detach"
          or event == "monitor_resize" or (event == "timer" and a == timer) then
        break
      end
    end
  end
end

-- Status screen: returns when the user wants the settings menu
local function statusScreen()
  while true do
    drawStatus()
    local event, a = os.pullEventRaw()
    if (event == "key" and (a == keys.m or a == keys.enter)) or event == "mouse_click" then
      return
    end
  end
end

---------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------

local function selectable(item) return item.kind ~= "header" end

-- Generic scrolling list. opts: title(), items(), drawRow(item, i, selected, y),
-- onEnter(item, i, y) -> "back" or status text, onDelete(item, i), canLeave, hint
local function listLoop(opts)
  local sel, top, status = 1, 1, opts.status or ""
  while true do
    W, H = term.getSize()
    local items = opts.items()
    local listH = H - 3
    if sel > #items then sel = #items end
    if sel < 1 then sel = 1 end
    while items[sel] and not selectable(items[sel]) and sel < #items do sel = sel + 1 end
    local want = sel
    if items[sel - 1] and not selectable(items[sel - 1]) then want = sel - 1 end
    if want < top then top = want end
    if sel >= top + listH then top = sel - listH + 1 end

    clearScreen()
    writeAt(1, 1, fit(" " .. opts.title(), W), colours.black, colours.yellow)
    for row = 0, listH - 1 do
      local i = top + row
      if items[i] then opts.drawRow(items[i], i, i == sel, row + 2) end
    end
    if #items == 0 then writeAt(2, 3, "(empty)", colours.grey) end
    writeAt(1, H - 1, fit(opts.hint, W), colours.lightGrey)
    writeAt(1, H, fit(status, W), colours.orange)

    local function step(dir)
      local i = sel
      repeat i = i + dir until not items[i] or selectable(items[i])
      if items[i] then sel = i end
    end
    local function activate()
      if not items[sel] then return end
      local res = opts.onEnter(items[sel], sel, sel - top + 2)
      if res == "back" then return true end
      status = res or ""
    end

    local event, a, b, c = os.pullEventRaw()
    if event == "key" then
      status = ""
      if a == keys.up then step(-1)
      elseif a == keys.down then step(1)
      elseif a == keys.pageUp then for _ = 1, listH do step(-1) end
      elseif a == keys.pageDown then for _ = 1, listH do step(1) end
      elseif a == keys.enter or a == keys.numPadEnter then
        if activate() then return end
      elseif a == keys.delete and opts.onDelete and items[sel] then
        status = opts.onDelete(items[sel], sel) or ""
      elseif (a == keys.backspace or a == keys.q) and opts.canLeave then
        return
      end
    elseif event == "mouse_click" then
      local i = top + c - 2
      if c >= 2 and c < 2 + listH and items[i] and selectable(items[i]) then
        sel = i
        status = ""
        if activate() then return end
      end
    elseif event == "mouse_scroll" then
      step(a)
    end
  end
end

-- Tab completion of peripheral names while typing
local function completeNames(text)
  local out = {}
  local all = inventoryNames()
  for _, name in ipairs(fluidNames()) do all[#all + 1] = name end
  for _, name in ipairs(turtleNames()) do all[#all + 1] = name end
  for _, name in ipairs(all) do
    if #name > #text and name:sub(1, #text) == text then out[#out + 1] = name:sub(#text + 1) end
  end
  return out
end

local function editField(item, y)
  writeAt(1, y, fit("> " .. item.label, LABEL_W), colours.yellow)
  writeAt(LABEL_W + 1, y, (" "):rep(W - LABEL_W), colours.white, colours.grey)
  term.setCursorPos(LABEL_W + 1, y)
  term.setCursorBlink(true)
  local value = read(nil, nil, item.complete and completeNames or nil, item.get())
  term.setCursorBlink(false)
  return item.set((value:gsub("^%s+", ""):gsub("%s+$", "")))
end

-- Basin list / resource list etc.: reorder (Enter, Enter) and remove (Delete)
-- extra(i, name) = text shown after the name (or nil)
local function orderPage(key, title, extra)
  local picked
  listLoop({
    canLeave = true,
    hint = "Enter: pick + Enter: swap  Del: remove  Q: back",
    title = function() return title .. " (" .. #cfg[key] .. ")" end,
    items = function()
      local items = {}
      for i, name in ipairs(cfg[key]) do items[i] = { kind = "row", name = name } end
      return items
    end,
    drawRow = function(item, i, selected, y)
      local mark = (i == picked) and "*" or (selected and ">" or " ")
      local text = ("%s%2d %-24s"):format(mark, i, item.name)
      if extra then text = text .. " " .. extra(i, item.name) end
      writeAt(1, y, fit(text, W), (i == picked) and colours.yellow or colours.white,
        selected and colours.grey or colours.black)
    end,
    onEnter = function(_, i)
      if not picked then
        picked = i
        return "Now select the second one and press Enter"
      end
      local list = cfg[key]
      list[picked], list[i] = list[i], list[picked]
      local msg = "Swapped " .. picked .. " and " .. i
      picked = nil
      saveConfig()
      return msg
    end,
    onDelete = function(item, i)
      table.remove(cfg[key], i)
      if key == "overflow" then cfg.assign[item.name] = nil end
      picked = nil
      saveConfig()
      return "Removed " .. item.name
    end,
  })
end

local function networkPage()
  local names = inventoryNames()
  listLoop({
    canLeave = true,
    hint = "Tab completes names while typing.  Q: back",
    title = function() return "Inventories on the network (" .. #names .. ")" end,
    items = function()
      local items = {}
      for i, name in ipairs(names) do
        items[i] = { kind = "row", name = name, where = usedElsewhere(name) }
      end
      return items
    end,
    drawRow = function(item, _, selected, y)
      local text = (selected and ">" or " ") .. item.name
      if item.where then text = fit(text, 30) .. " " .. item.where end
      writeAt(1, y, fit(text, W), item.where and colours.lightBlue or colours.white,
        selected and colours.grey or colours.black)
    end,
    onEnter = function() return "back" end,
  })
end

local function textSetting(key)
  return function(value)
    cfg[key] = value
    saveConfig()
  end
end

local function storageSetting(key)
  local label = SINGLE_USES[key]
  return function(value)
    if value == "" then
      cfg[key] = nil
      saveConfig()
      return label .. " cleared"
    end
    local where = usedElsewhere(value, key)
    if where then return value .. " is already used as " .. where end
    if not isInventory(value) then return value .. " - not found on the network" end
    cfg[key] = value
    saveConfig()
    return label .. " set"
  end
end

local function turtleSetting(value)
  if value == "" then
    cfg.crafter = nil
    saveConfig()
    return "crafter turtle cleared"
  end
  if not isTurtle(value) then
    local found = turtleNames()
    return value .. " - not a turtle on the network" ..
      (#found > 0 and (" (found: " .. table.concat(found, ", ") .. ")") or "")
  end
  cfg.crafter = value
  crafter.reset = true
  saveConfig()
  return "crafter turtle set"
end

local function numberSetting(key, min, max)
  return function(value)
    local n = tonumber(value)
    if not n or n < min or (max and n > max) then
      return "Must be a number " .. min .. (max and (".." .. max) or " or more")
    end
    cfg[key] = n
    saveConfig()
  end
end

local function start()
  local problems = checkConfig()
  if #problems > 0 then
    local more = #problems > 1 and (" (+" .. (#problems - 1) .. " more)") or ""
    return "Can't start: " .. problems[1] .. more
  end
  cfg.running = true
  saveConfig()
  installStartup()
  os.queueEvent("feeder_start")
  return "back"
end

local stopArmed = false
local function stop()
  if not stopArmed then
    stopArmed = true
    return "Press STOP again to really stop the feeder"
  end
  stopArmed = false
  cfg.running = false
  saveConfig()
  return "Feeder stopped. Press START to run it again."
end

local function menuItems()
  local function field(label, get, set, complete)
    return { kind = "field", label = label, get = get, set = set, complete = complete }
  end
  local function button(label, action, colour)
    return { kind = "button", label = label, action = action, colour = colour }
  end
  local items = {
    { kind = "header", label = "BASINS  " .. #cfg.basins .. "/" .. TOTAL_BASINS ..
      "  (each 4 in a row = one nugget type)" },
    field("From", function() return cfg.basinFrom end, textSetting("basinFrom"), true),
    field("To", function() return cfg.basinTo end, textSetting("basinTo"), true),
    button("Add basins From..To", function() return addNames("basins", cfg.basinFrom, cfg.basinTo, TOTAL_BASINS) end),
    button("Remove basins From..To", function() return removeNames("basins", cfg.basinFrom, cfg.basinTo) end),
    button("Basin list / order", function()
      orderPage("basins", "Basin list", function(i) return typeOf(i) and typeOf(i).label or "(extra)" end)
    end),

    { kind = "header", label = "STORAGES" },
    field("Main storage", function() return cfg.main or "" end, storageSetting("main"), true),
    field("Gravel storage", function() return cfg.gravel or "" end, storageSetting("gravel"), true),
    field("Stone storage", function() return cfg.stone or "" end, storageSetting("stone"), true),

    { kind = "header", label = "RESOURCE STORAGES  (each item type gets its own)" },
    field("Storage from", function() return cfg.overFrom end, textSetting("overFrom"), true),
    field("Storage to", function() return cfg.overTo end, textSetting("overTo"), true),
    button("Add storages From..To", function() return addNames("overflow", cfg.overFrom, cfg.overTo) end),
    button("Remove storages From..To", function() return removeNames("overflow", cfg.overFrom, cfg.overTo) end),
    button("Resource storages (" .. #cfg.overflow .. ")", function()
      orderPage("overflow", "Resource storages", function(_, name) return cfg.assign[name] or "(free)" end)
    end),

    { kind = "header", label = "TRASH  (deletes what doesn't fit, e.g. chute above lava)" },
    field("Trash from", function() return cfg.trashFrom end, textSetting("trashFrom"), true),
    field("Trash to", function() return cfg.trashTo end, textSetting("trashTo"), true),
    button("Add trash From..To", function() return addNames("trash", cfg.trashFrom, cfg.trashTo) end),
    button("Remove trash From..To", function() return removeNames("trash", cfg.trashFrom, cfg.trashTo) end),
    button("Trash list (" .. #cfg.trash .. ")", function() orderPage("trash", "Trash", nil) end),

    { kind = "header", label = "NUGGET CRAFTER  (crafty turtle on the network)" },
    field("Crafter turtle", function() return cfg.crafter or "" end, turtleSetting, true),
    button("Retry uncraftable nuggets (" .. #keysOf(cfg.noCraft) .. ")", function()
      cfg.noCraft = {}
      saveConfig()
      return "All nuggets go to the turtle again"
    end),

    { kind = "header", label = "WATER TANKS  (water for the zinc basins)" },
    field("Tank from", function() return cfg.tankFrom end, textSetting("tankFrom"), true),
    field("Tank to", function() return cfg.tankTo end, textSetting("tankTo"), true),
    button("Add tanks From..To", function() return addNames("tanks", cfg.tankFrom, cfg.tankTo, nil, isFluid) end),
    button("Remove tanks From..To", function() return removeNames("tanks", cfg.tankFrom, cfg.tankTo) end),
    button("Tank list (" .. #cfg.tanks .. ")", function() orderPage("tanks", "Water tanks", nil) end),
    field("Water in basin mB", function() return tostring(cfg.water) end, numberSetting("water", 1, 1000)),

    { kind = "header", label = "SETTINGS" },
    field("Limit in main", function() return tostring(cfg.limit) end, numberSetting("limit", 0)),
    field("Max in basin", function() return tostring(cfg.fill) end, numberSetting("fill", 1, 64)),
    field("Delay (sec)", function() return tostring(cfg.delay) end, numberSetting("delay", 0.05, 60)),
    button("Show inventories on network", networkPage),

    { kind = "header", label = "" },
  }
  if cfg.running then
    items[#items + 1] = button("Back to work screen", function() return "back" end, colours.lime)
    items[#items + 1] = button(stopArmed and "STOP - press again to confirm" or "STOP", stop, colours.red)
  else
    items[#items + 1] = button(">> START (runs forever) <<", start, colours.lime)
    items[#items + 1] = button("Exit", function() return "back" end, colours.red)
  end
  return items
end

local function menu()
  stopArmed = false
  listLoop({
    hint = "Up/Down or mouse: select  Enter: edit / press",
    title = function()
      return "Basin Feeder - setup" .. (cfg.running and "   (feeder is WORKING)" or "   (stopped)")
    end,
    items = menuItems,
    drawRow = function(item, _, selected, y)
      local back = selected and colours.grey or colours.black
      local mark = selected and "> " or "  "
      if item.kind == "header" then
        writeAt(1, y, fit(" " .. item.label, W), colours.yellow)
      elseif item.kind == "field" then
        local value = item.get()
        writeAt(1, y, fit(mark .. item.label, LABEL_W), colours.white, back)
        writeAt(LABEL_W + 1, y, fit(value == "" and "-" or value, W - LABEL_W),
          value == "" and colours.grey or colours.lightBlue, back)
      else
        writeAt(1, y, fit(mark .. "[ " .. item.label .. " ]", W), item.colour or colours.cyan, back)
      end
    end,
    onEnter = function(item, _, y)
      if item.kind ~= "field" then stopArmed = stopArmed and item.action == stop end
      if item.kind == "field" then return editField(item, y) end
      return item.action()
    end,
  })
end

-- Screen side: work screen while running, menu otherwise.
-- Returns only when the user presses Exit while the feeder is stopped.
local function uiLoop()
  while true do
    if cfg.running then statusScreen() end
    menu()
    if not cfg.running then return end -- Exit (only shown while stopped)
  end
end

---------------------------------------------------------------------------
-- Main: never dies while the feeder is running
---------------------------------------------------------------------------

loadConfig()
if cfg.running then installStartup() end -- repair autostart if it was deleted

while true do
  local ok, err = pcall(parallel.waitForAny, workerLoop, uiLoop, monitorLoop)
  if ok and not cfg.running then break end              -- Exit pressed while stopped
  if not ok and err == "Terminated" and not cfg.running then break end -- Ctrl+T while stopped
  if not ok and err ~= "Terminated" then
    clearScreen()
    print("Error: " .. tostring(err))
    print("Restarting...")
  end
  pcall(sleep, 1)
end
clearScreen()
