local U = require('worktree_review.util')
local C = require('worktree_review.config')
local M = {}
function M.run(root, args, allow_failure, input)
  local cmd = { C.values.git.executable, '--no-pager', '--literal-pathspecs', '-c', 'color.ui=false', '-C', root }
  vim.list_extend(cmd, args)
  local result = U.await(function(cb)
    local ok, err = pcall(vim.system, cmd, { text = false, stdin = input, env = { GIT_TERMINAL_PROMPT = '0' } }, cb)
    if not ok then cb({ code = -1, stdout = '', stderr = tostring(err) }) end
  end)
  result.stdout, result.stderr = result.stdout or '', result.stderr or ''
  if result.code ~= 0 and not allow_failure then
    error(('Git %s failed (%s):\n%s'):format(args[1], result.code, result.stderr ~= '' and result.stderr or result.stdout), 0)
  end
  return result.stdout, result
end
function M.text(root, args, allow) return vim.trim(M.run(root, args, allow)) end
function M.serialize(repo, fn)
  U.await(function(cb)
    repo.queue = repo.queue or {}
    repo.queue[#repo.queue + 1] = cb
    if not repo.busy then repo.busy = true; repo.queue[1]() end
  end)
  local ok, result = pcall(fn)
  table.remove(repo.queue, 1)
  if repo.queue[1] then repo.queue[1]() else repo.busy = false end
  if not ok then error(result, 0) end
  return result
end
function M.parse_status(data)
  local s = { entries = {}, staged = 0, unstaged = 0, added = 0, changed = 0, deleted = 0, conflicts = 0, remote = '', merge_ref = '', push_remote = '' }
  local records, i = U.nul(data), 1
  while i <= #records do
    local r, entry = records[i]
    if r:sub(1, 2) == '# ' then
      local key, value = r:match('^# ([^ ]+) (.*)$')
      if key == 'branch.head' then s.branch = value
      elseif key == 'branch.oid' then s.head = value ~= '(initial)' and value or nil
      elseif key == 'branch.upstream' then s.upstream = value
      elseif key == 'branch.ab' then s.ahead, s.behind = value:match('^%+(%d+) %-(%d+)$') end
    elseif r:sub(1, 2) == '? ' then entry = { path = r:sub(3), x = '?', y = '?', untracked = true }
    elseif r:sub(1, 2) == '1 ' then
      local xy, sub, mh, mi, mw, hh, hi, path = r:match('^1 (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$')
      if xy then entry = { path = path, x = xy:sub(1, 1), y = xy:sub(2, 2), sub = sub, mh = mh, mi = mi, mw = mw, hh = hh, hi = hi } end
    elseif r:sub(1, 2) == '2 ' then
      local xy, sub, mh, mi, mw, hh, hi, score, path = r:match('^2 (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$')
      if xy then i = i + 1; entry = { path = path, old_path = records[i], x = xy:sub(1, 1), y = xy:sub(2, 2), sub = sub, mh = mh, mi = mi, mw = mw, hh = hh, hi = hi, score = score } end
    elseif r:sub(1, 2) == 'u ' then
      local xy, sub, m1, m2, m3, mw, h1, h2, h3, path = r:match('^u (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$')
      if xy then entry = { path = path, x = xy:sub(1, 1), y = xy:sub(2, 2), conflict = true, sub = sub, mw = mw } end
    end
    if entry then
      s.entries[#s.entries + 1] = entry
      if entry.conflict then s.conflicts = s.conflicts + 1
      else
        if not entry.untracked and entry.x ~= '.' then s.staged = s.staged + 1 end
        if entry.untracked or entry.y ~= '.' then s.unstaged = s.unstaged + 1 end
      end
      local kind = entry.untracked and 'A' or (entry.y ~= '.' and entry.y or entry.x)
      if kind == 'A' then s.added = s.added + 1 elseif kind == 'D' then s.deleted = s.deleted + 1 else s.changed = s.changed + 1 end
    end
    i = i + 1
  end
  s.ahead, s.behind = tonumber(s.ahead), tonumber(s.behind)
  return s
end
function M.status(ctx)
  local s = M.parse_status(M.run(ctx.root, { 'status', '--porcelain=v2', '--branch', '-z', '--untracked-files=all' }))
  local remotes = M.text(ctx.root, { 'remote' })
  s.remotes = remotes ~= '' and vim.split(remotes, '\n', { plain = true }) or {}
  if s.upstream then
    local _, r = M.run(ctx.root, { 'rev-parse', '--verify', '@{upstream}' }, true)
    s.remote_label = r.code ~= 0 and 'Upstream missing' or ('↑%d ↓%d'):format(s.ahead or 0, s.behind or 0)
    s.remote = M.text(ctx.root, { 'config', '--get', 'branch.' .. (s.branch or '') .. '.remote' }, true)
    s.merge_ref = M.text(ctx.root, { 'config', '--get', 'branch.' .. (s.branch or '') .. '.merge' }, true)
    s.push_remote = M.text(ctx.root, { 'config', '--get', 'branch.' .. (s.branch or '') .. '.pushRemote' }, true)
    if s.push_remote == '' then s.push_remote = M.text(ctx.root, { 'config', '--get', 'remote.pushDefault' }, true) end
  else s.remote_label = #s.remotes == 0 and 'No remote' or 'Unpublished' end
  local dir = M.text(ctx.root, { 'rev-parse', '--absolute-git-dir' })
  ctx.git_dir = dir
  for _, name in ipairs({ 'MERGE_HEAD', 'rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG', 'index.lock' }) do
    if U.uv.fs_stat(dir .. '/' .. name) then s.operation = name; break end
  end
  ctx.status, ctx.error = s, nil
  return s
end
function M.parse_worktrees(data)
  local out, current = {}, nil
  for _, line in ipairs(U.nul(data)) do
    if line:sub(1, 9) == 'worktree ' then current = { root = line:sub(10) }; out[#out + 1] = current
    elseif current then
      local key, value = line:match('^(%S+)%s?(.*)$')
      if key == 'branch' then current.branch = value:gsub('^refs/heads/', '')
      elseif key == 'HEAD' then current.head = value
      elseif key then current[key] = value ~= '' and value or true end
    end
  end
  return out
end
function M.history(ctx, count)
  if not ctx.status.head then return {} end
  local data = M.run(ctx.root, { 'log', '-z', '--format=%H%x00%h%x00%s%x00%an%x00%aI%x00%P', '-n', tostring(count) })
  local fields, out = U.nul(data), {}
  for i = 1, #fields, 6 do
    if fields[i + 5] then out[#out + 1] = { oid = fields[i], short = fields[i + 1], subject = fields[i + 2], author = fields[i + 3], date = fields[i + 4], parents = vim.split(fields[i + 5], ' ', { trimempty = true }) } end
  end
  return out
end
function M.commit_files(ctx, commit, parent)
  local args = { 'diff-tree', '--no-commit-id', '--name-status', '-r', '-z', '-M', '--no-ext-diff' }
  if parent then vim.list_extend(args, { parent, commit.oid }) else vim.list_extend(args, { '--root', commit.oid }) end
  local parts, entries, i = U.nul(M.run(ctx.root, args)), {}, 1
  while i <= #parts do
    local kind, path = parts[i], parts[i + 1]
    if path then
      local e = { x = kind:sub(1, 1), y = '.', path = path, group = 'commit' }
      i = i + 2
      if e.x == 'R' or e.x == 'C' then e.old_path, e.path = path, parts[i]; i = i + 1 end
      entries[#entries + 1] = e
    else break end
  end
  return entries
end
function M.content(ctx, ref, path)
  if not ref or not path then return '', { empty = true } end
  local spec = ref == ':' and ':' .. path or ref .. ':' .. path
  local oid, result = M.run(ctx.root, { 'rev-parse', '--verify', spec }, true)
  if result.code ~= 0 then return '', { empty = true } end
  oid = vim.trim(oid)
  local kind = M.text(ctx.root, { 'cat-file', '-t', oid })
  if kind ~= 'blob' then return 'Git object: ' .. kind .. ' ' .. oid, { special = true } end
  local size = tonumber(M.text(ctx.root, { 'cat-file', '-s', oid })) or 0
  if size > C.values.review.large_file_bytes and not ctx.load_large then return 'Large file (' .. size .. ' bytes). Press L in the file list to load.', { special = true } end
  local data = M.run(ctx.root, { 'cat-file', 'blob', oid })
  if data:find('\0', 1, true) then return 'Binary file: ' .. U.display(path), { special = true } end
  if not ctx.load_large and #U.lines(data) > C.values.review.large_file_lines then return 'Large file (line limit). Press L to load.', { special = true } end
  local lfs_prefix = 'version https://git-lfs.github.com/spec/v1\n'
  if data:sub(1, #lfs_prefix) == lfs_prefix then return data, { lfs = true } end
  return data, { oid = oid, no_eol = data ~= '' and data:sub(-1) ~= '\n', crlf = data:find('\r\n', 1, true) ~= nil }
end
return M
