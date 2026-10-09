local M = { initialized = false }
local commands = { 'changes', 'worktrees', 'create', 'remove', 'refresh', 'fetch', 'pull', 'push', 'stage', 'unstage', 'commit', 'edit', 'copilot', 'copilot-stop', 'copilot-restart', 'copilot-enlarge', 'details' }
function M.setup(opts)
  assert(vim.fn.has('nvim-0.10') == 1, 'Worktree Review requires Neovim 0.10 or newer (vim.system)')
  require('worktree_review.config').setup(opts)
  M.initialized = true
  for group, link in pairs({ WorktreeReviewAdded = 'DiffAdd', WorktreeReviewChanged = 'DiffChange', WorktreeReviewDeleted = 'DiffDelete' }) do
    vim.api.nvim_set_hl(0, group, { default = true, link = link })
  end
  require('worktree_review.refresh').setup()
  vim.api.nvim_create_user_command('WorktreeReview', function(args) M.command(args.args) end, { nargs = '?', complete = function(prefix) return vim.tbl_filter(function(cmd) return cmd:sub(1, #prefix) == prefix end, commands) end, force = true })
  if require('worktree_review.config').values.keymaps.global then
    vim.keymap.set('n', '<leader>gw', function() M.command('worktrees') end, { desc = 'Worktree Review' })
    vim.keymap.set('n', '<leader>ga', function() M.command('copilot') end, { desc = 'Worktree Copilot' })
  end
end
function M.command(cmd)
  if not M.initialized then M.setup() end
  cmd = cmd == '' and 'worktrees' or cmd or 'worktrees'
  local U = require('worktree_review.util')
  local Context = require('worktree_review.context')
  local UI = require('worktree_review.ui')
  U.task(function()
    local ctx = Context.active()
    -- An overview row, rather than the tab underneath the floating overview, is the target.
    for _, repo in pairs(Context.repos) do
      if repo.overview and repo.overview.win == vim.api.nvim_get_current_win() then ctx = UI.selected(repo); break end
    end
    if not ctx then
      local repo, root = Context.discover(Context.start_path())
      Context.list(repo)
      ctx = Context.get(repo, root)
    end
    if cmd == 'worktrees' then
      Context.list(ctx.repo)
      UI.overview(ctx.repo)
      if #ctx.repo.worktrees == 1 and not ctx.repo.setup_notice and require('worktree_review.config').values.worktrees.show_setup_notice then
        ctx.repo.setup_notice = true
        U.notify('Your existing checkout stays in place. New feature worktrees are created beside it; no files or changes are moved.')
      end
    elseif cmd == 'changes' then UI.hide_overview(ctx.repo); UI.open(ctx)
    elseif cmd == 'refresh' then require('worktree_review.refresh').invalidate(ctx.repo)
    elseif cmd == 'copilot' then require('worktree_review.copilot').toggle(ctx)
    elseif cmd == 'copilot-stop' then require('worktree_review.copilot').stop(ctx)
    elseif cmd == 'copilot-restart' then require('worktree_review.copilot').toggle(ctx, true)
    elseif cmd == 'copilot-enlarge' then require('worktree_review.copilot').enlarge(ctx)
    elseif cmd == 'details' then U.details('Git details', ctx.error or ctx.repo.last_error or ctx.repo.fetch_error or 'No recorded errors')
    elseif require('worktree_review.actions')[cmd] then require('worktree_review.actions')[cmd](ctx)
    else U.notify('Unknown WorktreeReview action: ' .. cmd, vim.log.levels.ERROR) end
  end, function(err)
    U.notify('Cannot open Worktree Review. Open a file or directory inside a Git repository.\n' .. err, vim.log.levels.ERROR)
  end)
end
return M
