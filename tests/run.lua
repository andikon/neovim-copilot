-- Dependency-free headless tests. Run from the repository: nvim --headless -u NONE -l tests/run.lua
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.o.columns, vim.o.lines = 180, 55
local U = require('worktree_review.util')
local G = require('worktree_review.git')
local Context = require('worktree_review.context')
local B = require('worktree_review.buffers')
local UI = require('worktree_review.ui')
local A = require('worktree_review.actions')
local passed = 0
local messages = {}
vim.notify = function(msg) messages[#messages + 1] = msg end
local choices, inputs = {}, {}
vim.ui.select = function(items, _, cb)
  local choice = table.remove(choices, 1)
  vim.schedule(function() cb(type(choice) == 'number' and items[choice] or choice) end)
end
vim.ui.input = function(_, cb) local input = table.remove(inputs, 1); vim.schedule(function() cb(input) end) end
local function wait_for(fn, label)
  assert(vim.wait(15000, fn, 10), 'Timeout: ' .. label .. '\n' .. table.concat(messages, '\n'))
end
local function async(fn)
  local done, failure
  U.task(function() fn(); done = true end, function(err) failure, done = err, true end)
  wait_for(function() return done end, 'async task')
  assert(not failure, failure)
end
local function eq(a, b) assert(vim.deep_equal(a, b), vim.inspect(a) .. ' != ' .. vim.inspect(b)) end
local function test(name, fn) fn(); passed = passed + 1; print('PASS ' .. name) end
local fixture = vim.fn.tempname() .. '-worktree-review-tests'
vim.fn.mkdir(fixture, 'p')
local main, linked, bare = fixture .. '/main ü space', fixture .. '/feature space', fixture .. '/remote.git'
local function write(path, text)
  local fd = assert(U.uv.fs_open(path, 'w', 438)); assert(U.uv.fs_write(fd, text, 0)); U.uv.fs_close(fd)
end
local function git(path, args, allow)
  local cmd = { 'git', '--no-pager', '--literal-pathspecs', '-C', path }; vim.list_extend(cmd, args)
  local r = vim.system(cmd, { text = false, env = { GIT_TERMINAL_PROMPT = '0' } }):wait()
  if not allow then assert(r.code == 0, r.stderr .. '\n' .. table.concat(args, ' ')) end
  return r.stdout or '', r
end
local ctx, other, repo
local function settle()
  wait_for(function()
    for _, repository in pairs(Context.repos) do if repository.busy or repository.listing then return false end end
    for _, c in pairs(Context.contexts) do if c.refreshing then return false end end
    return true
  end, 'Git actions settle')
end
local function act(fn)
  fn()
  -- Action callbacks enter the async queue at the next scheduled tick.
  vim.wait(30, function() return false end, 10)
  settle()
end
local function select_entry(c, path, group)
  async(function() G.status(c); c.mode, c.commit = 'current', nil; UI.render_lists(c) end)
  for row, e in pairs(c.ui.file_rows) do
    if e.path == path and e.group == group then vim.api.nvim_win_set_cursor(c.ui.files_win, { row, 0 }); c.selected = e; return e end
  end
  error('Missing entry ' .. path .. ' ' .. group)
end
local function cleanup()
  if require('worktree_review.refresh').timer then require('worktree_review.refresh').timer:stop() end
  for _, c in pairs(Context.contexts) do require('worktree_review.refresh').stop(c); if c.copilot and c.copilot.state == 'running' then vim.fn.jobstop(c.copilot.job) end end
  -- Delete only the unique directory created above, after verifying its identity.
  assert(fixture:match('%-worktree%-review%-tests$') and fixture ~= root)
  vim.cmd('tcd ' .. vim.fn.fnameescape(root)); vim.cmd('lcd ' .. vim.fn.fnameescape(root))
  assert(vim.fn.delete(fixture, 'rf') == 0, 'Cannot remove isolated test fixture: ' .. fixture)
end
local ok, failure = xpcall(function()
  require('worktree_review').setup({ git = { auto_fetch_on_overview = false }, copilot = { enabled = false }, refresh = { poll_interval_ms = 60000, watch_files = false } })
  test('NUL status parser: rename, dual staging, conflicts, missing HEAD and Unicode', function()
    local nul = '\0'
    local data = '# branch.oid (initial)' .. nul .. '# branch.head feature/demo' .. nul
      .. '1 MM N... 100644 100644 100644 abc def a ü [x].txt' .. nul
      .. '2 R. N... 100644 100644 100644 abc def R100 new name.txt' .. nul .. 'old\nname.txt' .. nul
      .. '? -untracked.txt' .. nul .. 'u UU N... 100644 100644 100644 100644 a b c conflict.txt' .. nul
    local s = G.parse_status(data)
    eq(s.staged, 2); eq(s.unstaged, 2); eq(s.conflicts, 1); eq(s.head, nil)
    eq(s.entries[2].old_path, 'old\nname.txt'); eq(s.entries[1].path, 'a ü [x].txt')
  end)
  test('worktree parser preserves spaces, missing paths and lock reasons', function()
    local ws = G.parse_worktrees('worktree C:/hello world\0HEAD abc\0branch refs/heads/main\0\0worktree C:/missing\0detached\0locked reason here\0prunable gone\0\0')
    eq(#ws, 2); eq(ws[1].root, 'C:/hello world'); eq(ws[2].locked, 'reason here')
    assert(U.inside(main .. '/x', main)); assert(not U.inside(main .. '-other/x', main))
  end)
  vim.fn.mkdir(main, 'p'); vim.fn.mkdir(bare, 'p')
  git(main, { 'init', '-b', 'main' }); git(main, { 'config', 'user.name', 'Test' }); git(main, { 'config', 'user.email', 'test@example.invalid' }); git(main, { 'config', 'core.autocrlf', 'false' })
  git(main, { 'config', 'commit.gpgsign', 'false' })
  write(main .. '/tracked.txt', 'base\r\nsecond\r\n'); write(main .. '/rename.txt', 'rename content\n'); write(main .. '/delete.txt', 'delete me\n')
  git(main, { 'add', '-A' }); git(main, { 'commit', '-m', 'Initial' })
  git(main, { 'worktree', 'add', '-b', 'feature/demo', linked, 'HEAD' })
  git(bare, { 'init', '--bare' }); git(main, { 'remote', 'add', 'origin', bare })
  async(function() repo = Context.discover(linked); Context.list(repo); ctx = Context.get(repo, main); other = Context.get(repo, linked); G.status(ctx); G.status(other) end)
  test('discovery from linked worktree uses shared identity and stable main root', function()
    eq(U.norm(repo.root), U.norm(main)); eq(#repo.worktrees, 2); assert(ctx.main); assert(not other.main)
  end)
  test('HEAD / Index / Working File are independent, literal filenames are safe', function()
    write(main .. '/tracked.txt', 'staged\r\nsecond\r\n'); git(main, { 'add', '--', 'tracked.txt' }); write(main .. '/tracked.txt', 'unstaged\r\nsecond\r\n')
    write(main .. '/ü [literal].txt', 'literal\n'); write(main .. '/-leading.txt', 'leading\n')
    git(main, { 'mv', 'rename.txt', 'renamed ü.txt' }); assert(U.uv.fs_unlink(main .. '/delete.txt'))
    async(function()
      local s = G.status(ctx); assert(s.staged >= 2 and s.unstaged >= 4)
      local head = G.content(ctx, s.head, 'tracked.txt'); local index = G.content(ctx, ':', 'tracked.txt')
      eq(head, 'base\r\nsecond\r\n'); eq(index, 'staged\r\nsecond\r\n'); eq(G.status(other).staged, 0)
      local history = G.history(ctx, 100); eq(#history, 1); eq(#history[1].parents, 0)
      eq(#G.commit_files(ctx, history[1]), 3)
    end)
  end)
  test('review real buffer editing preserves index and modified buffers across worktrees', function()
    UI.open(ctx); settle()
    local e = select_entry(ctx, 'tracked.txt', 'unstaged'); UI.diff(ctx, e, true)
    wait_for(function() return ctx.diff_key ~= nil end, 'working diff')
    local b = vim.api.nvim_win_get_buf(ctx.ui.right); eq(U.norm(vim.api.nvim_buf_get_name(b)), U.norm(main .. '/tracked.txt')); eq(vim.bo[b].fileformat, 'dos')
    vim.api.nvim_buf_set_lines(b, 0, 1, false, { 'unsaved editor' }); assert(vim.bo[b].modified)
    local oldtab = ctx.tab; UI.open(other); settle(); UI.open(ctx); settle(); eq(ctx.tab, oldtab)
    eq(vim.api.nvim_buf_get_lines(b, 0, 1, false), { 'unsaved editor' }); assert(vim.bo[b].modified)
    vim.api.nvim_buf_call(b, function() vim.cmd('write') end)
    local index = git(main, { 'show', ':tracked.txt' }); eq(index, 'staged\r\nsecond\r\n')
    e = select_entry(ctx, 'tracked.txt', 'staged'); UI.diff(ctx, e, true)
    wait_for(function() return ctx.diff_key and ctx.diff_key:sub(1, 6) == 'staged' end, 'staged diff')
    eq(vim.bo[vim.api.nvim_win_get_buf(ctx.ui.right)].buftype, 'nofile'); assert(not vim.bo[vim.api.nvim_win_get_buf(ctx.ui.right)].modifiable)
  end)
  test('normal write formatters and hooks still run on managed real buffers', function()
    local b = B.find(ctx, 'tracked.txt')
    local before, after = false, false
    local group = vim.api.nvim_create_augroup('WorktreeReviewTestWrite', { clear = true })
    vim.api.nvim_create_autocmd('BufWritePre', { group = group, buffer = b, callback = function() before = true; vim.api.nvim_buf_set_lines(b, 0, 1, false, { 'formatted content' }) end })
    vim.api.nvim_create_autocmd('BufWritePost', { group = group, buffer = b, callback = function() after = true end })
    vim.api.nvim_buf_call(b, function() vim.cmd('write') end)
    assert(before and after); eq(B.disk(main .. '/tracked.txt'), 'formatted content\r\nsecond\r\n')
    vim.api.nvim_del_augroup_by_id(group)
  end)
  test('stage literal file, unstage and index isolation', function()
    select_entry(ctx, 'ü [literal].txt', 'unstaged'); act(function() A.stage(ctx) end)
    eq(git(main, { 'show', ':ü [literal].txt' }), 'literal\n')
    select_entry(ctx, 'ü [literal].txt', 'staged'); eq(UI.selected_file(ctx).path, 'ü [literal].txt'); eq(UI.selected_file(ctx).group, 'staged'); act(function() A.unstage(ctx) end)
    local _, missing = git(main, { 'cat-file', '-e', ':ü [literal].txt' }, true); assert(missing.code ~= 0)
    eq(git(other.root, { 'status', '--porcelain' }), '')
  end)
  test('binary and large files stay out of editable review buffers until explicitly loaded', function()
    local limits = require('worktree_review.config').values.review
    write(main .. '/binary.dat', 'abc\0def'); local b, reason = B.open(ctx, 'binary.dat'); eq(b, nil); eq(reason, 'Binary file')
    write(main .. '/large.txt', string.rep('large\n', 50)); local original_limit = limits.large_file_bytes; limits.large_file_bytes = 32
    b, reason = B.open(ctx, 'large.txt'); eq(b, nil); assert(reason:match('Large file'))
    ctx.load_large = true; assert(B.open(ctx, 'large.txt')); ctx.load_large = nil; limits.large_file_bytes = original_limit
    assert(U.uv.fs_unlink(main .. '/binary.dat')); assert(U.uv.fs_unlink(main .. '/large.txt'))
    write(main .. '/no-eol.txt', 'no newline')
    local no_eol = assert(B.open(ctx, 'no-eol.txt')); assert(not vim.bo[no_eol].endofline)
    vim.api.nvim_buf_set_lines(no_eol, 0, -1, false, { 'still no newline' })
    vim.api.nvim_buf_call(no_eol, function() vim.cmd('write') end)
    eq(B.disk(main .. '/no-eol.txt'), 'still no newline'); assert(U.uv.fs_unlink(main .. '/no-eol.txt'))
  end)
  test('external file conflicts are scoped to one observed version; cancellation protects writes', function()
    local b = B.find(ctx, 'tracked.txt'); vim.api.nvim_buf_set_lines(b, 0, 1, false, { 'editor pending' })
    write(main .. '/tracked.txt', 'external one\r\n'); local original = vim.fn.confirm
    vim.fn.confirm = function() return 3 end
    assert(not B.resolve(b)); assert(vim.b[b].worktree_review_external_conflict)
    local saved = pcall(vim.api.nvim_buf_call, b, function() vim.cmd('write') end); assert(not saved)
    vim.fn.confirm = function() return 1 end; assert(B.resolve(b)); assert(B.resolve(b))
    write(main .. '/tracked.txt', 'external two\r\n'); vim.fn.confirm = function() return 3 end; assert(not B.resolve(b))
    vim.fn.confirm = function() return 2 end; assert(not B.resolve(b)); eq(vim.api.nvim_buf_get_lines(b, 0, 1, false), { 'external two' }); assert(not vim.bo[b].modified)
    vim.api.nvim_buf_set_lines(b, 0, 1, false, { 'explicitly kept editor' })
    write(main .. '/tracked.txt', 'external three\r\n')
    vim.fn.confirm = function() return 1 end
    vim.api.nvim_buf_call(b, function() vim.cmd('write') end)
    eq(B.disk(main .. '/tracked.txt'), 'explicitly kept editor\r\n')
    vim.fn.confirm = original
  end)
  test('deleted Working File uses a placeholder and never recreates the path', function()
    local e = select_entry(ctx, 'delete.txt', 'unstaged'); UI.diff(ctx, e, true)
    wait_for(function() return ctx.diff_key and ctx.diff_key:find('delete.txt', 1, true) end, 'deleted diff')
    eq(vim.bo[vim.api.nvim_win_get_buf(ctx.ui.right)].buftype, 'nofile'); assert(not U.uv.fs_stat(main .. '/delete.txt'))
  end)
  test('initial commit history is readonly; fast file selection discards stale results', function()
    async(function() ctx.history = G.history(ctx, 100) end); UI.select_history(ctx, 3)
    wait_for(function() return ctx.mode == 'commit' and ctx.commit_entries ~= nil end, 'history'); settle()
    eq(#ctx.commit.parents, 0)
    local first, last = { path = 'tracked.txt', x = 'M', y = 'M', group = 'unstaged' }, { path = 'ü [literal].txt', x = '?', y = '?', untracked = true, group = 'unstaged' }
    UI.diff(ctx, first, true); UI.diff(ctx, last, true)
    wait_for(function() return ctx.diff_key and ctx.diff_key:find('ü [literal].txt', 1, true) end, 'latest diff')
    eq(U.norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(ctx.ui.right))), U.norm(main .. '/ü [literal].txt'))
    ctx.mode, ctx.commit = 'current', nil
  end)
  test('explicit commit uses only index, retains unstaged files and draft on hook failure', function()
    A.commit(ctx); wait_for(function() return ctx.commit_buffer and ctx.commit_index end, 'commit window')
    vim.api.nvim_buf_set_lines(ctx.commit_buffer, 0, -1, false, { 'Test staged commit', '', 'More detail ü' })
    local hooks = fixture .. '/hooks'; vim.fn.mkdir(hooks, 'p'); write(hooks .. '/pre-commit', '#!/bin/sh\nexit 1\n'); U.uv.fs_chmod(hooks .. '/pre-commit', 493)
    git(main, { 'config', 'core.hooksPath', hooks })
    local mapping = vim.api.nvim_buf_get_keymap(ctx.commit_buffer, 'n'); local submit
    for _, m in ipairs(mapping) do if m.lhs == '<C-S>' or m.lhs == '<C-s>' then submit = m.callback end end
    assert(submit, 'Commit mapping missing'); act(submit)
    eq(vim.api.nvim_buf_get_lines(ctx.commit_buffer, 0, 1, false), { 'Test staged commit' }); eq(vim.trim(git(main, { 'log', '-1', '--format=%s' })), 'Initial')
    git(main, { 'config', '--unset', 'core.hooksPath' }); act(submit)
    eq(vim.trim(git(main, { 'log', '-1', '--format=%s' })), 'Test staged commit')
    local _, untracked = git(main, { 'cat-file', '-e', 'HEAD:ü [literal].txt' }, true); assert(untracked.code ~= 0)
    eq(git(main, { 'show', 'HEAD:tracked.txt' }), 'staged\r\nsecond\r\n')
  end)
  test('first push publishes exactly selected branch and sets upstream', function()
    choices[#choices + 1] = 'Push branch'; act(function() A.push(other) end)
    eq(vim.trim(git(linked, { 'rev-parse', '--abbrev-ref', '@{upstream}' })), 'origin/feature/demo')
    local refs = git(bare, { 'for-each-ref', '--format=%(refname)' }); eq(vim.trim(refs), 'refs/heads/feature/demo')
  end)
  test('worktree removal blocks unsaved text and running terminals', function()
    local b = assert(B.open(other, 'tracked.txt')); vim.api.nvim_buf_set_lines(b, 0, 1, false, { 'unsaved' })
    act(function() A.remove(other) end); assert(U.uv.fs_stat(linked))
    vim.bo[b].modified = false; other.copilot = { state = 'running' }; act(function() A.remove(other) end); assert(U.uv.fs_stat(linked)); other.copilot = nil
  end)
  test('unborn HEAD supports unstaging even when Working File differs from staged content', function()
    local unborn = fixture .. '/unborn'; vim.fn.mkdir(unborn, 'p'); git(unborn, { 'init', '-b', 'new' })
    write(unborn .. '/new.txt', 'index\n'); git(unborn, { 'add', 'new.txt' }); write(unborn .. '/new.txt', 'working\n')
    local newctx
    async(function() local newrepo = Context.discover(unborn); Context.list(newrepo); newctx = Context.get(newrepo, unborn); G.status(newctx) end)
    UI.open(newctx); settle(); select_entry(newctx, 'new.txt', 'staged'); act(function() A.unstage(newctx) end)
    eq(git(unborn, { 'ls-files' }), ''); eq(B.disk(unborn .. '/new.txt'), 'working\n')
    async(function() eq(G.status(newctx).head, nil); eq(#G.history(newctx, 100), 0) end)
  end)
  test('create worktree from explicit base, reject dirty removal, and open existing checkout', function()
    local target = fixture .. '/created feature ü'
    inputs = { 'feature/created', 'HEAD', target }; choices = { 'Create and open' }
    act(function() A.create(ctx) end)
    assert(U.uv.fs_stat(target)); local created = Context.get(repo, target)
    eq(vim.trim(git(target, { 'rev-parse', 'HEAD' })), vim.trim(git(main, { 'rev-parse', 'HEAD' })))
    eq(git(target, { 'status', '--porcelain' }), '')
    inputs = { 'feature/created' }; choices = { 'Open existing worktree' }
    act(function() A.create(ctx) end); eq(vim.api.nvim_get_current_tabpage(), created.tab)
    write(target .. '/untracked.txt', 'still here\n'); act(function() A.remove(created) end); assert(U.uv.fs_stat(target))
    assert(U.uv.fs_unlink(target .. '/untracked.txt'))
    git(main, { 'worktree', 'lock', target }); act(function() A.remove(created) end); assert(U.uv.fs_stat(target))
    git(main, { 'worktree', 'unlock', target }); choices = { 'Remove; keep branch' }; act(function() A.remove(created) end); assert(not U.uv.fs_stat(target), table.concat(messages, '\n'))
  end)
  test('fetch preserves usable overview, missing upstream is explicit, and divergence never merges', function()
    UI.overview(repo)
    local overview = repo.overview
    local config = vim.api.nvim_win_get_config(overview.win)
    assert(config.border, 'Overview should use a floating border')
    assert(config.width <= 112 and config.relative == 'editor')
    local lines = vim.api.nvim_buf_get_lines(overview.buf, 0, -1, false)
    local content = table.concat(lines, '\n')
    assert(content:find('ACTIONS', 1, true) and content:find('WORKTREES', 1, true))
    assert(content:find('[Enter] Open', 1, true) and content:find('WORKTREE DETAILS · INFORMATION', 1, true))
    local second_row = overview.worktree_item_rows[2]
    vim.api.nvim_win_set_cursor(overview.win, { second_row, 0 })
    eq(UI.selected(repo), repo.worktrees[2])
    vim.api.nvim_win_set_cursor(overview.win, { overview.worktree_item_rows[1], 0 })
    eq(UI.selected(repo), repo.worktrees[1])
    A.fetch(other); assert(repo.fetching); assert(vim.api.nvim_win_is_valid(repo.overview.win))
    wait_for(function() return not repo.fetching end, 'fetch'); settle(); assert(repo.fetch_time); assert(not repo.fetch_error)
    UI.hide_overview(repo)
    local clone = fixture .. '/remote writer'; git(fixture, { 'clone', bare, clone })
    git(clone, { 'config', 'user.name', 'Test' }); git(clone, { 'config', 'user.email', 'test@example.invalid' }); git(clone, { 'config', 'commit.gpgsign', 'false' })
    git(clone, { 'checkout', 'feature/demo' }); write(clone .. '/remote.txt', 'remote commit\n'); git(clone, { 'add', 'remote.txt' }); git(clone, { 'commit', '-m', 'Remote commit' }); git(clone, { 'push' })
    write(linked .. '/local.txt', 'local commit\n'); git(linked, { 'add', 'local.txt' }); git(linked, { 'commit', '-m', 'Local commit' })
    local before = vim.trim(git(linked, { 'rev-parse', 'HEAD' })); choices = { 'Pull (fast-forward only)' }; act(function() A.pull(other) end)
    eq(vim.trim(git(linked, { 'rev-parse', 'HEAD' })), before); assert(not U.uv.fs_stat(other.git_dir .. '/MERGE_HEAD'))
    git(linked, { 'update-ref', '-d', 'refs/remotes/origin/feature/demo' }); async(function() eq(G.status(other).remote_label, 'Upstream missing') end)
    A.fetch(other); wait_for(function() return not repo.fetching end, 'refetch'); settle()
  end)
  test('merge commit supports explicit first and second parent comparisons', function()
    local merge = fixture .. '/merge'; vim.fn.mkdir(merge, 'p'); git(merge, { 'init', '-b', 'main' }); git(merge, { 'config', 'user.name', 'Test' }); git(merge, { 'config', 'user.email', 'test@example.invalid' }); git(merge, { 'config', 'commit.gpgsign', 'false' })
    write(merge .. '/base.txt', 'base\n'); git(merge, { 'add', '.' }); git(merge, { 'commit', '-m', 'Base' }); git(merge, { 'checkout', '-b', 'side' })
    write(merge .. '/side.txt', 'side\n'); git(merge, { 'add', '.' }); git(merge, { 'commit', '-m', 'Side' }); git(merge, { 'checkout', 'main' })
    write(merge .. '/main.txt', 'main\n'); git(merge, { 'add', '.' }); git(merge, { 'commit', '-m', 'Main' }); git(merge, { 'merge', '--no-ff', 'side', '-m', 'Merge' })
    async(function()
      local r = Context.discover(merge); local c = Context.get(r, merge); G.status(c)
      local commit = G.history(c, 10)[1]; eq(#commit.parents, 2)
      eq(G.commit_files(c, commit, commit.parents[1])[1].path, 'side.txt'); eq(G.commit_files(c, commit, commit.parents[2])[1].path, 'main.txt')
    end)
  end)
  test('Copilot argument quoting, native terminal reuse and independent worktree sessions', function()
    local config = require('worktree_review.config').values
    config.copilot.enabled = true
    config.copilot.command = vim.fn.has('win32') == 1 and { 'pwsh', '-NoLogo', '-NoProfile', '-Command', 'Write-Output $PWD; Start-Sleep -Seconds 30' } or { 'sh', '-c', 'pwd; sleep 30' }
    local P = require('worktree_review.copilot')
    P.toggle(other); local session = other.copilot; assert(session.state == 'running')
    P.toggle(other); assert(not session.win); P.toggle(other); eq(other.copilot.buf, session.buf); eq(other.copilot.job, session.job)
    UI.open(ctx); P.toggle(ctx); assert(ctx.copilot.job ~= session.job)
    vim.fn.jobstop(session.job); vim.fn.jobstop(ctx.copilot.job)
    wait_for(function() return session.state == 'exited' and ctx.copilot.state == 'exited' end, 'terminal exits')
    vim.cmd('stopinsert')
  end)
  test('clean worktree removal retains its branch', function()
    choices[#choices + 1] = 'Remove; keep branch'; act(function() A.remove(other) end)
    assert(not U.uv.fs_stat(linked)); local _, exists = git(main, { 'show-ref', '--verify', 'refs/heads/feature/demo' }, true); eq(exists.code, 0)
  end)
end, debug.traceback)
cleanup()
if not ok then io.stderr:write(failure .. '\n'); vim.cmd('cquit 1') end
print(('All %d tests passed'):format(passed))
vim.cmd('qa!')
