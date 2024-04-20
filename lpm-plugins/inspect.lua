-- inspect plugins; allows easy viewing of plugins and prs
local function is_argument_repo(arg)
  return arg:find("^http") or arg:find("[\\/]") or arg == "."
end

local old_command = lpm.command
function lpm.command(ARGS)
  if ARGS[2] == "inspect" then
    local id = ARGS[3]
    local addons = {}
    local i = 3
    while i <= #ARGS do
      local str = ARGS[i]
      if is_argument_repo(str) then
        table.insert(repositories, 1, Repository.url(str):add(AUTO_PULL_REMOTES))
        system_bottle:invalidate_cache()
        repositories[1].explicit = true
      else
        local id, version = common.split(":", str)
        local potentials = { system_bottle:get_addon(id, version, { mod_version = system_bottle.lite_xl.mod_version }) }
        local uniq = {}
        local found_one = false
        for i, addon in ipairs(potentials) do
          if addon:is_core(system_bottle) then
            uniq[addon.id] = addon
            found_one = true
          elseif not addon:is_orphan(system_bottle) and not uniq[addon.id] then
            table.insert(addons, addon)
            uniq[addon.id] = addon
            found_one = true
          end
          if i > 1 and uniq[addon.id] and uniq[addon.id] ~= addon and addon.repository and addon.repository.explicit then
            log.warning("your explicitly specified repository " .. addon.repository:url() .. " has a version of " .. addon.id .. " lower than that in " .. uniq[addon.id].repository:url() .. " (" .. addon.version .. " vs. " .. uniq[addon.id].version ..
              "; in order to use the one in your specified repo, please specify " .. addon.id .. ":" .. addon.version)
          end
        end
        if not found_one then error("can't find addon " .. str) end
        break
      end
      i = i + 1
    end
    if addons[1]:is_stub() then addons[1]:unstub() end
    if addons[1].url then
      local target = TMPDIR .. PATHSEP .. common.basename(addons[1].url)
      common.get(addons[1].url, { callback = write_progress_bar, target = target, checksum = addons[1].checksum  })
      system_bottle:run({ target })
    elseif system.stat(addons[1].local_path .. PATHSEP .. "init.lua") then
      system_bottle:run({ addons[1].local_path .. PATHSEP .. "init.lua" })
    else
      system_bottle:run({ addons[1].local_path })
    end
    return true
  end
  return old_command(ARGS)
end

