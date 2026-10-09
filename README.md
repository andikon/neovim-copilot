# neovim-copilot

My own agentic coding neovim plugin

A dependency-free worktree and review workspace, exposed as
`require("worktree_review")` and `:WorktreeReview`. Each worktree has its own tab,
editable Working File buffers, Git index, review selection, and optional Copilot
CLI terminal. State is kept only for the current Neovim session.

## Requirements

- Neovim **0.10+** and Git **2.31+** (`vim.system`, porcelain v2, NUL worktree
  records, and absolute Git directory discovery).
- Neovim **0.12+** for the built-in `vim.pack` installer.
- Optional: an existing GitHub Copilot CLI installation. On Windows, use
  PowerShell 6+ (`pwsh`), or configure the path to your supported PowerShell.
- No other Neovim plugins, Node installation, Python, GitHub CLI, or UI tools are
  required by this plugin. Copilot manages its own prerequisites and login.

## Install

### lazy.nvim

```lua
{
  "andikon/neovim-copilot",
  cmd = "WorktreeReview",
  main = "worktree_review",
  opts = {},
}
```

For the implementation in this local folder, use this entry immediately:

```lua
{
  dir = "C:/Users/andri/Desktop/NeovimPlugin/neovim-copilot",
  name = "neovim-copilot",
  cmd = "WorktreeReview",
  main = "worktree_review",
  opts = {},
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  { src = "https://github.com/andikon/neovim-copilot" },
})
require("worktree_review").setup({})
```

The remote examples use the repository's default branch. The implementation
must be committed and pushed to that repository before a remote install can
download it. Local lazy.nvim installation loads the files in this folder,
including uncommitted changes. `vim.pack` can also clone a local **committed**
repository using a `file:///C:/.../neovim-copilot` source.

