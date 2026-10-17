-- Nugget crafter for the Basin Feeder. Runs on a crafty turtle (normal or advanced, with a crafting table).
-- Connect the turtle to the feeder's wired network: a wired modem on the turtle (or a full wired
-- modem block next to it), right-click the modem. No chests needed, no fuel needed.
-- The feeder puts nuggets straight into the 3x3 grid (slots 1-3, 5-7, 9-11); the turtle crafts them.
-- Ingots go to slot 16, nuggets it could not use go to slot 15; the feeder takes both.

local GRID = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local OUTSIDE = { 4, 8, 12, 13, 14, 15, 16 }
local RESULT, BACK = 16, 15

if not turtle or not turtle.craft then
  printError("This must run on a crafty turtle (turtle with a crafting table).")
  return
end

-- How many grid slots are filled, with which item, smallest stack; "mixed" if types differ
local function gridState()
  local name, min, filled = nil, 64, 0
  for _, s in ipairs(GRID) do
    local d = turtle.getItemDetail(s)
    if d then
      if name and d.name ~= name then return "mixed" end
      name, filled, min = d.name, filled + 1, math.min(min, d.count)
    end
  end
  return filled, name, min
end

local function counts()
  local c = {}
  for s = 1, 16 do c[s] = turtle.getItemCount(s) end
  return c
end

local function same(a, b)
  for s = 1, 16 do
    if a[s] ~= b[s] then return false end
  end
  return true
end

local function outsideEmpty()
  for _, s in ipairs(OUTSIDE) do
    if turtle.getItemCount(s) > 0 then return false end
  end
  return true
end

-- Everything left in the grid goes to BACK (the feeder takes it back)
local function clearGrid()
  for _, g in ipairs(GRID) do
    if turtle.getItemCount(g) > 0 then
      turtle.select(g)
      turtle.transferTo(BACK)
      for _, s in ipairs({ 14, 13, 12, 8, 4 }) do
        if turtle.getItemCount(g) == 0 then break end
        turtle.transferTo(s)
      end
    end
  end
end

local crafted = 0

-- One step. Returns true if something was done.
local function step()
  local filled = gridState()
  if filled == 0 then return false end
  if not outsideEmpty() then return false end -- the feeder has not taken the last result yet

  -- wait until the feeder has finished filling the grid
  local before = counts()
  sleep(1)
  if not same(before, counts()) then return true end

  local name, k
  filled, name, k = gridState()
  if filled ~= 9 then -- mixed items or an incomplete grid: give them back
    clearGrid()
    return true
  end
  turtle.select(RESULT)
  local ok = turtle.craft(k)
  if ok then
    crafted = crafted + turtle.getItemCount(RESULT)
    print(("Crafted %d from %s (total %d)"):format(turtle.getItemCount(RESULT), name, crafted))
  else
    printError("Can't craft " .. name .. ", giving it back")
  end
  clearGrid()
  return true
end

print("Nugget crafter ready. Waiting for nuggets from the feeder...")
while true do
  local ok, did = pcall(step)
  if not ok then
    if did == "Terminated" then error(did, 0) end
    printError(did)
  end
  if not ok or not did then
    local timer = os.startTimer(2)
    repeat
      local event, id = os.pullEvent()
    until event == "turtle_inventory" or (event == "timer" and id == timer)
  end
end
