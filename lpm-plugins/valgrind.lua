ARGS = common.args(ARGS, {
  ["valgrind"] = "flag"
})

if ARGS["valgrind"] then
  function Bottle:run(args)
    args = args or {}
    if self.is_system then error("system bottle cannot be run") end
    local path = self.local_path .. PATHSEP .. "lite-xl" .. EXECUTABLE_EXTENSION
    if not system.stat(path) then error("cannot find bottle executable " .. path) end
    local line = "valgrind -- " .. path .. (#args > 0 and " " or "") .. table.concat(common.map(args, function(arg)
      return "'" .. arg:gsub("'", "'\"'\"'"):gsub("\\", "\\\\") .. "'"
    end), " ")
    if VERBOSE then log.action("Running " .. line) end
    return os.execute(line)
  end
end
