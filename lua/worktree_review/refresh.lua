local U = require('worktree_review.util')
local G = require('worktree_review.git')
local Context = require('worktree_review.context')
local C = require('worktree_review.config')
local M = {}
local function shown(ctx) return ctx.tab and ctx.tab == vim.api.nvim_get_current_tabpage() end
local function overview_shown(repo) return repo.overview and repo.overview.win and vim.api.nvim_win_is_valid(repo.overview.win) end
function M.request(ctx, immediate)
  if not ctx then local current = Context.active(); if current then M.request(current, immediate) end; return end
  if ctx.refreshing then ctx.refresh_again = true; return end
  ctx.refresh_tick = (ctx.refresh_tick or 0) + 1
  local tick = ctx.refresh_tick
  local function read()
    if tick ~= ctx.refresh_tick or ctx.missing then return end
    ctx.refreshing = true
    U.task(function()
      require('worktree_review.buffers').check(ctx)
      local previous = ctx.last_status_fingerprint
      local s = G.status(ctx)
      ctx.branch = s.branch == '(detached)' and nil or s.branch
      ctx.history = G.history(ctx, ctx.history_limit)
      if ctx.mode == 'commit' and ctx.commit then
        local ok, entries = pcall(G.commit_files, ctx, ctx.commit, ctx.commit.parents[ctx.parent_index or 1])
        if ok then ctx.commit_entries = entries
        else ctx.mode, ctx.commit = 'current', nil; U.notify('Historical comparison unavailable; showing Current Changes.') end
      end
      ctx.refreshing = false
      local changed = previous ~= vim.inspect(s)
      ctx.last_status_fingerprint = vim.inspect(s)
      if shown(ctx) and ctx.ui then
        local b = ctx.ui.right and vim.api.nvim_win_is_valid(ctx.ui.right) and vim.api.nvim_win_get_buf(ctx.ui.right)
        local content_tick = b and vim.api.nvim_buf_get_changedtick(b)
        local content_changed = content_tick ~= ctx.last_content_tick
        ctx.last_content_tick = content_tick
        if changed or content_changed or ctx.force_refresh then require('worktree_review.ui').refresh(ctx)
        else require('worktree_review.ui').render_lists(ctx) end
      end
      ctx.force_refresh = nil
      require('worktree_review.ui').render_overview(ctx.repo)
      if ctx.commit_window and vim.api.nvim_win_is_valid(ctx.commit_window) then
        local index = G.text(ctx.root, { 'write-tree' }, true)
        vim.api.nvim_win_set_config(ctx.commit_window, { title = ' Commit · ' .. U.display(s.branch) .. ' · ' .. s.staged .. ' staged' .. (index ~= ctx.commit_index and ' · Staging changed' or '') .. ' ' })
      end
      if ctx.refresh_again then ctx.refresh_again = false; M.request(ctx) end
    end, function(err)
      ctx.refreshing, ctx.error = false, err
      require('worktree_review.ui').render_overview(ctx.repo)
      if shown(ctx) then require('worktree_review.ui').render_lists(ctx) end
    end)
  end
  if immediate then ctx.force_refresh = true; read() else vim.defer_fn(read, C.values.refresh.debounce_ms) end
end
function M.overview(repo)
  if repo.listing then repo.list_again = true; return end
  repo.listing = true
  U.task(function()
    Context.list(repo)
    require('worktree_review.ui').render_overview(repo)
    -- Sequential reads bound process concurrency even for repositories with many worktrees.
    for _, ctx in ipairs(repo.worktrees) do
      if not ctx.missing then
        local ok, err = pcall(G.status, ctx)
        if not ok then ctx.error = tostring(err) end
        require('worktree_review.ui').render_overview(repo)
      end
    end
    repo.listing = false
    if repo.list_again then repo.list_again = false; M.overview(repo) end
  end, function(err) repo.listing = false; repo.last_error = err; U.notify(err, vim.log.levels.ERROR) end)
end
function M.invalidate(repo)
  M.overview(repo)
  for _, ctx in pairs(repo.contexts) do if shown(ctx) then M.request(ctx, true) end end
end
function M.watch(ctx)
  if not C.values.refresh.watch_files or ctx.watchers then return end
  ctx.watchers = {}
  local dirs = { ctx.root, ctx.git_dir, ctx.repo.id }
  for _, dir in ipairs(dirs) do
    if dir then
      local watcher = U.uv.new_fs_event()
      local ok = watcher:start(dir, {}, vim.schedule_wrap(function() if shown(ctx) then M.request(ctx) end end))
      if ok then ctx.watchers[#ctx.watchers + 1] = watcher else watcher:close() end
    end
  end
end
function M.stop(ctx)
  for _, watcher in ipairs(ctx.watchers or {}) do watcher:stop(); watcher:close() end
  ctx.watchers = nil
  ctx.generation = ctx.generation + 1
end
function M.setup()
  if M.timer then M.timer:stop(); M.timer:close() end
  if M.spinner then M.spinner:stop(); M.spinner:close() end
  M.spinner = U.uv.new_timer()
  M.spinner:start(150, 150, vim.schedule_wrap(function()
    for _, repo in pairs(Context.repos) do
      if repo.fetching and overview_shown(repo) then
        repo.spinner_tick = (repo.spinner_tick or 0) + 1
        require('worktree_review.ui').render_overview(repo)
      end
    end
  end))
  M.timer = U.uv.new_timer()
  M.timer:start(C.values.refresh.poll_interval_ms, C.values.refresh.poll_interval_ms, vim.schedule_wrap(function()
    for _, repo in pairs(Context.repos) do if overview_shown(repo) then M.overview(repo) end end
    local ctx = Context.active(); if ctx then M.request(ctx) end
  end))
  local group = vim.api.nvim_create_augroup('WorktreeReviewRefresh', { clear = true })
  vim.api.nvim_create_autocmd({ 'FocusGained', 'TabEnter', 'BufWritePost', 'TermClose' }, { group = group, callback = function() M.request(Context.active(), true) end })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, { group = group, callback = function(event)
    -- Redrawing immutable navigation lists must never start a refresh loop.
    if vim.bo[event.buf].buftype == '' then
      local id = vim.b[event.buf].worktree_review_context
      M.request(id and Context.contexts[id] or Context.active())
    end
  end })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = function()
    M.timer:stop(); M.timer:close(); M.timer = nil
    M.spinner:stop(); M.spinner:close(); M.spinner = nil
    for _, ctx in pairs(Context.contexts) do
      M.stop(ctx)
      if ctx.copilot and ctx.copilot.state == 'running' then U.notify('Stopping Copilot in ' .. ctx.root); vim.fn.jobstop(ctx.copilot.job) end
    end
  end })
end
return M
