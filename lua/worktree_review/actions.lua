local U = require('worktree_review.util')
local G = require('worktree_review.git')
local Context = require('worktree_review.context')
local B = require('worktree_review.buffers')
local C = require('worktree_review.config')
local M = {}
local function action(ctx, fn)
  if not ctx then U.notify('Select a worktree first.'); return end
  U.task(function()
    G.serialize(ctx.repo, function() fn() end)
    require('worktree_review.refresh').invalidate(ctx.repo)
  end, function(err)
    ctx.repo.last_error = err; U.notify(err, vim.log.levels.ERROR)
    require('worktree_review.refresh').invalidate(ctx.repo)
  end)
end
local function safe(ctx, operation, clean)
  assert(not ctx.missing, 'Worktree directory is missing')
  local s = G.status(ctx)
  assert(not s.operation, operation .. ' blocked by Git operation: ' .. tostring(s.operation))
  if clean then
    assert(#s.entries == 0, operation .. ' blocked: staged, unstaged, untracked or conflicted files remain')
    assert(#Context.unsaved(ctx) == 0, operation .. ' blocked: unsaved buffers remain')
    for b, t in pairs(B.tracked) do if t.ctx == ctx then assert(not t.conflict, operation .. ' blocked: external file conflict in buffer ' .. b) end end
  end
  return s
end
local function entries(ctx, marked)
  if marked then
    local list = {}; for _, e in pairs(ctx.marked or {}) do list[#list + 1] = e end
    return list
  end
  local e = require('worktree_review.ui').selected_file(ctx)
  return e and { e } or {}
end
local function stage(ctx, unstage, marked)
  -- Bind the requested files before opening a dialog or waiting on another action.
  local selected = entries(ctx, marked)
  if #selected == 0 then U.notify('Select a file first.'); return end
  action(ctx, function()
    local paths, seen = {}, {}
    for _, entry in ipairs(selected) do
      assert(entry.group ~= 'commit', 'Historical files cannot be staged; open Current Changes first')
      for _, path in ipairs({ entry.path, entry.old_path }) do
        if path and not seen[path] then seen[path] = true; paths[#paths + 1] = path end
      end
    end
    if not unstage then
      local dirty = {}
      for _, path in ipairs(paths) do
        local b = B.find(ctx, path)
        if b then
          B.track(ctx, b, ctx.root .. '/' .. path)
          assert(B.resolve(b), 'Staging cancelled: external file conflict')
          if vim.bo[b].modified then dirty[#dirty + 1] = b end
        end
      end
      if #dirty > 0 then
        local choice = U.select({ 'Save and stage', 'Cancel' }, ('%d unsaved file(s) in %s'):format(#dirty, ctx.root))
        if choice ~= 'Save and stage' then return end
        for _, b in ipairs(dirty) do
          assert(B.resolve(b), 'Staging cancelled: new external change')
          vim.api.nvim_buf_call(b, function() vim.cmd('write') end)
          assert(not vim.bo[b].modified, 'Save failed; staging cancelled')
        end
      end
    end
    local s = G.status(ctx)
    assert(not s.operation or s.operation ~= 'index.lock', 'Index is locked by another Git process')
    local args
    if unstage then args = s.head and { 'restore', '--staged', '--' } or { 'update-index', '--force-remove', '--' }
    else args = { 'add', '-A', '--' } end
    vim.list_extend(args, paths)
    G.run(ctx.root, args)
    ctx.marked = {}
  end)
end
function M.stage(ctx) stage(ctx, false, false) end
function M.unstage(ctx) stage(ctx, true, false) end
function M.stage_marked(ctx) stage(ctx, false, true) end
function M.unstage_marked(ctx) stage(ctx, true, true) end
function M.edit(ctx)
  if not ctx then return end
  local e = require('worktree_review.ui').selected_file(ctx)
  if not e then U.notify('Select a file first.'); return end
  if not U.uv.fs_lstat(ctx.root .. '/' .. e.path) then U.notify('Working File is deleted; no new file was created.'); return end
  local entry = vim.tbl_extend('force', e, { group = 'unstaged', old_path = nil, untracked = e.untracked })
  require('worktree_review.ui').diff(ctx, entry, true)
  if ctx.ui and vim.api.nvim_win_is_valid(ctx.ui.right) then vim.api.nvim_set_current_win(ctx.ui.right) end
end
function M.fetch(ctx)
  if not ctx then return end
  local repo = ctx.repo
  if repo.fetching then return end
  repo.fetching = true
  require('worktree_review.ui').render_overview(repo)
  U.task(function()
    G.serialize(repo, function()
      local args = { 'fetch', '--all' }; if C.values.git.fetch_prune then args[#args + 1] = '--prune' end
      G.run(repo.root, args)
    end)
    repo.fetching, repo.fetch_error, repo.fetch_time = false, nil, os.time()
    require('worktree_review.refresh').invalidate(repo)
  end, function(err)
    repo.fetching, repo.fetch_error = false, err
    U.notify('Fetch failed; previous values may be stale. E in overview shows details.', vim.log.levels.WARN)
    require('worktree_review.refresh').invalidate(repo)
  end)
end
function M.pull(ctx)
  action(ctx, function()
    local s = safe(ctx, 'Pull', true)
    if not s.upstream then
      local refs = G.text(ctx.root, { 'for-each-ref', '--format=%(refname:short)', 'refs/remotes' })
      local options = {}
      for ref in refs:gmatch('[^\n]+') do if not ref:match('/HEAD$') then options[#options + 1] = ref end end
      local upstream = U.select(options, 'Choose upstream for ' .. (s.branch or 'detached HEAD') .. ':')
      if not upstream then return end
      assert(s.branch ~= '(detached)' and s.branch ~= '(unknown)', 'Pull requires a local branch')
      G.run(ctx.root, { 'branch', '--set-upstream-to=' .. upstream, s.branch })
      s = safe(ctx, 'Pull', true)
    end
    assert(s.remote_label ~= 'Upstream missing', 'Upstream tracking reference is missing; fetch or choose another upstream')
    if U.select({ 'Pull (fast-forward only)', 'Cancel' }, ctx.root .. ' ← ' .. s.upstream) ~= 'Pull (fast-forward only)' then return end
    s = safe(ctx, 'Pull', true)
    G.run(ctx.root, { 'pull', '--ff-only', '--no-rebase', '--', s.remote, s.merge_ref })
  end)
end
local function remote_for(s)
  local requested = C.values.git.default_remote
  if requested then
    assert(vim.tbl_contains(s.remotes, requested), 'Configured git.default_remote does not exist: ' .. requested)
    return requested
  end
  if vim.tbl_contains(s.remotes, 'origin') then return 'origin' end
  if #s.remotes == 1 then return s.remotes[1] end
  return U.select(s.remotes, 'Choose push remote:')
end
function M.push(ctx)
  action(ctx, function()
    local s = safe(ctx, 'Push', false)
    assert(s.head and s.branch ~= '(detached)' and s.branch ~= '(unknown)', 'Push requires a local branch with a commit')
    assert(#s.remotes > 0, 'No Git remote configured')
    local remote = s.upstream and (s.push_remote ~= '' and s.push_remote or s.remote) or remote_for(s)
    if not remote then return end
    local target = s.upstream and s.merge_ref or ('refs/heads/' .. s.branch)
    if s.push_remote ~= '' and s.push_remote ~= s.remote then target = 'refs/heads/' .. s.branch end
    assert(target and target:match('^refs/heads/'), 'Upstream must refer to a branch')
    local prompt = ctx.root .. '\n' .. s.branch .. ' → ' .. remote .. '/' .. target:gsub('^refs/heads/', '')
    if s.push_remote ~= '' and s.push_remote ~= s.remote then prompt = prompt .. '\nPush remote differs from fetch remote: ' .. s.remote end
    if U.select({ 'Push branch', 'Cancel' }, prompt) ~= 'Push branch' then return end
    local latest = safe(ctx, 'Push', false)
    assert(latest.branch == s.branch and latest.remote == s.remote and latest.merge_ref == s.merge_ref, 'Push target changed externally; refresh and try again')
    local args = { 'push' }; if not s.upstream then args[#args + 1] = '--set-upstream' end
    vim.list_extend(args, { '--', remote, 'refs/heads/' .. s.branch .. ':' .. target })
    G.run(ctx.root, args)
    U.notify('Push successful: ' .. remote .. '/' .. target:gsub('^refs/heads/', ''))
  end)
end
function M.create(ctx)
  action(ctx, function()
    local branch = U.input('Feature branch (new or existing): ')
    if not branch or branch == '' then return end
    G.run(ctx.root, { 'check-ref-format', '--branch', branch })
    assert(branch:sub(1, 1) ~= '-', 'Branch cannot start with -')
    Context.list(ctx.repo)
    for _, other in ipairs(ctx.repo.worktrees) do
      if other.branch == branch then
        if U.select({ 'Open existing worktree', 'Cancel' }, branch .. ' is already checked out in ' .. other.root) == 'Open existing worktree' then require('worktree_review.ui').open(other) end
        return
      end
    end
    local _, exists = G.run(ctx.root, { 'show-ref', '--verify', '--quiet', 'refs/heads/' .. branch }, true)
    local base
    if exists.code ~= 0 then
      base = U.input('Base ref (source changes are not copied): ', 'HEAD')
      if not base then return end
      base = G.text(ctx.root, { 'rev-parse', '--verify', '--end-of-options', base .. '^{commit}' })
    end
    local main = ctx.repo.worktrees[1].root
    local suffix = branch:gsub('[<>:"/\\|?*%c]', '-'):gsub('[ .]+$', '')
    local path = U.input('New worktree path (source changes are not copied): ', vim.fs.dirname(main) .. '/' .. vim.fs.basename(main) .. '-' .. suffix)
    if not path then return end
    path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
    assert(not U.uv.fs_lstat(path), 'Target path already exists; choose another directory')
    -- Resolve the nearest existing ancestor to reject nesting through symlink aliases.
    local ancestor, tail = path, ''
    while not U.uv.fs_stat(ancestor) do tail = '/' .. vim.fs.basename(ancestor) .. tail; local parent = vim.fs.dirname(ancestor); assert(parent and parent ~= ancestor, 'Invalid worktree path'); ancestor = parent end
    local resolved = (U.uv.fs_realpath(ancestor) or ancestor) .. tail
    for _, other in ipairs(ctx.repo.worktrees) do
      local other_root = U.uv.fs_realpath(other.root) or other.root
      assert(not U.inside(resolved, other_root) and not U.inside(other_root, resolved), 'Worktrees must not be nested')
    end
    local open_after = U.select({ 'Create and open', 'Create only', 'Cancel' }, branch .. '\n' .. path .. '\nOnly committed base content is copied.')
    if not open_after or open_after == 'Cancel' then return end
    local args = { 'worktree', 'add' }
    if exists.code ~= 0 then vim.list_extend(args, { '-b', branch, '--', path, base }) else vim.list_extend(args, { '--', path, branch }) end
    G.run(ctx.root, args)
    Context.list(ctx.repo)
    if open_after == 'Create and open' then require('worktree_review.ui').hide_overview(ctx.repo); require('worktree_review.ui').open(Context.get(ctx.repo, path)) end
  end)
end
function M.remove(ctx)
  action(ctx, function()
    assert(not ctx.main, 'The main worktree cannot be removed')
    Context.list(ctx.repo)
    assert(not ctx.locked, 'Worktree is locked; use Git externally to inspect it')
    assert(not (ctx.copilot and ctx.copilot.state == 'running'), 'Stop this worktree’s Copilot session before removal')
    local s = safe(ctx, 'Remove', true)
    local choice = U.select({ 'Remove; keep branch', 'Remove and delete branch (safe -d)', 'Cancel' }, ctx.root .. '\nBranch: ' .. (ctx.branch or 'Detached HEAD') .. ' · ' .. s.remote_label)
    if not choice or choice == 'Cancel' then return end
    safe(ctx, 'Remove', true)
    Context.list(ctx.repo)
    assert(not ctx.locked, 'Worktree became locked; removal cancelled')
    assert(not (ctx.copilot and ctx.copilot.state == 'running'), 'Copilot started; stop it first')
    -- Windows holds the process working directory open. Move managed local
    -- directories out of the target and release watchers before Git removes it.
    require('worktree_review.refresh').stop(ctx)
    if ctx.tab and vim.api.nvim_tabpage_is_valid(ctx.tab) then
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(ctx.tab)) do
        vim.api.nvim_win_call(win, function()
          vim.cmd('tcd ' .. vim.fn.fnameescape(ctx.repo.root))
          if U.inside(vim.fn.getcwd(), ctx.root) then vim.cmd('lcd ' .. vim.fn.fnameescape(ctx.repo.root)) end
        end)
      end
    end
    local removed, remove_error = pcall(G.run, ctx.repo.root, { 'worktree', 'remove', '--', ctx.root })
    if not removed then
      if U.uv.fs_stat(ctx.root) and ctx.tab and vim.api.nvim_tabpage_is_valid(ctx.tab) then
        vim.api.nvim_win_call(vim.api.nvim_tabpage_list_wins(ctx.tab)[1], function() vim.cmd('tcd ' .. vim.fn.fnameescape(ctx.root)) end)
        require('worktree_review.refresh').watch(ctx)
      end
      error(remove_error, 0)
    end
    ctx.missing = true
    require('worktree_review.buffers').check(ctx)
    if ctx.tab and vim.api.nvim_tabpage_is_valid(ctx.tab) then
      local original = vim.api.nvim_get_current_tabpage()
      vim.api.nvim_set_current_tabpage(ctx.tab)
      if #vim.api.nvim_list_tabpages() == 1 then vim.cmd('tabnew') end
      if vim.api.nvim_tabpage_is_valid(ctx.tab) then vim.api.nvim_set_current_tabpage(ctx.tab); vim.cmd('tabclose') end
      if original ~= ctx.tab and vim.api.nvim_tabpage_is_valid(original) then vim.api.nvim_set_current_tabpage(original) end
    end
    ctx.tab, ctx.ui = nil, nil
    if choice == 'Remove and delete branch (safe -d)' and ctx.branch then
      local _, result = G.run(ctx.repo.root, { 'branch', '-d', '--', ctx.branch }, true)
      if result.code ~= 0 then U.notify('Worktree removed; branch retained:\n' .. result.stderr, vim.log.levels.WARN); return end
    end
    U.notify('Worktree removed' .. (choice == 'Remove; keep branch' and '; branch retained' or ''))
  end)
end
function M.commit(ctx)
  if not ctx then return end
  U.task(function()
    local s = safe(ctx, 'Commit', false)
    assert(s.staged > 0 and s.conflicts == 0, 'Commit requires staged files and no unresolved conflicts')
    if ctx.commit_window and vim.api.nvim_win_is_valid(ctx.commit_window) then vim.api.nvim_set_current_win(ctx.commit_window); return end
    local b = ctx.commit_buffer
    if not b or not vim.api.nvim_buf_is_valid(b) then b = U.scratch('commit'); ctx.commit_buffer = b end
    vim.bo[b].modifiable = true
    vim.bo[b].filetype = 'gitcommit'
    vim.b[b].worktree_review_context = ctx.id
    local w = vim.api.nvim_open_win(b, true, { relative = 'editor', border = 'rounded', width = math.max(20, math.min(80, vim.o.columns - 4)), height = math.max(3, math.min(15, vim.o.lines - 5)), row = 2, col = 2,
      title = ' Commit · ' .. U.display(s.branch) .. ' · ' .. s.staged .. ' staged ', footer = ' Ctrl-s commit · q close (draft retained) ' })
    ctx.commit_window = w
    ctx.commit_index = G.text(ctx.root, { 'write-tree' })
    local function submit()
      if ctx.committing then return end
      ctx.committing = true
      action(ctx, function()
        local ok, err = pcall(function()
          local now = safe(ctx, 'Commit', false)
          assert(now.staged > 0 and now.conflicts == 0, 'Commit requires staged files and no conflicts')
          local index = G.text(ctx.root, { 'write-tree' })
          if index ~= ctx.commit_index then
            ctx.commit_index = index
            if U.select({ 'Commit current index', 'Cancel' }, 'Staging changed. ' .. now.staged .. ' files are now staged in ' .. ctx.root) ~= 'Commit current index' then return end
          end
          local message = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), '\n')
          assert(vim.trim(message) ~= '', 'Commit message is empty')
          local temp = vim.fn.tempname()
          local fd, open_error = U.uv.fs_open(temp, 'w', 384); assert(fd, open_error)
          local written, write_error = U.uv.fs_write(fd, message .. '\n', 0); U.uv.fs_close(fd)
          if not written then U.uv.fs_unlink(temp); error(write_error) end
          local success, commit_error = pcall(G.run, ctx.root, { 'commit', '-F', temp })
          U.uv.fs_unlink(temp)
          if not success then error(commit_error, 0) end
          if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end
          vim.api.nvim_buf_set_lines(b, 0, -1, false, { '' }); vim.bo[b].modified = false
          U.notify('Commit successful. Unstaged and unsaved contents remain separate.')
        end)
        ctx.committing = false
        if not ok then error(err, 0) end
      end)
    end
    vim.keymap.set({ 'n', 'i' }, '<C-s>', submit, { buffer = b })
    vim.keymap.set('n', 'q', function() if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end end, { buffer = b })
  end)
end
return M