See the official [Neovim package documentation](https://neovim.io/doc/user/pack/)
for `vim.pack` installation and updates.

## Use

1. Open a file or directory in a Git repository and run `:WorktreeReview`.
2. Select a worktree and press Enter. Use `a` to create a feature worktree next
   to the main checkout. A branch already checked out opens its existing worktree.
3. Choose Current Changes or a commit in the left pane, then a file in the next
   pane. The two right panes use Neovim's native diff view.
4. In Changes, edit the right **Working File** pane normally and save with `:w`.
   This writes the actual file, without staging. Staged and historical panes
   are read-only; press `e` in the file list to edit the current Working File.
5. Press `s` / `u` in the file list to stage / unstage a whole file. Unsaved
   text requires **Save and stage** or cancellation. Space marks files; `S` / `U`
   operate on all marked files. Rename actions include both paths.
6. Press `c` for a multiline commit draft; Ctrl-s commits the current index.
   Failed hooks or signing retain the draft. There is no automatic push.
7. Run `:WorktreeReview copilot` to show or hide this worktree's terminal.
   Hiding and switching worktrees preserve the same job. Terminal keys remain
   available to the CLI; use Neovim's terminal-normal mode to issue commands.

Overview keys: Enter open, `a` create, `d` remove, `f` fetch, `p` pull, `P` push,
`E` fetch error details. Lists: `r` refresh, `q` hide, `?` help, Tab / Shift-Tab
move between panes. Native Ctrl-w navigation and `]c` / `[c` work in diff panes.
History: `+` loads another page, `i` shows commit details, `m` selects a merge
commit parent (first parent is the default). `L` explicitly loads a large file.

The overview, commit draft, and detail/help surfaces use centered rounded
floating windows. The overview separates selectable worktrees and highlighted
actions from read-only worktree details; review panes keep Neovim's native
side-by-side diff editing and show concise pane labels and key hints. Hints are
shown only when `keymaps.local_defaults` is enabled.
Design references and primary-source citations: [UI research notes](notes/ui-design-research.md).

No global mappings are created by default. Optional mappings:

```lua
vim.keymap.set("n", "<leader>gw", "<cmd>WorktreeReview<cr>")
vim.keymap.set("n", "<leader>ga", "<cmd>WorktreeReview copilot<cr>")
```

## Configuration

```lua
require("worktree_review").setup({
  git = {
    executable = "git",
    auto_fetch_on_overview = true,
    fetch_prune = true,
    pull_strategy = "ff-only",
    -- default_remote = "origin",
  },
  worktrees = {
    location = "sibling",
    preserve_session_state = true,
    show_setup_notice = true,
  },
  review = {
    history_page_size = 100,
    selection_delay_ms = 80,
    navigation_width = 26,
    files_width = 32,
    large_file_bytes = 2 * 1024 * 1024,
    large_file_lines = 50000,
  },
  refresh = {
    watch_files = true,
    debounce_ms = 200,
    poll_interval_ms = 2000,
  },
  copilot = {
    enabled = true,
    command = { "copilot" },
    shell = "auto", -- Windows: pwsh, otherwise powershell; may be an absolute path
    position = "bottom",
    height_ratio = 0.30,
  },
  keymaps = { global = false, local_defaults = true },
})
```

`preserve_session_state` is retained for spec compatibility; worktree tabs always
preserve session state. `pull_strategy`, `location`, and terminal `position`
currently accept only the documented defaults. Turn off Copilot independently
with `copilot = { enabled = false }`. Use `:checkhealth worktree_review` for
executable and API diagnostics, and `:help worktree-review` for commands.

## Behavior and safeguards

- Diff bases: **Index → Working File** for unstaged files, **HEAD → Index** for
  staged files, **Parent → Commit** for history, and empty → commit for a root
  commit. Files with both staged and unstaged changes appear in both groups.
- New worktrees contain only the selected committed base. Source changes and
  unsaved text stay in their original worktree. Paths are validated for existing
  targets and nesting, including symlink aliases.
- Overview fetch runs asynchronously once per shared repository on each visit,
  with a visible Fetching indicator. There is no periodic network fetch. Git
  actions use argument lists, explicit worktree roots, literal pathspecs, and a
  shared repository queue. Authentication errors are reported rather than
  opening a hidden terminal password prompt; configure Git credentials normally.
- Pull explicitly confirms its upstream and uses fast-forward only. Dirty
  files, unsaved text, or integration state block it. Divergence is left to Git
  commands outside the plugin. First push sets upstream, publishes one branch,
  and confirms the concrete remote target. No force push is provided.
- Removal blocks the main checkout, dirty or missing worktrees, locks, unsaved
  buffers, integration state, and running Copilot jobs. Branch deletion is a
  separate choice, using Git's safe `branch -d` only after worktree removal.
- External changes reload clean buffers. Modified buffers offer Keep editor
  content, Reload file, or Cancel. A Keep decision applies only to the observed
  disk version; another external edit requires another decision before saving.
  A deleted Working File gets a read-only placeholder, never an implicit new file.
- Binary, symlink and submodule Working Files are shown as metadata instead of
  editing a target accidentally. Large files require explicit loading. Git LFS
  pointers remain pointers; no LFS downloads or submodule management are performed.
  Neovim handles actual file encoding, CRLF, and writes; Git versions are raw
  blobs, without external diff/text conversion filters. No hunk staging, restore,
  destructive reset, clean, snapshots, review scoring, or session persistence.
- Copilot's UI handles login, permissions, and conversations. The plugin tracks
  process lifetime, not whether the agent is thinking or finished. Exited
  terminals remain readable; restart is explicit. Neovim exit stops managed jobs.

## Commands

`:WorktreeReview` opens the overview. Subcommands:

| Action | Purpose |
| --- | --- |
| `worktrees`, `changes` | Open overview or active worktree review |
| `create`, `remove` | Manage selected worktree |
| `refresh`, `fetch`, `pull`, `push` | Refresh local state or explicit Git action |
| `stage`, `unstage`, `edit`, `commit` | Selected-file action or commit draft |
| `copilot`, `copilot-stop` | Toggle terminal or explicitly stop session |
| `copilot-restart`, `copilot-enlarge` | Restart an exited session or resize terminal |
| `details` | Show recorded Git errors |

## Tests and validation

From this repository run:

```text
nvim --headless -u NONE -l tests/run.lua
nvim --headless -u NONE -l tests/install.lua
```

Tests use isolated temporary Git repositories and a local bare remote; no network
remote is mutated. They cover parsing, index isolation, CRLF and Unicode paths,
buffer preservation, conflicts, history, commit-hook failures, first push, unborn
HEAD, terminal reuse, and safe removal. Installation tests package a temporary
committed copy and exercise the real `vim.pack` loader without changing this
repository or your Neovim configuration.

Windows verification used Neovim 0.12.4 and Git 2.55.0. Copilot CLI 1.0.89's
executable was checked separately. Terminal lifecycle tests use PowerShell
processes; interactive Copilot authentication, task conversations, signing with
your keys, GUI layout, and corporate network credentials need verification in
your normal Neovim session. See GitHub's [Copilot CLI installation documentation](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)
for CLI prerequisites.
