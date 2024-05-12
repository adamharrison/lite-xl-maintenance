-- github extension plugin
-- requires `git` and `gh` installed.

local function run_command(cmd, ...)
  cmd = string.format(cmd, ...)
  if VERBOSE then log.action("Running " .. cmd .. "...") end
  local process = io.popen(cmd)
  local result = process:read("*all")
  local success, signal, code = process:close()
  if not success then error(string.format("command '%s' %s with error code %d: %s", cmd, signal, code, result)) end
  return result
end

local old_repository_url = Repository.url
function Repository.url(url, ...)
  if type(url) == "string" then
    local s, e, owner, repo, pull_id = url:find("https://github.com/([^/]+)/([^/]+)/pull/(%d+)")
    if s then
      local pr = json.decode(run_command("gh pr list -R %s/%s -S %d --json headRepository,headRefName,headRepositoryOwner,number", owner, repo, pull_id))[1]
      if pr then return old_repository_url(string.format("https://github.com/%s/%s.git:%s", pr.headRepositoryOwner.login, pr.headRepository.name, pr.headRefName), ...) end
      error("Can't find pull request" .. url)
    end
  end
 return old_repository_url(url, ...)
end

local function retrieve_owner_project_branch(url)
  return url:match("^(.*[/:]([%w-]+)/([%w-]+)%.?g?i?t?):?([%w-]*)$")
end

local function retrieve_repository_origin(path)
  if not system.stat(path .. PATHSEP .. ".git/config") then return nil end
  return common.read(path .. PATHSEP .. ".git/config"):match("%[remote \"origin\"%]%s+url%s*=%s*(%S+)")
end

-- options.source is the repository:branch containing the plugin in question.
-- options.target is repository:branch we create the PR in.
-- options.staging is a fork of options.target, or exactly equal to options.target
local function create_addon_pr(options, addons)
  local target = options["target"]
  local target_url, target_owner, target_project, target_branch = retrieve_owner_project_branch(target)
  assert(target_url and target_branch and target_owner and target_project, "invalid target " .. target)

  local source = options["source"]
  local source_url, source_owner, source_project, source_branch = retrieve_owner_project_branch(source)
  assert(source_branch, "can't find source branch from" .. source)
  local source_commit = common.is_commit_hash(source_branch) and source_branch or run_command("git ls-remote %s refs/heads/%s", source_url, source_branch):gsub("%s+.*\n$", "")
  local source_manifest = json.decode(common.get(string.format("https://raw.githubusercontent.com/%s/%s/%s/manifest.json", source_owner, source_project, source_commit)))

  local staging = options["staging"]
  local staging_url, staging_owner, staging_project, staging_branch, staging_local
  if system.stat(staging) then
    staging_local = staging
    staging = retrieve_repository_origin(staging) .. ":master"
    staging_url, staging_owner, staging_project, staging_branch = retrieve_owner_project_branch(staging)
    assert(staging_owner and target_project == staging_project, "invalid staging " .. staging)
  else
    staging_url, staging_owner, staging_project, staging_branch = retrieve_owner_project_branch(staging)
    assert(staging_owner and target_project == staging_project, "invalid staging " .. staging)
  end

  local updating_addons = addons or {}
  if #updating_addons > 0 then
    updating_addons = common.map(updating_addons, function(addon)
      addon = assert(common.grep(source_manifest.addons, function(a) return a.id == addon end)[1], "can't find addon " .. addon)
      return addon
    end)
  else
    updating_addons = source_manifest.addons
  end
  local path
  if staging_local then
    path = system.stat(staging_local).abs_path
  else
    path = SYSTMPDIR .. PATHSEP .. "pr"
    common.rmrf(path)
    run_command("git clone --depth=1 %s %s", staging:gsub(":%w+$", ""), path)
    if target ~= staging then
      run_command("cd %s && git remote add upstream %s && git fetch --depth=1 upstream", path, target_url)
      staging_branch = "upstream/" .. (staging_branch ~= "" and staging_branch or "master")
    end
  end

  local name = options.name or (source_owner .. "/" .. source_project)
  local handle = common.handleize(name)
  run_command("cd %s && git checkout -B 'PR/update-manifest-%s' && git reset %s --hard", path, handle, staging_branch)
  local target_manifest = json.decode(common.read(path .. PATHSEP .. "manifest.json"))
  local target_map = {}
  for i,v in ipairs(target_manifest.addons) do target_map[v.id] = i end
  for i,v in ipairs(updating_addons) do
    local entry = {
      id = v.id,
      version = v.version,
      mod_version = v.mod_version,
      remote = string.format("https://github.com/%s/%s.git:%s", source_owner, source_project, source_commit)
    }
    if v.name then entry.name = v.name end
    if v.description then entry.description = v.description end
    if v.tags then entry.tags = v.tags end
    if not common.is_commit_hash(source_branch) and source_branch ~= "latest" then entry.extra = { follow_branch = source_branch } end
    if not target_map[v.id] then
      table.insert(target_manifest.addons, entry)
    elseif options["ignore-version"] or (target_manifest.addons[target_map[v.id]].version ~= entry.version) then
      target_manifest.addons[target_map[v.id]] = common.merge(target_manifest.addons[target_map[v.id]], entry)
    end
  end
  common.write(path .. PATHSEP .. "manifest.json", json.encode(target_manifest, { pretty = true }) .. "\n")
  if not os.execute("cd '" .. path .. "' && git diff --exit-code -s manifest.json") then
    run_command("cd %s && git add manifest.json && git commit -m 'Updated manifest.json.'", path)
    run_command("cd %s && git push -f origin PR/update-manifest-%s", path, handle)
    if not options["no-pr"] then
      local result = json.decode(run_command("gh pr list -R %s/%s -H PR/update-manifest-%s --json id", target_owner, target_project, handle))
      if result and #result == 0 then
        run_command("gh pr create -R %s/%s -H %s:PR/update-manifest-%s -t 'Update %s Version' -b 'Bumping versions of stubs for `%s`.'", target_owner, target_project, staging_owner, handle, name, name)
      end
    end
  else
    log.warning("no change to manifest.json; not creating pr")
    return false
  end
  return true
