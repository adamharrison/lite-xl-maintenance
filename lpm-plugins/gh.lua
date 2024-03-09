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
