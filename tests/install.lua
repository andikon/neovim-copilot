-- Tests real vim.pack installation from a temporary committed source copy.
-- Run from the plugin repository: nvim --headless -u NONE -l tests/install.lua
local root = vim.fn.getcwd()
local uv = vim.uv or vim.loop
local fixture = vim.fn.tempname() .. '-worktree-review-install'
vim.fn.mkdir(fixture .. '/source', 'p')
local function run(cmd)
  local r = vim.system(cmd, { text = true }):wait()
  assert(r.code == 0, r.stderr or r.stdout)
  return r.stdout
end
local function copy(dir)
  local scan = assert(uv.fs_scandir(root .. '/' .. dir))
  vim.fn.mkdir(fixture .. '/source/' .. dir, 'p')
  while true do
    local name, kind = uv.fs_scandir_next(scan); if not name then break end
    local rel = dir .. '/' .. name
    if kind == 'directory' then copy(rel)
    elseif name ~= 'tags' then
      assert(uv.fs_copyfile(root .. '/' .. rel, fixture .. '/source/' .. rel))
    end
  end
end
local ok, err = xpcall(function()
  for _, dir in ipairs({ 'lua', 'plugin', 'doc' }) do copy(dir) end
  local source = fixture .. '/source'
  for _, args in ipairs({ { 'init', '-b', 'main' }, { 'add', '-A' },
    { '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-m', 'Install fixture' } }) do
    local cmd = { 'git', '-C', source }; vim.list_extend(cmd, args); run(cmd)
  end
  -- Child process gets isolated stdpaths before Neovim starts; no user's config
  -- or installed plugin directories are changed.
  local script = fixture .. '/check.lua'
  vim.fn.writefile({
    'vim.pack.add({ { src = ' .. string.format('%q', source:gsub('\\', '/')) .. ', name = "worktree-review-install" } }, { confirm = false })',
    'assert(vim.fn.exists(":WorktreeReview") == 2, "Plugin command was not auto-loaded")',
    'require("worktree_review").setup({ copilot = { enabled = false } })',
    'assert(require("worktree_review").initialized)',
    'assert(#vim.api.nvim_get_runtime_file("doc/worktree-review.txt", false) == 1)',
    'vim.cmd("checkhealth worktree_review")',
    'print("PASS real vim.pack installation, command loading, setup, help and health")',
    'vim.cmd("qa!")',
  }, script)
  local env = {}
  for _, key in ipairs({ 'XDG_DATA_HOME', 'XDG_CONFIG_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME' }) do env[key] = fixture .. '/' .. key end
  local result = vim.system({ vim.v.progpath, '--headless', '-u', 'NONE', '-l', script }, { text = true, env = env }):wait(30000)
  assert(result.code == 0, (result.stderr or '') .. (result.stdout or ''))
  print(result.stderr ~= '' and result.stderr or result.stdout)
end, debug.traceback)
assert(fixture:match('%-worktree%-review%-install$') and fixture ~= root)
assert(vim.fn.delete(fixture, 'rf') == 0, 'Cannot remove install fixture: ' .. fixture)
if not ok then io.stderr:write(err .. '\n'); vim.cmd('cquit 1') end
vim.cmd('qa!')
