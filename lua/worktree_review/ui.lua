local U = require('worktree_review.util')
local C = require('worktree_review.config')
local G = require('worktree_review.git')
local Context = require('worktree_review.context')
local B = require('worktree_review.buffers')
local M = { ns = vim.api.nvim_create_namespace('WorktreeReview') }
local function valid(w) return w and vim.api.nvim_win_is_valid(w) end
local function map(b, key, fn)
  if C.values.keymaps.local_defaults then vim.keymap.set('n', key, fn, { buffer = b, silent = true, nowait = true }) end
end
local function common(b, ctx)
  map(b, 'r', function() require('worktree_review.refresh').request(ctx, true) end)
  map(b, 'c', function() require('worktree_review.actions').commit(ctx) end)
  map(b, '<Tab>', function() vim.cmd('wincmd w') end)
  map(b, '<S-Tab>', function() vim.cmd('wincmd W') end)
  map(b, '?', function() U.details('Worktree Review help', 'Overview: Enter open, a create, d remove, f fetch, p pull, P push\nReview: Enter diff, s stage, u unstage, e edit Working File, c commit\nSpace mark file, S stage marked, U unstage marked, L load large file\nHistory: Enter select, m choose merge parent, + load more, i details\nr refresh, q hide, Tab switch pane. :WorktreeReview copilot toggles CLI.\nDiff: ]c / [c move between hunks. Working File: normal editing and :w.\nCommit: Ctrl-s submit, q close in normal mode; draft retained on failure.') end)
end
local function statusline(ctx, label, b)
  if b and vim.bo[b].buftype == '' and not vim.bo[b].endofline then label = label .. ' · no final newline' end
  local modified = b and vim.bo[b].modified and ' · Unsaved' or ''
  local conflict = b and vim.b[b].worktree_review_external_conflict and ' · Externally changed' or ''
  return (' %s · %s%s%s '):format(U.display(ctx.branch or 'Detached HEAD'), label, modified, conflict):gsub('%%', '%%%%')
end
function M.selected(repo)
  local view = repo.overview
  local row = view and valid(view.win) and vim.api.nvim_win_get_cursor(view.win)[1] or 3
  return repo.worktrees[math.max(1, row - 2)] or repo.worktrees[1]
end
local function paint(b, row, group)
  vim.api.nvim_buf_add_highlight(b, M.ns, group, row - 1, 0, -1)
