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
-- options.staging_local is a
local function create_addon_pr(options, addons)
  local target = options["target"] or "git@github.com:lite-xl/lite-xl-plugins.git:master"
  local target_url, target_owner, target_project, target_branch = retrieve_owner_project_branch(target)
  assert(target_url and target_branch and target_owner and target_project, "invalid target " .. target)

  local source = options["source"] or (retrieve_repository_origin(".") .. ":HEAD")
  local source_url, source_owner, source_project, source_branch = retrieve_owner_project_branch(source)
  assert(source_branch, "can't find source branch from" .. source)
  local source_commit = common.is_commit_hash(source_branch) and source_branch or run_command("git ls-remote %s refs/heads/%s", source_url, source_branch):gsub("%s+.*\n$", "")

  local staging = options["staging"] or os.getenv("LPM_ADDON_STAGING_REPO") or ("git@github.com:" .. source_owner .. "/" .. target_project)
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

  local updating_manifest = json.decode(common.read(options["manifest"] or "manifest.json"))
  local updating_addons = addons or {}
  if #updating_addons > 0 then
    updating_addons = common.map(updating_addons, function(addon)
      addon = assert(common.grep(updating_manifest.addons, function(a) return a.id == addon end)[1], "can't find addon " .. addon)
      return addon
    end)
  else
    updating_addons = updating_manifest.addons
  end
  local path
  if staging_local then
    path = system.stat(staging_local).abs_path
  else
    path = SYSTMPDIR .. PATHSEP .. "pr"
    common.rmrf(path)
    run_command("git clone --depth=1 %s %s", staging, path)
    staging_branch = "origin/master"
    if target ~= staging then
      run_command("cd %s && git remote add upstream %s && git fetch --depth=1 upstream", path, target_url)
      staging_branch = "upstream/master"
    end
  end

  local name = options.name or common.basename(system.stat(".").abs_path)
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
    if not target_map[v.id] then
      table.insert(target_manifest.addons, entry)
    elseif options["ignore-version"] or (target_manifest.addons[target_map[v.id]].version ~= entry.version) then
      target_manifest.addons[target_map[v.id]] = common.merge(target_manifest.addons[target_map[v.id]], entry)
    end
  end
  common.write(path .. PATHSEP .. "manifest.json", json.encode(target_manifest, { pretty = true }) .. "\n")
  if not os.execute("cd '" .. path .. "' && git diff --exit-code -s manifest.json") then
    run_command("cd %s && git add manifest.json && git commit -m 'Updated manifest.json.'", path)
    run_command("cd %s && git push -f --set-upstream origin PR/update-manifest-%s", path, handle)
    if not options["no-pr"] then
      local result = json.decode(run_command("gh pr list -R %s/%s -H PR/update-manifest-%s --json id", target_owner, target_project, handle))
      if result and #result == 0 then
        assert(os.execute(string.format("gh pr create -R %s/%s -H %s:PR/update-manifest-%s -t 'Update %s Version' -b 'Bumping versions of stubs for %s.'", target_owner, target_project, staging_owner, handle, name, name)), "can't create pr")
      end
    end
  else
    log.warning("no change to manifest.json; not creating pr")
  end
end



if ARGS[2] == "gh" and ARGS[3] == "create-stubs-pr" then
  ARGS = common.args(ARGS, { target = "string", source = "string", staging = "string", name = "string", ["no-pr"] = "flag" })
  create_addon_pr(ARGS, common.slice(ARGS, 4))
  os.exit(0)
end


-- options.target is the repository we want create our PRs in.
-- options.staging is the repository we want to create our branches in; can be the same as options.target.
if ARGS[2] == "gh" and ARGS[3] == 'check-stubs-update-pr' then
  ARGS = common.args(ARGS, { target = "string", staging = "string", name = "string", ["no-pr"] = "flag", ["ignore-version"] = "flag"})
  local target = ARGS["target"] or retrieve_repository_origin(".") .. ":master"
  local staging = ARGS["staging"] or target

  local list = common.slice(ARGS, 4)

  local manifest = json.decode(common.read("manifest.json"))
  local remotes = {}
  for i,v in ipairs(manifest.addons) do
    if v.remote then
      if #list == 0 or #common.grep(list, function(e) return e == v.id end) > 0 then
        local repo = v.remote:match("^(.*):[a-f0-9]+$")
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
        local path = SYSTMPDIR .. PATHSEP .. "commit-" .. system.hash(remote .. branch)
        common.rmrf(path)
        local _, pinned = addons[1].remote:match("^.*:(%s+)$")
        run_command("git clone --depth 1 %s -b %s %s", remote, branch, path)
        if commit ~= pinned then
          create_addon_pr({ target = target, staging = staging, name = common.join(" and ", common.map(addons, function(a) return a.name or a.id end)), source = (remote .. ":" .. commit), manifest = path .. PATHSEP .. "manifest.json", ["no-pr"] = ARGS["no-pr"], ["ignore-version"] = ARGS["ignore-version"] }, common.map(addons, function(e) return e.id end))
          log.action(string.format("updated stub entry for %s to be pinned at %s based on branch %s", remote, commit, branch))
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
