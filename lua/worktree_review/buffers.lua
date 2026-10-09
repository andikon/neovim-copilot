local U = require('worktree_review.util')
local M = { tracked = {} }
function M.disk(path)
  local stat = U.uv.fs_lstat(path)
  if not stat then return nil, 'missing' end
  if stat.type ~= 'file' then return nil, stat.type end
  local fd = U.uv.fs_open(path, 'r', 438)
  if not fd then return nil, 'unreadable' end
  local data = U.uv.fs_read(fd, stat.size, 0)
  U.uv.fs_close(fd)
  if not data then return nil, 'unreadable' end
  return data, vim.fn.sha256(data)
end
function M.find(ctx, path)
  local full = U.norm(ctx.root .. '/' .. path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[b].buftype == '' and U.norm(vim.api.nvim_buf_get_name(b)) == full then return b end
  end
end
function M.reload(b, data)
  local views = {}
  for _, w in ipairs(vim.fn.win_findbuf(b)) do views[w] = vim.api.nvim_win_call(w, vim.fn.winsaveview) end
  vim.api.nvim_buf_call(b, function() vim.cmd('silent edit!') end)
  for w, view in pairs(views) do if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_call(w, function() vim.fn.winrestview(view) end) end end
  local t = M.tracked[b]
  if t then local _, stamp = M.disk(t.path); t.stamp, t.conflict = stamp, nil end
  vim.b[b].worktree_review_external_conflict = nil
  vim.b[b].worktree_review_missing = nil
end
function M.resolve(b)
  local t = M.tracked[b]
  if not t then return true end
  local data, stamp = M.disk(t.path)
  if stamp == 'unreadable' then U.notify('Cannot read external file: ' .. t.path, vim.log.levels.ERROR); return false end
  if stamp == t.stamp then return true end
  t.conflict = true
  vim.b[b].worktree_review_external_conflict = true
  local answer = vim.fn.confirm('Externally changed: ' .. t.path .. '\nUnsaved editor text differs from the observed disk version.', '&Keep editor content\n&Reload file\n&Cancel', 3)
  if answer == 1 then
    -- Acknowledgement belongs to precisely this disk version, never a future edit.
    t.stamp, t.conflict = stamp, nil
    t.overwrite_stamp = stamp
    vim.b[b].worktree_review_external_conflict = nil
    return true
  elseif answer == 2 then
    local latest, latest_stamp = M.disk(t.path)
    if latest == nil then U.notify('File is missing or unreadable; editor content was retained.'); return false end
    M.reload(b, latest)
    t.stamp = latest_stamp
  end
  return false
end
function M.track(ctx, b, path)
  if not M.tracked[b] then
    local _, stamp = M.disk(path)
    M.tracked[b] = { path = path, stamp = stamp, ctx = ctx }
    vim.b[b].worktree_review_context = ctx.id
    local group = vim.api.nvim_create_augroup('WorktreeReviewBuffer' .. b, { clear = true })
    vim.api.nvim_create_autocmd('FileChangedShell', { group = group, buffer = b, callback = function()
      -- Neovim's timestamp checks defer to the same version-scoped conflict policy.
      vim.v.fcs_choice = ''
      vim.schedule(function() if vim.api.nvim_buf_is_valid(b) then M.check(ctx) end end)
    end })
    local install_writer
    install_writer = function()
      if not vim.api.nvim_buf_is_valid(b) then return end
      local id
      id = vim.api.nvim_create_autocmd('BufWriteCmd', { group = group, buffer = b, nested = true, callback = function(event)
        local t = M.tracked[b]
        if not M.resolve(b) then error('Write cancelled: external file change requires a decision', 0) end
        local _, observed = M.disk(t.path)
        local force = vim.v.cmdbang == 1 or (t.overwrite_stamp and t.overwrite_stamp == observed)
        local target = event.file
        local current = vim.api.nvim_buf_get_name(b)
        local extra = target ~= '' and U.norm(target) ~= U.norm(current) and (' ' .. vim.fn.fnameescape(target)) or ''
        -- Delegate to the native writer after removing only our own handler.
        -- nested=true preserves user BufWritePre formatters and BufWritePost hooks.
        vim.api.nvim_del_autocmd(id)
        local ok, err = pcall(vim.api.nvim_buf_call, b, function() vim.cmd('write' .. (force and '!' or '') .. extra) end)
        install_writer()
        if not ok then error(err, 0) end
      end })
    end
    install_writer()
    vim.api.nvim_create_autocmd('BufWritePre', { group = group, buffer = b, callback = function()
      if not M.resolve(b) then error('Write cancelled: external file change requires a decision', 0) end
    end })
    vim.api.nvim_create_autocmd('BufWritePost', { group = group, buffer = b, callback = function()
      local t = M.tracked[b]
      if t then local _, stamp2 = M.disk(t.path); t.stamp, t.conflict, t.overwrite_stamp = stamp2, nil, nil end
      require('worktree_review.refresh').request(ctx)
    end })
    vim.api.nvim_create_autocmd('BufWipeout', { group = group, buffer = b, callback = function() M.tracked[b] = nil end })
  end
end
function M.open(ctx, path)
  local full = ctx.root .. '/' .. path
  local c = require('worktree_review.config').values.review
  local stat = U.uv.fs_lstat(full)
  if stat and stat.type == 'file' and stat.size > c.large_file_bytes and not ctx.load_large then return nil, 'Large file. Press L to load explicitly.' end
  local data, stamp = M.disk(full)
  if not data then return nil, stamp end
  if data:find('\0', 1, true) then return nil, 'Binary file' end
  if not ctx.load_large and (#data > c.large_file_bytes or #U.lines(data) > c.large_file_lines) then return nil, 'Large file. Press L to load explicitly.' end
  local b = M.find(ctx, path) or vim.fn.bufadd(full)
  vim.fn.bufload(b)
  if not vim.bo[b].endofline then vim.bo[b].fixendofline = false end
  vim.bo[b].bufhidden = 'hide'
  M.track(ctx, b, full)
  return b
end
function M.check(ctx)
  for b, t in pairs(M.tracked) do
    if t.ctx == ctx and vim.api.nvim_buf_is_valid(b) then
      local data, stamp = M.disk(t.path)
      if stamp ~= t.stamp then
        if vim.bo[b].modified then
          if not t.conflict then t.conflict = true; vim.b[b].worktree_review_external_conflict = true; M.resolve(b) end
        elseif data then M.reload(b, data)
        else
          -- A clean buffer for a removed file is retained, but is not an
          -- unresolved editor/disk conflict and must not block clean removal.
          t.conflict = nil
          vim.b[b].worktree_review_external_conflict = nil
          vim.b[b].worktree_review_missing = true
        end
      end
    end
  end
end
return M
