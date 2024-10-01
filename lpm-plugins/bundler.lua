ARGS = common.args(ARGS, {
  ["output"] = "string"
})

if ARGS[2] == "bundle" then
  if not ARGS[3]:find("^%d") and ARGS[3] ~= "system" then error("must begin with a lite version") end
  lpm.setup()
  local lite_xl = ARGS[3] == "system" and system_bottle.lite_xl or lpm.get_lite_xl(ARGS[3])
  if not lite_xl.local_path or not system.stat(lite_xl.local_path) or not system.stat(lite_xl.local_path .. PATHSEP .. "src") then error("lite-xl version must contain a src folder") end
  local addons = lpm.retrieve_addons(lite_xl, { select(3, ARGS) })
  
  table.sort(addons, function(a, b) return (a.id .. ":" .. a.version) < (b.id .. ":" .. b.version) end)
  local hash = system.hash(lite_xl.version .. " " .. common.join(" ", common.map(addons, function(p) return (p.repository and p.repository:url() or "") .. ":" .. p.id .. ":" .. p.version end)))
  local path = CACHEDIR .. PATHSEP .. "bundler" .. PATHSEP .. hash
  common.rmrf(path)
  common.copy(lite_xl.local_path, path)
  local bundled_lite_xl = LiteXL.new(nil, { version = lite_xl.version, binary_path = { [ARCH[1]] = path .. PATHSEP .. "lite-xl" }, datadir_path = path .. PATHSEP .. "data", path = path, mod_version = lite_xl.mod_version })
  local bottle = Bottle.new(bundled_lite_xl, addons, nil, true)
  bottle.local_path = path .. PATHSEP .. "data"
  local installing = {}
  for i,addon in ipairs(addons) do
    addon:install(bottle, installing)
  end
  
  local extra_file_c = [[
    extern const char* packaged_files[];
    const char* retrieve_packaged_file(const char* path, size_t* size) {
      if (path[0] != '%') return NULL;
      for (int i = 0; packaged_files[i]; i += 3) {
        if (strcmp(path, packaged_files[i]) == 0) {
          *size = (size_t)(long int)packaged_files[i+2];
          return packaged_files[i+1];
        }
      }
      return NULL;
    }
    
    static int f_packaged_file(lua_State* L) {
      size_t size;
      const char* file = retrieve_packaged_file(luaL_checkstring(L, 1), &size);
      if (!file)
        return 0;
      lua_pushlstring(L, file, size);
      return 1;
    }

    static int f_packaged_dir(lua_State* L) {
      int files = 0;
      size_t path_len;
      const char* path = luaL_checklstring(L, 1, &path_len);
      lua_newtable(L);
      for (int i = 0; packaged_files[i]; i += 3) {
        if (strncmp(path, packaged_files[i], path_len) == 0 && !strstr(&packaged_files[i][path_len+1], "/")) {
          lua_pushstring(L, &packaged_files[i][path_len+1]);
          lua_rawseti(L, -2, ++files);
        }
      }
      return files ? 1 : 0;
    }

    void f_setup_all_in_one(lua_State* L) {
      lua_getglobal(L, "package");
      lua_pushcfunction(L, f_packaged_file);  lua_setfield(L, -2, "file");
      lua_pushcfunction(L, f_packaged_dir);  lua_setfield(L, -2, "dir");
      lua_pop(L, 1);
      if (luaL_dostring(L, "\n\
        MACOS_RESOURCES = '%INTERNAL%'\n\
        local _require = require\n\
        require = function(modname)\n\
          if package.loaded[modname] then return package.loaded[modname] end\n\
          local modpath = modname:gsub('%.', PATHSEP)\n\
          for path in package.path:gsub('%?', modpath):gmatch('[^;]+') do\n\
            local contents = package.file(path)\n\
            if contents then package.loaded[modname] = load(contents, '=' .. path:gsub('%%INTERNAL%%' .. PATHSEP, ''))() return package.loaded[modname] end\n\
          end\n\
          for path in package.cpath:gsub('%?', modpath):gmatch('[^;]+') do\n\
            local contents = package.file(path)\n\
            if contents then\n\
              local path = '/tmp/' .. common.basename(path)\n\
              io.open(path, 'wb'):write(contents):close()\n\
              package.loaded[modname] = system.load_native_plugin(path)()\n\
            end\n\
          end\n\
          return package.loaded[modname] or _require(modname)\n\
        end\n\
        local old_list_dir = system.list_dir\n\
        system.list_dir = function(dir) return package.dir(dir) or old_list_dir(dir) end\n\
        local old_get_file_info = system.get_file_info\n\
        system.get_file_info = function(file)\n\
          local f = package.file(file) return f and { mtime = 0, size = #f, type = 'file' } or old_get_file_info(file)\n\
        end\n\
        local _dofile = dofile\n\
        local _loadfile = loadfile\n\
        loadfile = function(path)\n\
          local f = package.file(path) if f then return load(f, '=' .. path) else return _loadfile(path) end\n\
        end\n\
        dofile = function(str, ...) return loadfile(str)(...) end\n\
        local old_io_open = io.open\n\
        io.open = function(path, mode)\n\
          if type(path) == 'string' and mode:find('r') then\n\
            local f = package.file(path)\n\
            if f then return { _contents = f, lines = function(self) return self._contents:gmatch('([^\\n]*)\\n\\n?') end, close = function() end } end\n\
          end\n\
          return old_io_open(path, mode)\n\
        end\n\
      ") != 0) {
        fprintf(stderr, "internal error when starting bundle: %s\n", lua_tostring(L, -1));
        exit(-1);
      }
    }
  ]]
  local function replace_in_file(file, ...) 
    local replacement, count = common.read(file):gsub(...)
    assert(count > 0, "can't find string to replace in " .. file)
    common.write(file, replacement) 
  end
  replace_in_file(path .. PATHSEP .. "src" .. PATHSEP .. "main.c", "const char %*init_lite_code", "f_setup_all_in_one(L);\n\tconst char *init_lite_code")
  replace_in_file(path .. PATHSEP .. "src" .. PATHSEP .. "renderer.c", 'file = SDL_RWFromFile[^;]+;', "size_t internal_file_size;\n  const char* internal_file = retrieve_packaged_file(path, &internal_file_size);\n  file = internal_file ? SDL_RWFromConstMem(internal_file, internal_file_size) : SDL_RWFromFile(path, \"rb\");\n")
  replace_in_file(path .. PATHSEP .. "src" .. PATHSEP .. "renderer.h", "#endif", "struct lua_State; extern const char* retrieve_packaged_file(const char* path, size_t* size);\nvoid f_setup_all_in_one(struct lua_State* L);\n#endif")
  local f = io.open(path .. PATHSEP .. "src" .. PATHSEP .. "main.c", "ab")
  f:write(extra_file_c, "\nconst char* packaged_files[] = {\n")
  local first = true
  local function write_files(path, original)
    local s = system.stat(path)
    if s.type == "dir" then
      for i, sf in ipairs(system.ls(path)) do
        write_files(path .. PATHSEP .. sf, original or path)
      end
    else
      local contents = io.open(path, "rb"):read("*all")
      if not first then f:write(",") end
      f:write('"', "%INTERNAL%", PATHSEP, path:sub(#original + 2), '","', contents:gsub(".",function(c) return string.format("\\x%02X",string.byte(c)) end), '", (const char*)', #contents, "LL\n")
      first = false
    end
  end
  write_files(path .. PATHSEP .. "data")
  f:write("};")
  f:close()
  
  --os.execute("cd " .. lite_xl.local_path .. "; bash scripts/build.sh -U --forcefallback --portable -b build")
  os.execute("cd " .. bundled_lite_xl.path .. "; bash scripts/build.sh -U --portable -b build")

  common.copy(bundled_lite_xl.local_path .. PATHSEP .. "build" .. PATHSEP .. "lite-xl" .. PATHSEP .. "lite-xl", ARGS["output"] or "lite-xl")
  os.exit(0)
end