end
function M.render_overview(repo)
  local v = repo.overview
  if not v or not vim.api.nvim_buf_is_valid(v.buf) then return end
  local frames = { '|', '/', '-', '\\' }
  local fetch = repo.fetching and (' | ' .. frames[(repo.spinner_tick or 0) % #frames + 1] .. ' Fetching …') or (repo.fetch_error and ' | Fetch failed (E: details)' or '')
  local lines = { 'Worktrees' .. fetch, 'Enter open · a create · d remove · f fetch · p pull · P push · r refresh · q hide' }
  for _, ctx in ipairs(repo.worktrees) do
    local s = ctx.status
    local state = ctx.missing and 'Missing' or (ctx.locked and 'Locked' or (ctx.error and 'Status unavailable' or 'Loading …'))
    if s and not ctx.error and not ctx.missing then
      state = #s.entries == 0 and 'Clean' or ('+%d ~%d -%d · %d staged · %d unstaged'):format(s.added, s.changed, s.deleted, s.staged, s.unstaged)
      state = state .. ' · ' .. s.remote_label .. (s.operation and ' · ' .. s.operation or '')
      if ctx.locked then state = state .. ' · Locked: ' .. U.display(type(ctx.locked) == 'string' and ctx.locked or 'locked') end
    end
    local unsaved = #Context.unsaved(ctx)
    lines[#lines + 1] = ('%s %s · %s · %s%s · Copilot %s'):format(Context.active() == ctx and '>' or ' ', U.display(vim.fs.basename(ctx.root)),
      U.display(ctx.branch or 'Detached HEAD'), state, unsaved > 0 and (' · %d unsaved'):format(unsaved) or '', ctx.copilot and ctx.copilot.state or 'not started')
  end
  local selected = M.selected(repo)
  lines[#lines + 1] = ''
  if selected then
    vim.list_extend(lines, { 'Path: ' .. U.display(selected.root), 'Branch: ' .. U.display(selected.branch or 'Detached HEAD'),
      'Upstream: ' .. (selected.status and selected.status.upstream or 'none'),
      'Push remote: ' .. (selected.status and (selected.status.push_remote ~= '' and selected.status.push_remote or selected.status.remote) or 'none'),
      'Last successful fetch: ' .. (repo.fetch_time and os.date('%Y-%m-%d %H:%M:%S', repo.fetch_time) or 'unknown'), selected.error or '' })
  end
  U.set_lines(v.buf, lines)
  vim.api.nvim_buf_clear_namespace(v.buf, M.ns, 0, -1)
  for i, ctx in ipairs(repo.worktrees) do
    local s = ctx.status
    if ctx.error or ctx.missing then paint(v.buf, i + 2, 'DiagnosticError')
    elseif s and s.conflicts > 0 then paint(v.buf, i + 2, 'DiagnosticError')
    elseif s and s.added > 0 then paint(v.buf, i + 2, 'WorktreeReviewAdded')
    elseif s and s.deleted > 0 then paint(v.buf, i + 2, 'WorktreeReviewDeleted')
    elseif s and s.changed > 0 then paint(v.buf, i + 2, 'WorktreeReviewChanged') end
    local line = lines[i + 2]
    local start = line:find('%+%d+ ~%d+ %-%d+')
    if start then
      for _, part in ipairs({ { '%+%d+', 'WorktreeReviewAdded' }, { '~%d+', 'WorktreeReviewChanged' }, { '%-%d+', 'WorktreeReviewDeleted' } }) do
        local first, last = line:find(part[1], start)
        if first then vim.api.nvim_buf_add_highlight(v.buf, M.ns, part[2], i + 1, first - 1, last) end
      end
    end
  end
end
function M.overview(repo)
  local v = repo.overview
  if v and valid(v.win) then vim.api.nvim_set_current_win(v.win)
  else
    local b = v and vim.api.nvim_buf_is_valid(v.buf) and v.buf or U.scratch('worktrees')
    local width, height = math.max(20, vim.o.columns - 4), math.max(4, vim.o.lines - 6)
    local w = vim.api.nvim_open_win(b, true, { relative = 'editor', border = 'rounded', style = 'minimal', row = 1, col = 1, width = width, height = height, title = ' Worktree Review ' })
    repo.overview = { buf = b, win = w }
    common(b)
    map(b, '<CR>', function() local ctx = M.selected(repo); if ctx then M.hide_overview(repo); M.open(ctx) end end)
    map(b, 'q', function() M.hide_overview(repo) end)
    for key, action in pairs({ a = 'create', d = 'remove', f = 'fetch', p = 'pull', P = 'push' }) do
      map(b, key, function() require('worktree_review.actions')[action](M.selected(repo)) end)
    end
    map(b, 'E', function() U.details('Git details', repo.fetch_error or (M.selected(repo) or {}).error or 'No errors') end)
    map(b, 'r', function() require('worktree_review.refresh').overview(repo) end)
    vim.api.nvim_create_autocmd('CursorMoved', { buffer = b, callback = function() M.render_overview(repo) end })
  end
  M.render_overview(repo)
  require('worktree_review.refresh').overview(repo)
  if C.values.git.auto_fetch_on_overview then require('worktree_review.actions').fetch(repo.worktrees[1] or Context.get(repo, repo.root)) end
end
function M.hide_overview(repo)
  if repo.overview and valid(repo.overview.win) then vim.api.nvim_win_close(repo.overview.win, true) end
end
local function list_entry(ctx, entry)
  local b = B.find(ctx, entry.path)
  local mark = ctx.marked and ctx.marked[entry.group .. '\0' .. entry.path] and '*' or ' '
  local kind = entry.group == 'unstaged' and entry.y or entry.x
  local icon = entry.untracked and '+' or ({ A = '+', D = '-', R = 'R', C = 'C', U = '!' })[kind] or '~'
  return mark .. icon .. ' ' .. U.display(entry.old_path and (entry.old_path .. ' → ' .. entry.path) or entry.path)
    .. (entry.untracked and ' [Untracked]' or '') .. (entry.conflict and ' [Conflict]' or '')
    .. (b and vim.bo[b].modified and ' [Unsaved]' or '')
    .. (b and vim.b[b].worktree_review_external_conflict and ' [Externally changed]' or '')
end
function M.render_lists(ctx)
  if not ctx.ui then return end
  local v = ctx.ui
  local nav = { 'Current Changes', 'History' }
  for _, commit in ipairs(ctx.history or {}) do nav[#nav + 1] = commit.short .. ' ' .. U.display(commit.subject) end
  nav[#nav + 1] = '+ Load more'
  if ctx.status and not ctx.status.head then nav[2] = 'No commits yet' end
  U.set_lines(v.nav_buf, nav)
  local rows, entries = {}, {}
  if ctx.error then rows = { 'Status unavailable', ctx.error:gsub('\n.*', ''), 'r: retry' }
  elseif ctx.mode == 'commit' and ctx.commit then
    rows[1] = ctx.commit.short .. ' · ' .. (#ctx.commit.parents == 0 and 'initial commit' or 'Parent ' .. (ctx.parent_index or 1))
    for _, e in ipairs(ctx.commit_entries or {}) do rows[#rows + 1] = list_entry(ctx, e); entries[#rows] = e end
  else
    for _, group in ipairs({ 'conflict', 'staged', 'unstaged' }) do
      rows[#rows + 1] = ({ conflict = 'Conflicts', staged = 'Staged Changes', unstaged = 'Changes · Index → Working File' })[group]
      for _, original in ipairs(ctx.status and ctx.status.entries or {}) do
        if (group == 'conflict' and original.conflict) or (not original.conflict and ((group == 'staged' and not original.untracked and original.x ~= '.') or (group == 'unstaged' and (original.untracked or original.y ~= '.')))) then
          local e = vim.tbl_extend('force', original, { group = group })
          rows[#rows + 1] = list_entry(ctx, e); entries[#rows] = e
        end
      end
    end
  end
  v.file_rows = entries
  U.set_lines(v.files_buf, rows)
  vim.api.nvim_buf_clear_namespace(v.files_buf, M.ns, 0, -1)
  for row, entry in pairs(entries) do
    local kind = entry.group == 'unstaged' and entry.y or entry.x
    paint(v.files_buf, row, entry.conflict and 'DiagnosticError' or ((entry.untracked or kind == 'A') and 'WorktreeReviewAdded' or (kind == 'D' and 'WorktreeReviewDeleted' or 'WorktreeReviewChanged')))
    if ctx.selected and ctx.selected.path == entry.path and ctx.selected.group == entry.group and valid(v.files_win) then
      local current = vim.api.nvim_win_get_cursor(v.files_win)[1]
      if not entries[current] or entries[current].path ~= entry.path or entries[current].group ~= entry.group then vim.api.nvim_win_set_cursor(v.files_win, { row, 0 }) end
    end
  end
end
function M.selected_file(ctx)
  if ctx.ui and valid(ctx.ui.files_win) then return ctx.ui.file_rows[vim.api.nvim_win_get_cursor(ctx.ui.files_win)[1]] or ctx.selected end
  return ctx.selected
end
local function version_buffer(ctx, name, text, path, metadata)
  local b = U.scratch(name, U.lines(text))
  vim.b[b].worktree_review_context = ctx.id
  local ft = path and vim.filetype.match({ filename = path })
  if ft then vim.bo[b].filetype = ft end
  vim.bo[b].modifiable = true
  vim.bo[b].endofline = not (metadata and metadata.no_eol)
  vim.bo[b].fileformat = metadata and metadata.crlf and 'dos' or 'unix'
  vim.bo[b].modifiable = false
  vim.bo[b].modified = false
  return b
end
local function set_diff(ctx, left, right, left_label, right_label, special)
  local v = ctx.ui
  if not v or not valid(v.left) or not valid(v.right) then return end
  local views = {}
  if ctx.diff_key then
    for _, w in ipairs({ v.left, v.right }) do views[w] = vim.api.nvim_win_call(w, vim.fn.winsaveview) end
  end
  local old_virtual = v.virtual or {}
  v.virtual = {}
  for _, pair in ipairs({ { v.left, left, left_label }, { v.right, right, right_label } }) do
    local w, b, label = unpack(pair)
    if vim.api.nvim_win_get_buf(w) ~= b then vim.api.nvim_win_set_buf(w, b) end
    vim.wo[w].diff, vim.wo[w].scrollbind, vim.wo[w].cursorbind = not special, not special, not special
    vim.wo[w].foldmethod = special and 'manual' or 'diff'
    vim.wo[w].foldenable = false
    vim.wo[w].winfixbuf = false
    vim.wo[w].statusline = statusline(ctx, label, b)
    if vim.bo[b].buftype == 'nofile' then v.virtual[#v.virtual + 1] = b end
  end
  for _, b in ipairs(old_virtual) do
    if b ~= left and b ~= right and vim.api.nvim_buf_is_valid(b) then vim.api.nvim_buf_delete(b, {}) end
  end
  if not special then vim.api.nvim_win_call(v.right, function() vim.cmd('diffupdate') end) end
  for w, view in pairs(views) do vim.api.nvim_win_call(w, function() vim.fn.winrestview(view) end) end
end
function M.diff(ctx, entry, force)
  if not entry or not ctx.ui then return end
  local key = entry.group .. '\0' .. entry.path .. '\0' .. (ctx.commit and ctx.commit.oid or '') .. '\0' .. tostring(ctx.parent_index)
  if ctx.diff_key == key and not force then return end
  ctx.generation = ctx.generation + 1
  local generation = ctx.generation
  if ctx.diff_key ~= key then ctx.diff_key = nil end
  ctx.selected = entry
  U.task(function()
    local left_ref, right_ref, left_label, right_label
    local left_path = entry.old_path or entry.path
    if entry.group == 'staged' then left_ref, right_ref, left_label, right_label = ctx.status.head, ':', 'HEAD', 'Index (read only)'
    elseif entry.group == 'commit' then
      left_ref = ctx.commit.parents[ctx.parent_index or 1]
      right_ref, left_label, right_label = ctx.commit.oid, left_ref and ('Parent ' .. (ctx.parent_index or 1)) or 'Empty (root commit)', ctx.commit.short .. ' (read only)'
    else left_ref, left_label, right_label = entry.untracked and nil or ':', 'Index', 'Working File' end
    local ltext, lm = G.content(ctx, left_ref, left_path)
    local rtext, rm, right
    if right_ref then rtext, rm = G.content(ctx, right_ref, entry.path)
    else
      local special_mode = entry.mw == '120000' or entry.mi == '120000' or entry.mw == '160000' or (entry.sub and entry.sub:sub(1, 1) == 'S')
      if special_mode then rtext, rm = 'Symlink / submodule metadata. Open explicitly outside the review to edit.', { special = true }
      else
        local why
        right, why = B.open(ctx, entry.path)
        if not right then rtext, rm = why == 'missing' and '' or ('Working File: ' .. tostring(why)), { special = why ~= 'missing' } end
      end
    end
    if generation ~= ctx.generation or not ctx.ui or not valid(ctx.ui.right) then return end
    local metadata = (entry.mh and entry.mi and entry.mh ~= entry.mi) or (entry.mi and entry.mw and entry.mi ~= entry.mw)
    if metadata then left_label = left_label .. ' · mode ' .. (entry.mh or entry.mi); right_label = right_label .. ' · mode ' .. (entry.group == 'staged' and entry.mi or entry.mw or '?') end
    if lm.lfs then left_label = left_label .. ' · Git LFS pointer' end
    if rm and rm.lfs then right_label = right_label .. ' · Git LFS pointer' end
    if (lm.special or (rm and rm.special)) and not right then right_label = right_label .. ' · metadata' end
    local left = version_buffer(ctx, left_label, ltext, entry.path, lm)
    right = right or version_buffer(ctx, right_label, rtext or '', entry.path, rm)
    local special = lm.special or (rm and rm.special) or #U.lines(ltext) > C.values.review.large_file_lines and not ctx.load_large
    set_diff(ctx, left, right, left_label .. (lm.no_eol and ' · no final newline' or ''), right_label .. (rm and rm.no_eol and ' · no final newline' or ''), special)
    ctx.diff_key = key
  end)
end
function M.select_history(ctx, row)
  ctx.comparison_tick = (ctx.comparison_tick or 0) + 1
  local comparison_tick = ctx.comparison_tick
  U.task(function()
    if row == 1 then ctx.mode, ctx.commit = 'current', nil; ctx.commit_entries = nil
    elseif row == #(ctx.history or {}) + 3 then
      ctx.history_limit = ctx.history_limit + C.values.review.history_page_size
      local history = G.history(ctx, ctx.history_limit)
      if comparison_tick ~= ctx.comparison_tick then return end
      ctx.history = history
    else
      local commit = (ctx.history or {})[row - 2]
      if not commit then return end
      local files = G.commit_files(ctx, commit, commit.parents[1])
      if comparison_tick ~= ctx.comparison_tick then return end
      ctx.mode, ctx.commit, ctx.parent_index = 'commit', commit, 1
      ctx.commit_entries = files
    end
    ctx.diff_key, ctx.selected = nil, nil
    M.render_lists(ctx)
    local rows = vim.tbl_keys(ctx.ui.file_rows); table.sort(rows)
    if rows[1] then vim.api.nvim_win_set_cursor(ctx.ui.files_win, { rows[1], 0 }); M.diff(ctx, ctx.ui.file_rows[rows[1]])
    else M.empty(ctx) end
  end)
end
function M.empty(ctx)
  ctx.generation = ctx.generation + 1
  ctx.selected, ctx.diff_key = nil, nil
  set_diff(ctx, version_buffer(ctx, 'empty-left', ''), version_buffer(ctx, 'empty-right', 'No changes in this comparison.'), 'Old version', 'No changes', true)
end
function M.open(ctx)
  if ctx.tab and vim.api.nvim_tabpage_is_valid(ctx.tab) then
    vim.api.nvim_set_current_tabpage(ctx.tab)
    if ctx.ui and valid(ctx.ui.nav_win) and valid(ctx.ui.files_win) and valid(ctx.ui.left) and valid(ctx.ui.right) then
      require('worktree_review.refresh').request(ctx, true); return
    end
  else vim.cmd('tabnew'); ctx.tab = vim.api.nvim_get_current_tabpage() end
  vim.cmd('tcd ' .. vim.fn.fnameescape(ctx.root))
  -- Build in a fresh tab; real buffers are hidden, never deleted or written.
  local right = vim.api.nvim_get_current_win()
  vim.cmd('topleft vsplit'); local nav_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow vsplit'); local files_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(right); vim.cmd('leftabove vsplit'); local left = vim.api.nvim_get_current_win()
  local nav_buf, files_buf = U.scratch('navigation'), U.scratch('files')
  ctx.ui = { nav_win = nav_win, files_win = files_win, left = left, right = right, nav_buf = nav_buf, files_buf = files_buf, file_rows = {} }
  vim.api.nvim_win_set_buf(nav_win, nav_buf); vim.api.nvim_win_set_buf(files_win, files_buf)
  vim.api.nvim_win_set_width(nav_win, C.values.review.navigation_width)
  vim.api.nvim_win_set_width(files_win, C.values.review.files_width)
  for _, w in ipairs({ nav_win, files_win }) do vim.wo[w].wrap = false; vim.wo[w].number = false; vim.wo[w].relativenumber = false; vim.wo[w].winfixwidth = true end
  for _, b in ipairs({ nav_buf, files_buf }) do
    vim.b[b].worktree_review_context = ctx.id
    common(b, ctx)
    map(b, 'q', function() M.hide(ctx) end)
  end
  map(nav_buf, '<CR>', function() M.select_history(ctx, vim.api.nvim_win_get_cursor(nav_win)[1]) end)
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = nav_buf, callback = function()
    ctx.nav_tick = (ctx.nav_tick or 0) + 1; local tick = ctx.nav_tick
    vim.defer_fn(function()
      if tick == ctx.nav_tick and ctx.tab == vim.api.nvim_get_current_tabpage() and ctx.ui and vim.api.nvim_get_current_buf() == nav_buf then
        M.select_history(ctx, vim.api.nvim_win_get_cursor(nav_win)[1])
      end
    end, C.values.review.selection_delay_ms)
  end })
  map(nav_buf, '+', function() M.select_history(ctx, #(ctx.history or {}) + 3) end)
  map(nav_buf, 'i', function() if ctx.commit then U.details('Commit', ctx.commit.oid .. '\n' .. ctx.commit.author .. '\n' .. ctx.commit.date .. '\nParents: ' .. table.concat(ctx.commit.parents, ', ') .. '\n' .. ctx.commit.subject) end end)
  map(nav_buf, 'm', function()
    U.task(function()
      if not ctx.commit or #ctx.commit.parents < 2 then return end
      local parent = U.select(ctx.commit.parents, 'Compare merge commit against parent:')
      if not parent then return end
      for i, p in ipairs(ctx.commit.parents) do if p == parent then ctx.parent_index = i end end
      ctx.commit_entries = G.commit_files(ctx, ctx.commit, parent); ctx.diff_key = nil; M.render_lists(ctx)
      M.diff(ctx, M.selected_file(ctx), true)
    end)
  end)
  map(files_buf, '<CR>', function() M.diff(ctx, M.selected_file(ctx)); vim.api.nvim_set_current_win(right) end)
  for key, action in pairs({ s = 'stage', u = 'unstage', e = 'edit', S = 'stage_marked', U = 'unstage_marked' }) do map(files_buf, key, function() require('worktree_review.actions')[action](ctx) end) end
  map(files_buf, '<Space>', function()
    local e = M.selected_file(ctx); if not e then return end
    ctx.marked = ctx.marked or {}; local key = e.group .. '\0' .. e.path
    ctx.marked[key] = ctx.marked[key] and nil or e
    M.render_lists(ctx)
  end)
  map(files_buf, 'L', function() ctx.load_large = true; M.diff(ctx, M.selected_file(ctx), true) end)
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = files_buf, callback = function()
    ctx.selection_tick = (ctx.selection_tick or 0) + 1; local tick = ctx.selection_tick
    vim.defer_fn(function() if tick == ctx.selection_tick and ctx.tab == vim.api.nvim_get_current_tabpage() and ctx.ui then M.diff(ctx, M.selected_file(ctx)) end end, C.values.review.selection_delay_ms)
  end })
  vim.api.nvim_set_current_win(files_win)
  M.empty(ctx)
  require('worktree_review.refresh').watch(ctx)
  require('worktree_review.refresh').request(ctx, true)
end
function M.hide(ctx)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab ~= ctx.tab then vim.api.nvim_set_current_tabpage(tab); return end
  end
  vim.cmd('tabnew')
end
function M.refresh(ctx)
  if not ctx.ui then return end
  M.render_lists(ctx)
  local selected
  for _, entry in pairs(ctx.ui.file_rows) do
    if ctx.selected and entry.path == ctx.selected.path and entry.group == ctx.selected.group then selected = entry; break end
  end
  if selected then M.diff(ctx, selected, true)
  elseif ctx.selected then U.notify('Selected file is no longer in this comparison.'); M.empty(ctx)
  else
    local rows = vim.tbl_keys(ctx.ui.file_rows); table.sort(rows)
    if rows[1] then M.diff(ctx, ctx.ui.file_rows[rows[1]], true) else M.empty(ctx) end
  end
end
return M
