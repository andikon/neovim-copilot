local M = {}
function M.check()
  local h = vim.health
  local c = require('worktree_review.config').values
  h.start('Worktree Review')
  if vim.fn.has('nvim-0.10') == 1 then h.ok('Neovim supports vim.system and native terminals') else h.error('Neovim 0.10+ is required') end
  if vim.fn.executable(c.git.executable) == 1 then
    local r = vim.system({ c.git.executable, '--version' }, { text = true }):wait()
    if r.code == 0 then h.ok(vim.trim(r.stdout)) else h.error(r.stderr) end
  else h.error('Git executable missing: ' .. c.git.executable) end
  if not c.copilot.enabled then h.info('Copilot disabled; Git features remain available')
  elseif vim.fn.executable(c.copilot.command[1]) == 1 then h.ok('Copilot executable: ' .. vim.fn.exepath(c.copilot.command[1]))
  else h.warn('Copilot executable missing; Git features remain available') end
  if vim.fn.has('win32') == 1 and c.copilot.enabled then
    local shell = c.copilot.shell == 'auto' and (vim.fn.executable('pwsh') == 1 and 'pwsh' or 'powershell') or c.copilot.shell
    if vim.fn.executable(shell) == 1 then
      h.ok('PowerShell: ' .. vim.fn.exepath(shell))
      local r = vim.system({ shell, '-NoLogo', '-NoProfile', '-Command', '$PSVersionTable.PSVersion.Major' }, { text = true }):wait()
      if r.code ~= 0 or (tonumber(vim.trim(r.stdout or '')) or 0) < 6 then h.warn('GitHub Copilot CLI requires PowerShell 6+. Configure copilot.shell to a supported PowerShell.') end
    else h.warn('PowerShell missing: ' .. shell) end
    h.info('Use :WorktreeReview copilot to verify your interactive CLI login and terminal on this machine.')
  end
  h.info('Configuration has no required Lua plugin dependencies. vim.pack installation requires Neovim 0.12+.')
end
return M
