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
  local s, e = 1, #all_plugins
  while e ~= s do
    local pivot = math.floor(((e - s) + 1) / 2)
    common.rmrf(plugins)
    common.mkdirp(plugins)
    for i = s, pivot do
      common.copy(backup .. PATHSEP .. all_plugins[i], plugins .. PATHSEP .. all_plugins[i], true, false)
      print("Loading " .. all_plugins[i])
    end
    os.execute(binary)
    local response
    repeat 
      response = io.stdin:read("*line")
      io.stderr:write("Was the error present with this loadout? [y/n]:\n")
    until response == "y" or response == "n"
    if response == "y" then
      e = pivot
    else
      s = pivot + 1
    end
  end
  common.rmrf(plugins)
  common.rename(backup, plugins)
  io.stderr:write("Plugin at fault is " .. all_plugins[s] .. "\n")
  os.exit(0)
end