end



if ARGS[2] == "gh" and ARGS[3] == "create-stubs-pr" then
  ARGS = common.args(ARGS, { target = "string", source = "string", staging = "string", name = "string", ["no-pr"] = "flag" })
  if not ARGS.target then ARGS.target = retrieve_repository_origin(".") .. ":master" end
  assert(ARGS.source, "requires a --source")
  create_addon_pr(ARGS, common.slice(ARGS, 4))
  os.exit(0)
end


-- options.target is the repository we want create our PRs in.
-- options.staging is the repository we want to create our branches in; can be the same as options.target.
-- options.remotes will automatically pull in all entries for a remote, and mark them as stubs.
if ARGS[2] == "gh" and ARGS[3] == 'check-stubs-update-pr' then
  ARGS = common.args(ARGS, { target = "string", staging = "string", name = "string", ["no-pr"] = "flag", ["ignore-version"] = "flag" })
  local target = ARGS["target"] or retrieve_repository_origin(".") .. ":master"
  local staging = ARGS["staging"] or target

  local list = common.slice(ARGS, 4)

  local manifest = json.decode(common.read("manifest.json"))
  local remotes = {}
  local addons = manifest.addons
  for i, remote in ipairs(AUTO_PULL_REMOTES and manifest.remotes or {}) do
    local repo = Repository.url(remote):fetch()
    local url, branch = remote:match("^(.*):(.*)$")
    local manifest = repo:parse_manifest()
    addons = common.concat(addons, common.map(manifest.addons, function(v)
      local hash = {
        remote = url:gsub("%.git$", "") .. ":000000000000000000000000000000000000000",
        id = v.id,
      }
      if branch ~= "latest" then hash.extra = { follow_branch = branch } end
      return hash
    end))
  end
  for i,v in ipairs(manifest.addons) do
    if v.remote then
      if #list == 0 or #common.grep(list, function(e) return e == v.id end) > 0 then
        local repo = v.remote:match("^(.*):[a-f0-9]+$")
        repo = repo:gsub("%.git$", "")
        local following_branch = v.extra and v.extra.follow_branch or "latest"
        if not remotes[repo] then remotes[repo] = {} end
        if not remotes[repo][following_branch] then remotes[repo][following_branch] = {} end
        table.insert(remotes[repo][following_branch], v)
      end
    end
  end
  for remote, branches in pairs(remotes) do
    local branch_list = {}
    for k,v in pairs(branches) do table.insert(branch_list, k) end
    local commits = { common.split("\n", run_command("git ls-remote %s " .. common.join(" ", common.map(branch_list, function(branch) return "refs/heads/" .. branch end)), remote)) }
    for branch, addons in pairs(branches) do
      local commit_line = common.grep(commits, function(c) return c:find(branch .. "$") end)[1]
      if commit_line then
        local commit = commit_line:match("^(%S+)")
        local _, pinned = addons[1].remote:match("^.*:(%s+)$")
        if commit ~= pinned then
          if create_addon_pr({ target = target, staging = staging, source = (remote .. ":" .. commit), ["no-pr"] = ARGS["no-pr"], ["ignore-version"] = ARGS["ignore-version"] }, common.map(addons, function(e) return e.id end)) then
            log.action(string.format("updated stub entry for %s to be pinned at %s based on branch %s", remote, commit, branch))
          end
        else
          log.action(string.format("remote branch %s for %s matches current pinned commit %s", branch, remote, commit))
        end
      else
        log.warning(string.format("can't find remote branch %s for %s", branch, remote))
      end
    end
  end
  os.exit(0)
