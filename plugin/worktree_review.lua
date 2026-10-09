if vim.g.loaded_worktree_review then return end
vim.g.loaded_worktree_review = true
if vim.fn.exists(':WorktreeReview') == 2 then return end
vim.api.nvim_create_user_command('WorktreeReview', function(args)
  require('worktree_review').command(args.args)
end, { nargs = '?', complete = function()
  return { 'changes', 'worktrees', 'create', 'remove', 'refresh', 'fetch', 'pull', 'push', 'stage', 'unstage', 'commit', 'edit', 'copilot', 'copilot-stop', 'copilot-restart', 'copilot-enlarge', 'details' }
end })
