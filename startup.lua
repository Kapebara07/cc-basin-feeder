-- Autostart: finds the program and runs it after every boot.
-- If the program stops or crashes, it is started again in 5 seconds.
-- Hold Ctrl+T during the 5-second pause to get back to the shell.

local NAMES = { "basins.lua", "basins", "disk/basins.lua", "disk/basins" }

local function find()
  for _, name in ipairs(NAMES) do
    if fs.exists(name) and not fs.isDir(name) then return name end
  end
end

while true do
  local program = find()
  if program then
    shell.run(program)
    print("Program stopped. Restart in 5 s (Ctrl+T - cancel)")
  else
    printError("Program not found. Looked for:")
    for _, name in ipairs(NAMES) do print("  " .. name) end
    print("Retry in 5 s (Ctrl+T - cancel)")
  end
  sleep(5)
end