end

local function pull_version(id)
  local manifest = json.decode(common.read("manifest.json"))
  local addon = manifest.addons and (common.grep(manifest.addons, function(a) return (#manifest.addons == 1 and not id) or a.id == id end)[1])
  if not addon then error("can't find addon to pull version from") end
  local result = run_command('git describe --tags --match "v*"'):gsub("\n", "")
  local version, suffix = result:match("^v([%d%.]+)%-?(.*)$")
  if suffix and addon.version ~= version then return addon.version, true, manifest, addon end
  return result, false, manifest, addon
end

-- Must be performed at the repository root.
if ARGS[2] == "gh" and ARGS[3] == "version" then
  local version, release, manifest = pull_version(ARGS[4])
  print(version)
  os.exit(0)
end

-- Must be performed at the repository root.
-- lpm gh release Linux/*.so MacOS/*.so Windows/*.dll
if ARGS[2] == "gh" and ARGS[3] == "release" then
  ARGS = common.args(ARGS, { discord = "string", notes = "string", addon = "string" })
  local version, release, manifest, addon = pull_version(ARGS.addon)
  local files = common.slice(ARGS, 4)

  local changelog
  if ARGS.notes or (release and system.stat("CHAGNELOG.md")) then
    log.action(string.format("Writing release notes..."))
    if ARGS.notes then
      changelog = ARGS.notes
    else
      changelog = common.read("CHANGELOG.md")
      local vs, ve = changelog:find("^##*%s*" .. version)
      if not vs then error("can't find CHANGELOG entry for " .. version) end
      local ns, ne = changelog:find("^##*", ve + 1)
      changelog = changelog:sub(vs, ns and (ns - 1) or #changelog)
    end
    common.write("/tmp/NOTES.md", changelog)
  else
    log.action(string.format("Publishing no release notes..."))
    common.write("/tmp/NOTES.md", "No notes exist for this release.")
  end

  if #files > 0 and release then
    log.action(string.format("Recomputing checksums for %s...", common.join(", ", files)))
    if not addon.files then error("can't find files entry for manifest") end
    local file_hash = {}
    for i, path in ipairs(files) do file_hash[common.basename(path)] = path end
    for i,v in ipairs(addon.files) do
      if v.checksum and v.checksum ~= "SKIP" then
        local name = common.basename(v.url)
        if file_hash[name] then
          v.checksum = system.hash(file_hash[name], "file")
        else
          log.warning("Didn't supply path to file " .. name .. "; ensure that this is intentional.")
        end
      end
    end
    local contents = json.encode(manifest, { pretty = true }) .. "\n"
    if contents ~= common.read("manifest.json") then
      common.write("manifest.json", json.encode(manifest, { pretty = true }) .. "\n")
      run_command("git add manifest.json && git commit -m 'Updated manifest.json.' && git push")
    end
  end

  log.action(string.format("Creating continuous release..."))
  run_command("git tag -f continuous && git push -f origin refs/tags/continuous")
  run_command("gh release delete -y continuous || true; gh release create -p -t 'Continuous Release' continuous -F /tmp/NOTES.md %s", common.join(" ", files))
  if release then
    log.action(string.format("Creating versioned release..."))
    run_command("git tag -f v" .. version)
    run_command("git tag -f latest")
    run_command("git branch -f latest HEAD")
    run_command("git push -f origin refs/tags/v" .. version .. " refs/heads/latest refs/tags/latest")
    run_command("gh release delete -y v%s || true; gh release create -t v%s v%s -F /tmp/NOTES.md %s", version, version, version, common.join(" ", files))
    run_command("gh release delete -y latest || true; gh release create -t latest latest -F /tmp/NOTES.md %s", common.join(" ", files))
  end
  if release and changelog and ARGS.discord then
    log.action(string.format("Publishing release to discord..."))
    local url = "https://github.com/adamharrison/lite-xl-terminal/releases/tag/v" .. version
    common.write("/tmp/discord", json.encode({ content = "## " .. (addon.name or addon.id) .. " v" .. version .. " has been released!\n\n\n### Changes in " ..  version .. ":\n" .. changelog }))
    run_command('curl -H "Content-Type:application/json" ' .. ARGS.discord ..' -X POST -d "$(</tmp/discord)"')
  end
  log.action(string.format("Done."))
  os.exit(0)
end
