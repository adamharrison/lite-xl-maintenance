-- bisects a portable user folder's plugins to determine where an error is
if #ARGS > 1 and ARGS[2] == "bisect" then
  local prefix = ARGS[3] .. PATHSEP .. "user" .. PATHSEP
  local plugins = prefix .. "plugins"
  local backup = prefix .. ".bisect-plugins"
  local binary = ARGS[3] .. PATHSEP .. "lite-xl"
  assert(system.stat(binary), "can't find lite binary at " .. binary)
  assert(system.stat(plugins), "can't find user plugin directory at " .. plugins)
  -- we're just going to use base filesystem stuff rather than apply; it's more versatile with intermediate configurations
  common.rename(plugins, backup)
  local all_plugins = system.ls(prefix .. ".bisect-plugins")
  local absolute_min, absolute_max = 1, #all_plugins
  local old_absolute_max = absolute_max
  while absolute_max ~= absolute_min do
    local pivot = math.floor(((absolute_max - absolute_min) + 1) / 2) + (absolute_min - 1)
    if pivot == absolute_min then break end
    common.rmrf(plugins)
    common.mkdirp(plugins)
    for i = absolute_min, pivot do
      common.copy(backup .. PATHSEP .. all_plugins[i], plugins .. PATHSEP .. all_plugins[i], true, false)
      io.stderr:write("Loading " .. all_plugins[i] .. "\n")
    end
    io.stderr:flush()
    os.execute(binary .. " " .. (ARGS[4] or ""))
    local response
    repeat 
      io.stderr:write("Was the error present with this loadout? [y/n]:\n")
      io.stderr:flush()
      response = io.stdin:read("*line")
    until response == "y" or response == "n"
    if response == "y" then
      old_absolute_max = absolute_max
      absolute_max = pivot
    else
      absolute_min = pivot + 1
    end
  end
  common.rmrf(plugins)
  common.rename(backup, plugins)
  io.stderr:write("Plugin at fault is " .. all_plugins[absolute_min] .. "\n")
  os.exit(0)
end

