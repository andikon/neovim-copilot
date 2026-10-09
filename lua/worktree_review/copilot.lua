local C = require('worktree_review.config')
local U = require('worktree_review.util')
local M = {}
local function ps_quote(s) return "'" .. s:gsub("'", "''") .. "'" end
function M.command()
  local c = C.values.copilot
  if vim.fn.has('win32') == 1 then
    local shell = c.shell
    if shell == 'auto' then shell = vim.fn.executable('pwsh') == 1 and 'pwsh' or 'powershell' end
    assert(vim.fn.executable(shell) == 1, 'PowerShell executable missing: ' .. shell)
    local quoted = {}; for _, arg in ipairs(c.command) do quoted[#quoted + 1] = ps_quote(arg) end
    return { shell, '-NoLogo', '-NoProfile', '-Command', '& ' .. table.concat(quoted, ' ') .. '; if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }' }
  end
  return vim.deepcopy(c.command)
end
function M.toggle(ctx, restart)
  if not ctx then U.notify('Open a worktree first.'); return end
  if not C.values.copilot.enabled then U.notify('Copilot is disabled in configuration.'); return end
  local session = ctx.copilot
  if session and session.win and vim.api.nvim_win_is_valid(session.win) and not restart then vim.api.nvim_win_close(session.win, true); session.win = nil; return end
  if restart then
    if session and session.state == 'running' then U.notify('Stop the running session before restarting.'); return end
    if session and session.win and vim.api.nvim_win_is_valid(session.win) then vim.api.nvim_win_close(session.win, true) end
    if session and vim.api.nvim_buf_is_valid(session.buf) then vim.api.nvim_buf_delete(session.buf, {}) end
    ctx.copilot, session = nil, nil
  end
  if not ctx.tab or not vim.api.nvim_tabpage_is_valid(ctx.tab) then require('worktree_review.ui').open(ctx) end
  vim.api.nvim_set_current_tabpage(ctx.tab)
  if not session then
    if vim.fn.executable(C.values.copilot.command[1]) ~= 1 then U.notify('Copilot executable not found: ' .. C.values.copilot.command[1] .. '\nWorktree: ' .. ctx.root, vim.log.levels.ERROR); return end
    session = { buf = vim.api.nvim_create_buf(false, true), state = 'starting' }; ctx.copilot = session
    vim.bo[session.buf].bufhidden = 'hide'
    vim.b[session.buf].worktree_review_context = ctx.id
  end
  vim.cmd('botright split')
  session.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(session.win, math.max(3, math.floor(vim.o.lines * C.values.copilot.height_ratio)))
  vim.api.nvim_win_set_buf(session.win, session.buf)
  vim.wo[session.win].statusline = (' Copilot · %s '):format(U.display(ctx.root)):gsub('%%', '%%%%')
  if not session.job then
    local ok, result = pcall(function()
      return vim.fn.termopen(M.command(), { cwd = ctx.root, on_exit = function(_, code)
        vim.schedule(function() session.state, session.exit_code = 'exited', code; require('worktree_review.ui').render_overview(ctx.repo) end)
      end })
    end)
    if ok and result > 0 then session.job, session.state = result, 'running'
    else session.state = 'start failed'; U.notify('Copilot start failed in ' .. ctx.root .. ': ' .. tostring(result), vim.log.levels.ERROR) end
  end
  if session.state == 'running' then vim.cmd('startinsert') end
end
function M.stop(ctx)
  if not ctx or not ctx.copilot or ctx.copilot.state ~= 'running' then U.notify('No running Copilot session in this worktree.'); return end
  U.task(function()
    if U.select({ 'Stop session', 'Cancel' }, 'Stop Copilot in ' .. ctx.root .. '?') == 'Stop session' then vim.fn.jobstop(ctx.copilot.job) end
  end)
end
function M.enlarge(ctx)
  if ctx and ctx.copilot and ctx.copilot.win and vim.api.nvim_win_is_valid(ctx.copilot.win) then
    local w = ctx.copilot.win
    local height = vim.api.nvim_win_get_height(w)
    vim.api.nvim_win_set_height(w, height > vim.o.lines * 0.6 and math.max(3, math.floor(vim.o.lines * C.values.copilot.height_ratio)) or math.max(3, vim.o.lines - 8))
  end
end
return M
