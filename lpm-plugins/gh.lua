-- github extension plugin
-- requires `git` and `gh` installed.

local function run_command(cmd)
  if VERBOSE then log.action("Running " .. cmd .. "...") end
  return io.popen(cmd):read("*all")
end

local old_repository_url = Repository.url
function Repository.url(url, ...)
  if type(url) == "string" then
    local s, e, owner, repo, pull_id = url:find("https://github.com/([^/]+)/([^/]+)/pull/(%d+)")
    if s then
      local pr = json.decode(run_command(string.format("gh pr list -R %s/%s -S %d --json headRepository,headRefName,headRepositoryOwner,number", owner, repo, pull_id)))[1]
      if pr then return old_repository_url(string.format("https://github.com/%s/%s.git:%s", pr.headRepositoryOwner.login, pr.headRepository.name, pr.headRefName), ...) end
      error("Can't find pull request" .. url)
    end
  end
 return old_repository_url(url, ...)
end

if ARGS[2] == "gh" and ARGS[3] == "create-addon-update-pr" then
  ARGS = common.args(ARGS, { target = "string", source = "string", staging = "string", name = "string" })
  local target = ARGS["target"] or "git@github.com:lite-xl/lite-xl-plugins.git:master"
  local staging = ARGS["staging"] or os.getenv("LPM_ADDON_STAGING_REPO")
  assert(staging, "requires a staging plugins repository")
  local source = ARGS["source"] or (common.read(".git/config"):match("%[remote \"origin\"%]%s+url%s*=%s*(%S+)") .. ":HEAD")

  local name = ARGS["name"] or common.basename(system.stat(".").abs_path)
  local target_url, target_branch = target:match("^(.*):(%w+)$")
  local target_owner, target_project = target:match("git@github.com:([%w-]+)/([%w-]+).git")
  assert(target_url and target_branch and target_owner and target_project, "invalid target")
  local staging_owner, staging_project = staging:match("git@github.com:([%w-]+)/([%w-]+).git")
  assert(staging_owner and target_project == staging_project, "invalid staging")
  local source_owner, source_project, source_branch = source:match("([%w-]+)/([%w-]+)%.git:([%w-]+)$")
  assert(source_branch)
  local source_commit = run_command("git rev-parse " .. source_branch)
  local updating_manifest = json.decode(common.read("manifest.json"))
  local updating_addons = common.slice(ARGS, 4, #ARGS)
  if #updating_addons > 0 then
    updating_addons = common.map(updating_addons, function(addon)
      local to_update = common.grep(updating_manifest.addons, function(a) return a.id == addon.id end)
      assert(to_update, "can't find addon " .. addon)
      return to_update
    end)
  else
    updating_addons = updating_manifest.addons
  end
  local path = TMPDIR .. PATHSEP .. "pr"
  common.rmrf(path)
  assert(os.execute(string.format("git clone %s %s", staging, path)))
  local staging_branch = "origin/master"
  if target ~= staging then
    assert(os.execute(string.format("cd %s && git remote add upstream %s && git fetch upstream", path, target_url)))
    staging_branch = "upstream/master"
  end
  assert(os.execute(string.format("cd %s && git checkout -B 'PR/update-manifest-%s' && git reset %s --hard", path, name, staging_branch)))
  local target_manifest = json.decode(common.read(path .. PATHSEP .. "manifest.json"))
  local target_map = {}
  for i,v in ipairs(target_manifest.addons) do target_map[v.id] = i end
  for i,v in ipairs(updating_addons) do
    local entry = {
      id = v.id,
      version = v.version,
      remote = string.format("https://github.com/%s/%s.git:%s", source_owner, source_project, source_commit)
    }
    if v.name then entry.name = v.name end
    if v.description then entry.description = v.description end
    if not target_map[v.id] then
      table.insert(target_manifest.addons, v)
    else
      target_manifest.addons[target_map[v.id]] = common.merge(target_manifest.addons[target_map[v.id]], entry)
    end
  end
  common.write(path .. PATHSEP .. "manifest.json", json.encode(target_manifest, { pretty = true }))
  assert(os.execute(string.format("cd %s && git add manifest.json && git commit -m 'Updated manifest.json.' && git push -f --set-upstream origin PR/update-manifest-%s", path, name)))
  local result = json.decode(run_command(string.format("gh pr list -R %s/%s -H PR/update-manifest-%s --json id", target_owner, target_project, name)))
  if result and #result == 0 then
    assert(os.execute(string.format("gh pr create -R %s/%s -H %s:PR/update-manifest-%s -t 'Update %s Version' -b 'Bumping versions of stubs for %s.'", target_owner, target_project, staging_owner, name, name, name)))
  end
  os.exit(0)
end
