local U = require('worktree_review.util')
local G = require('worktree_review.git')
local M = { repos = {}, contexts = {} }
function M.discover(path)
  local root = G.text(path, { 'rev-parse', '--show-toplevel' })
  local common = G.text(root, { 'rev-parse', '--path-format=absolute', '--git-common-dir' })
  local id = U.norm(common)
  local repo = M.repos[id]
  if not repo then repo = { id = id, root = root, contexts = {}, worktrees = {} }; M.repos[id] = repo end
  return repo, root
end
function M.get(repo, root)
  local id = repo.id .. '|' .. U.norm(root)
  if not M.contexts[id] then
    M.contexts[id] = { id = id, root = root, repo = repo, generation = 0, mode = 'current', history_limit = require('worktree_review.config').values.review.history_page_size }
    repo.contexts[U.norm(root)] = M.contexts[id]
  end
  return M.contexts[id]
end
function M.list(repo)
  local entries = G.parse_worktrees(G.run(repo.root, { 'worktree', 'list', '--porcelain', '-z' }))
  if entries[1] and not entries[1].bare then repo.root = entries[1].root end
  repo.worktrees = {}
  for i, entry in ipairs(entries) do
    if not entry.bare then
      local ctx = M.get(repo, entry.root)
      ctx.main, ctx.locked, ctx.prunable, ctx.branch = i == 1, entry.locked, entry.prunable, entry.branch
      ctx.missing = U.uv.fs_stat(ctx.root) == nil
      repo.worktrees[#repo.worktrees + 1] = ctx
    end
  end
  return repo.worktrees
end
function M.active()
  local tab = vim.api.nvim_get_current_tabpage()
  for _, ctx in pairs(M.contexts) do if ctx.tab == tab then return ctx end end
end
function M.start_path()
  local b = vim.api.nvim_get_current_buf()
  local id = vim.b[b].worktree_review_context
  if id and M.contexts[id] then return M.contexts[id].root end
  local name = vim.api.nvim_buf_get_name(b)
  if vim.bo[b].buftype == '' and name ~= '' then return vim.fs.dirname(name) end
  return vim.fn.getcwd()
end
function M.unsaved(ctx)
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name ~= '' and vim.bo[b].buftype == '' and vim.bo[b].modified and U.inside(name, ctx.root) then out[#out + 1] = b end
  end
  return out
end
return M
