-- Basin Feeder installer / updater.
--   wget run https://raw.githubusercontent.com/Kapebara07/cc-basin-feeder/main/install.lua
-- On a computer: installs the feeder (basins.lua + startup.lua launcher).
-- On a turtle: installs the nugget crafter as startup.lua.
-- Settings (basins.cfg) are kept. A foreign startup.lua is saved as startup.lua.bak.

local BASE = "https://raw.githubusercontent.com/Kapebara07/cc-basin-feeder/main/"

local function download(path)
  local res, err = http.get(BASE .. path .. "?v=" .. os.epoch("utc"))
  if not res then error("Download failed: " .. path .. " (" .. tostring(err) .. ")", 0) end
  local text = res.readAll()
  res.close()
  return text
end

local function save(name, text)
  local f = fs.open(name, "w")
  f.write(text)
  f.close()
  print("  " .. name .. " (" .. #text .. " bytes)")
end

-- keeps someone else's startup.lua as startup.lua.bak
local function backupStartup(marker)
  if not fs.exists("startup.lua") then return end
  local f = fs.open("startup.lua", "r")
  local old = f.readAll()
  f.close()
  if old:find(marker, 1, true) or old:find("Basin Feeder autostart", 1, true) then return end
  if fs.exists("startup.lua.bak") then fs.delete("startup.lua.bak") end
  fs.copy("startup.lua", "startup.lua.bak")
  print("  old startup.lua saved as startup.lua.bak")
end

if turtle then
  print("Installing the nugget crafter (turtle)...")
  if not turtle.craft then
    printError("Warning: this turtle has no crafting table - it can't craft.")
  end
  local text = download("turtle.lua")
  backupStartup("Nugget crafter")
  save("startup.lua", text)
else
  print("Installing the Basin Feeder (computer)...")
  local feeder, launcher = download("basins.lua"), download("startup.lua")
  save("basins.lua", feeder)
  backupStartup("Autostart: finds the program")
  save("startup.lua", launcher)
end

print("Done. Rebooting in 3 s...")
sleep(3)
os.reboot()
