local M = {}
local errors = setmetatable({}, { __mode = 'k' })
M.uv = vim.uv or vim.loop
function M.norm(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p')):gsub('/$', '')
  if vim.fn.has('win32') == 1 then path = path:lower() end
  return path
end
function M.inside(path, root)
  path, root = M.norm(path), M.norm(root)
  return path == root or path:sub(1, #root + 1) == root .. '/'
end
function M.display(s) return (s or ''):gsub('[\r\n\t]', function(c) return ({ ['\r'] = '\\r', ['\n'] = '\\n', ['\t'] = '\\t' })[c] end) end
function M.nul(s)
  local out = {}
  for part in (s or ''):gmatch('([^%z]*)%z') do out[#out + 1] = part end
  return out
end
function M.notify(msg, level) vim.notify(msg, level or vim.log.levels.INFO, { title = 'Worktree Review' }) end
function M.task(fn, on_error)
  local co = coroutine.create(fn)
  errors[co] = on_error
  local function step(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then
      if on_error then on_error(tostring(err)) else M.notify(tostring(err), vim.log.levels.ERROR) end
    end
  end
  step()
  return co
end
function M.await(register)
  local co = coroutine.running()
  assert(co, 'Async operation requires util.task')
  register(function(...)
    local args = { ... }
    vim.schedule(function()
      local ok, err = coroutine.resume(co, unpack(args))
      if not ok then
        if errors[co] then errors[co](tostring(err)) else M.notify(tostring(err), vim.log.levels.ERROR) end
      end
    end)
  end)
  return coroutine.yield()
end
function M.select(items, prompt) return M.await(function(cb) vim.ui.select(items, { prompt = prompt }, cb) end) end
function M.input(prompt, default) return M.await(function(cb) vim.ui.input({ prompt = prompt, default = default }, cb) end) end
function M.lines(text)
  local lines = vim.split(text or '', '\n', { plain = true })
  if lines[#lines] == '' and #lines > 1 then table.remove(lines) end
  for i, line in ipairs(lines) do lines[i] = line:gsub('\r$', '') end
  return lines
end
function M.scratch(name, lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, 'worktree-review://' .. name .. '/' .. b)
  vim.bo[b].bufhidden = 'hide'
  vim.bo[b].swapfile = false
  M.set_lines(b, lines or { '' })
  return b
end
function M.set_lines(b, lines)
  if not vim.api.nvim_buf_is_valid(b) then return end
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, #lines > 0 and lines or { '' })
  vim.bo[b].modifiable = false
  vim.bo[b].modified = false
end
function M.details(title, text)
  local b = M.scratch(title, M.lines(text))
  local w = vim.api.nvim_open_win(b, true, { relative = 'editor', style = 'minimal', border = 'rounded',
    width = math.max(20, math.min(100, vim.o.columns - 4)), height = math.max(3, math.min(25, vim.o.lines - 4)), row = 1, col = 2, title = title })
  vim.keymap.set('n', 'q', function() if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end end, { buffer = b })
end
return M
