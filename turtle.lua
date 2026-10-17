-- Nugget crafter for the Basin Feeder. Runs on a crafty turtle (turtle + crafting table).
-- Chest ABOVE the turtle = input: the feeder puts nuggets there (one type, a multiple of 9).
-- Chest BELOW the turtle = output: ingots go there, the feeder sorts them.
-- Nuggets that can't be crafted and small leftovers also go down; the feeder handles them.
-- No fuel needed. Both chests must be on the feeder's network (wired modems).

local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }  -- the 3x3 crafting grid
local SPARE = { 4, 8, 12, 13, 14, 15, 16 }    -- the rest: holds the batch while it is laid out

if not turtle or not turtle.craft then
  printError("This must run on a crafty turtle (turtle with a crafting table).")
  return
end

-- Empties the turtle into the output chest. False if the chest is full.
local function dropAllDown()
  for s = 1, 16 do
    if turtle.getItemCount(s) > 0 then
      turtle.select(s)
      if not turtle.dropDown() then return false end
    end
  end
  return true
end

local function countIn(slots)
  local n = 0
  for _, s in ipairs(slots) do n = n + turtle.getItemCount(s) end
  return n
end

-- One batch: take the nuggets, lay them out 3x3, craft, drop the ingots down.
-- Returns false when there was nothing to do.
local function batch()
  if not dropAllDown() then return false end -- output chest full: wait

  turtle.select(1)
  local got = false
  while turtle.suckUp() do got = true end
  if not got then return false end

  -- keep one item type; others go back up for the next batch
  local first
  for s = 1, 16 do
    local d = turtle.getItemDetail(s)
    if d then
      first = first or d.name
      if d.name ~= first then
        turtle.select(s)
        if not turtle.dropUp() then turtle.dropDown() end
      end
    end
  end

  -- move everything out of the grid into the spare slots
  for _, g in ipairs(GRID) do
    for _, s in ipairs(SPARE) do
      if turtle.getItemCount(g) == 0 then break end
      turtle.select(g)
      turtle.transferTo(s)
    end
  end
  -- did not fit (more than 7 stacks): back up
  for _, g in ipairs(GRID) do
    if turtle.getItemCount(g) > 0 then
      turtle.select(g)
      if not turtle.dropUp() then turtle.dropDown() end
    end
  end

  local k = math.min(64, math.floor(countIn(SPARE) / 9))
  if k > 0 then
    -- k nuggets into every grid slot
    for _, g in ipairs(GRID) do
      local need = k
      for _, s in ipairs(SPARE) do
        if need == 0 then break end
        local c = turtle.getItemCount(s)
        if c > 0 then
          local t = math.min(c, need)
          turtle.select(s)
          turtle.transferTo(g, t)
          need = need - t
        end
      end
    end
    -- leftovers (fewer than 9) must not stay outside the grid while crafting
    for _, s in ipairs(SPARE) do
      if turtle.getItemCount(s) > 0 then
        turtle.select(s)
        turtle.dropDown()
      end
    end
    turtle.select(16)
    turtle.craft(k)
  end
  dropAllDown()
  return true
end

print("Nugget crafter: chest above = nuggets in, chest below = ingots out")
while true do
  local ok, did = pcall(batch)
  if not ok then
    if did == "Terminated" then error(did, 0) end
    printError(did)
  end
  if not ok or not did then sleep(1) end
end
