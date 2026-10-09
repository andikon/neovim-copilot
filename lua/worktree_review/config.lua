local M = {}
M.defaults = {
  git = { executable = 'git', auto_fetch_on_overview = true, fetch_prune = true, pull_strategy = 'ff-only' },
  worktrees = { location = 'sibling', preserve_session_state = true, show_setup_notice = true },
  review = { history_page_size = 100, selection_delay_ms = 80, navigation_width = 26, files_width = 32,
    large_file_bytes = 2 * 1024 * 1024, large_file_lines = 50000 },
  refresh = { watch_files = true, debounce_ms = 200, poll_interval_ms = 2000 },
  copilot = { enabled = true, command = { 'copilot' }, shell = 'auto', position = 'bottom', height_ratio = 0.30 },
  keymaps = { global = false, local_defaults = true },
}
M.values = vim.deepcopy(M.defaults)
function M.setup(opts)
  opts = opts or {}
  local function check(value, defaults, prefix)
    for key, item in pairs(value) do
      local field = prefix .. key
      if defaults[key] == nil then
        assert(field == 'git.default_remote', 'Unknown configuration field: ' .. field)
        assert(type(item) == 'string', field .. ' must be a string')
      elseif type(defaults[key]) == 'table' and key ~= 'command' then
        assert(type(item) == 'table', field .. ' must be a table')
        check(item, defaults[key], field .. '.')
      else
        assert(type(item) == type(defaults[key]), field .. ' must be a ' .. type(defaults[key]))
      end
    end
  end
  check(opts, M.defaults, '')
  local c = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts)
  assert(c.git.pull_strategy == 'ff-only', 'git.pull_strategy must be ff-only')
  assert(c.worktrees.location == 'sibling', 'worktrees.location must be sibling')
  assert(c.copilot.position == 'bottom', 'copilot.position must be bottom')
  assert(#c.copilot.command > 0, 'copilot.command must contain an executable')
  for _, arg in ipairs(c.copilot.command) do assert(type(arg) == 'string', 'copilot.command must contain strings') end
  assert(c.copilot.height_ratio > 0 and c.copilot.height_ratio < 1, 'copilot.height_ratio must be between 0 and 1')
  for _, key in ipairs({ 'history_page_size', 'navigation_width', 'files_width', 'large_file_bytes', 'large_file_lines' }) do
    assert(c.review[key] >= 1, 'review.' .. key .. ' must be positive')
  end
  assert(c.review.selection_delay_ms >= 0 and c.refresh.debounce_ms >= 0, 'Delays must be nonnegative')
  assert(c.refresh.poll_interval_ms >= 100, 'refresh.poll_interval_ms must be at least 100')
  M.values = c
  return c
end
return M
