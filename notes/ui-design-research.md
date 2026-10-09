# Neovim floating-UI design patterns: research notes

Purpose: capture, with primary-source citations, how established Neovim
plugins build clean/modern floating UIs — border styling, window layout,
keybinding presentation, and the highlight-group conventions that visually
separate actions, legends ("key → description" hints), and informational
text. This is research only; no implementation code was changed as part of
this document.

Primary sources consulted (official docs + plugin source, pinned to a
commit so citations stay reproducible):

- Neovim core: [`api.txt`](https://github.com/neovim/neovim/blob/c60f1c635d87c172d7ef9910ff096c2294b2e3c9/runtime/doc/api.txt)
  and [`options.txt`](https://github.com/neovim/neovim/blob/c60f1c635d87c172d7ef9910ff096c2294b2e3c9/runtime/doc/options.txt),
  commit `c60f1c635d87c172d7ef9910ff096c2294b2e3c9` (`master`, fetched 2026-10-09).
- `folke/which-key.nvim`, commit [`3aab2147e74890957785941f0c1ad87d0a44c15a`](https://github.com/folke/which-key.nvim/tree/3aab2147e74890957785941f0c1ad87d0a44c15a):
  [`presets.lua`](https://github.com/folke/which-key.nvim/blob/3aab2147e74890957785941f0c1ad87d0a44c15a/lua/which-key/presets.lua),
  [`config.lua`](https://github.com/folke/which-key.nvim/blob/3aab2147e74890957785941f0c1ad87d0a44c15a/lua/which-key/config.lua),
  [`view.lua`](https://github.com/folke/which-key.nvim/blob/3aab2147e74890957785941f0c1ad87d0a44c15a/lua/which-key/view.lua),
  [`colors.lua`](https://github.com/folke/which-key.nvim/blob/3aab2147e74890957785941f0c1ad87d0a44c15a/lua/which-key/colors.lua).
- `folke/snacks.nvim`, commit [`882c996cf28183f4d63640de0b4c02ec886d01f2`](https://github.com/folke/snacks.nvim/tree/882c996cf28183f4d63640de0b4c02ec886d01f2):
  [`win.lua`](https://github.com/folke/snacks.nvim/blob/882c996cf28183f4d63640de0b4c02ec886d01f2/lua/snacks/win.lua).
- `folke/noice.nvim`, commit [`7bfd942445fb63089b59f97ca487d605e715f155`](https://github.com/folke/noice.nvim/tree/7bfd942445fb63089b59f97ca487d605e715f155):
  [`views.lua`](https://github.com/folke/noice.nvim/blob/7bfd942445fb63089b59f97ca487d605e715f155/lua/noice/config/views.lua)
  and [`highlights.lua`](https://github.com/folke/noice.nvim/blob/7bfd942445fb63089b59f97ca487d605e715f155/lua/noice/config/highlights.lua).
- `nvim-telescope/telescope.nvim`, commit [`40aedd8a68c78a656a10a8d62d80c54af59420fb`](https://github.com/nvim-telescope/telescope.nvim/tree/40aedd8a68c78a656a10a8d62d80c54af59420fb):
  [`window.lua`](https://github.com/nvim-telescope/telescope.nvim/blob/40aedd8a68c78a656a10a8d62d80c54af59420fb/lua/telescope/pickers/window.lua),
  [`config.lua`](https://github.com/nvim-telescope/telescope.nvim/blob/40aedd8a68c78a656a10a8d62d80c54af59420fb/lua/telescope/config.lua),
  [`plugin/telescope.lua`](https://github.com/nvim-telescope/telescope.nvim/blob/40aedd8a68c78a656a10a8d62d80c54af59420fb/plugin/telescope.lua).
- `stevearc/dressing.nvim`, commit [`2d7c2db2507fa3c4956142ee607431ddb2828639`](https://github.com/stevearc/dressing.nvim/tree/2d7c2db2507fa3c4956142ee607431ddb2828639):
  [`config.lua`](https://github.com/stevearc/dressing.nvim/blob/2d7c2db2507fa3c4956142ee607431ddb2828639/lua/dressing/config.lua).

---

## 1. Floating windows: the underlying primitive

All plugins below build on the same Neovim API primitive, so it's worth
grounding the rest of the document in it.

`nvim_open_win({buf}, {enter}, {config})` creates (or `nvim_win_set_config`
reconfigures) a floating window when `config.relative` is set. Relevant
`config` keys, quoted from the official API docs:

- `border`: `string|string[]`, default is the `'winborder'` option. "The
  array form must have a length of eight or any divisor of eight, specifying
  the chars that form the border in a clockwise fashion starting from the
  top-left corner... By default, `hl-FloatBorder` highlight is used, which
  links to `hl-WinSeparator` when not defined. Each border side can specify
  an optional highlight: `[ ["+", "MyCorner"], ["x", "MyBorder"] ]`."
  (`neovim/neovim:runtime/doc/api.txt:3959-3978`)
- `title` / `title_pos`: "Title in window border, string or list... If
  string, or a tuple lacks a highlight, the default highlight group is
  `FloatTitle`." `title_pos` is `"left" | "center" | "right"`, default
  `"left"`. (`neovim/neovim:runtime/doc/api.txt:4039-4047`)
- `footer` / `footer_pos`: same shape as `title`, default highlight group
  `FloatFooter`. (`neovim/neovim:runtime/doc/api.txt:4002-4007`)
- `zindex`: "Floats with higher `zindex` overlay floats with lower indices.
  Below 100 is recommended, unless there is a good reason to overshadow
  builtin elements." Built-in UI elements already reserve 100 (completion
  popupmenu), 200 (message scrollback), 250 (cmdline completion popupmenu).
  (`neovim/neovim:runtime/doc/api.txt:4053-4064`)
- `style = "minimal"`: disables `number`, `relativenumber`, `cursorline`,
  `cursorcolumn`, `foldcolumn`, `spell`, `list`; forces `signcolumn=auto`,
  clears `colorcolumn`/`statuscolumn`, and hides end-of-buffer tildes — i.e.
  it strips normal-buffer chrome so a float reads as a UI surface, not a file.
  (`neovim/neovim:runtime/doc/api.txt:4020-4029`)
- Dedicated highlight groups exist specifically for floats: `hl-FloatBorder`
  (border), `hl-FloatTitle` (title), `hl-FloatFooter` (footer), while the
  body uses `hl-NormalFloat`; `'winhighlight'` can override these per-window.
  (`neovim/neovim:runtime/doc/api.txt:452-461`)

`'winborder'` (global option) documents the named border presets every
plugin below maps to or mirrors: `"none"`, `"single"`, `"double"`, `"rounded"`
("Like 'single', but with rounded corners (`╭` etc.)"), `"solid"` (adds
whitespace padding), `"bold"` (bold line box), `"shadow"` (drop-shadow via
background blending), or a custom comma-separated 8-entry char list.
(`neovim/neovim:runtime/doc/options.txt:7664-7681`)

**Takeaway**: "rounded corners" is not plugin-invented — it is a first-class
named value (`"rounded"`) for the core `border` field, paired with a
dedicated `FloatBorder` highlight group separate from the window body
(`NormalFloat`) and from the title/footer (`FloatTitle`/`FloatFooter`). This
repository already follows that primitive directly: `border = 'rounded'` is
passed straight to `vim.api.nvim_open_win` alongside `style = 'minimal'`
(`lua/worktree_review/util.lua:73-79` in this repo).

---

## 2. Rounded borders / corners in practice

Every popup-style plugin surveyed defaults to `"rounded"` (not `"single"` or
`"none"`) for anything meant to read as a modern floating panel, while
reserving `"none"` for chrome-less overlays that intentionally blend into
the editor (cmdline, virtual-text style notifications):

- **dressing.nvim** (`vim.ui.input` replacement): input popup defaults
  `border = "rounded"`, `relative = "cursor"`, with `title_pos = "left"` and
  a trimmed prompt string as the title.
  (`stevearc/dressing.nvim:lua/dressing/config.lua`, `input` block, "These
  are passed to nvim_open_win / border = 'rounded'"). The built-in
  `vim.ui.select` popup and the `nui`-backed Menu both also default to
  `border = "rounded"` (`builtin.border = "rounded"`; `nui.border.style =
  "rounded"`).
- **which-key.nvim**: all three built-in presets (`classic`, `modern`,
  `helix`) that enable a visible border use `border = "rounded"`; only
  `classic` (a bottom cmdline-style strip meant to look like part of the
  command line) uses `border = "none"`.
  (`folke/which-key.nvim:lua/which-key/presets.lua`, full file — `helix` and
  `modern` both set `border = "rounded"`, `classic` sets `border = "none"`.)
- **noice.nvim**: the `popup`, `cmdline_popup`, `cmdline_input`, and
  `confirm` views (anything meant to look like a standalone dialog) default
  `border.style = "rounded"`; the `cmdline`, `mini`, and `hover` views
  (meant to feel embedded in the editor surface, e.g. a virtual-text-like
  notification or an LSP hover tooltip near the cursor) use
  `border.style = "none"`.
  (`folke/noice.nvim:lua/noice/config/views.lua`, `popup`/`cmdline_popup`/
  `cmdline_input`/`confirm`/`cmdline`/`mini`/`hover` blocks.)
- **snacks.nvim**: `snacks.win` exposes `border` as one of
  `"none"|"top"|"right"|"bottom"|"left"|"top_bottom"|"hpad"|"vpad"|"rounded"|
  "single"|"double"|"solid"|"shadow"|"bold"|string[]|false|true` and ships
  partial-border presets (`left`, `right`, `top`, `bottom`, `top_bottom`,
  `hpad`, `vpad`) as literal 8-entry border-char arrays for things like
  helper footers that should blend into one side only.
  (`folke/snacks.nvim:lua/snacks/win.lua`, `snacks.win.Config` annotation and
  the `borders` table.)
- **telescope.nvim** doesn't hardcode a single value; it resolves
  `window.border` / `window.borderchars` per-picker-window (`preview`,
  `results`, `prompt`) through `resolve.win_option`, so prompt/results/preview
  can each receive distinct border chars from the same config
  (`nvim-telescope/telescope.nvim:lua/telescope/pickers/window.lua`, the
  `get_initial_window_options` function).

**Pattern**: "rounded" is the default aesthetic for anything the user
perceives as a standalone surface (input box, confirm dialog, help popup);
borderless (`"none"`) or partial borders are reserved for UI meant to feel
fused with its anchor (cmdline area, hover tooltip, footer strip).

---

## 3. Floating-window layout conventions

- **Sizing as fractions-of-screen with min/max clamps.** which-key's
  `modern` preset: `width = 0.9`, `height = { min = 4, max = 25 }`; `helix`:
  `width = { min = 30, max = 60 }`, `height = { min = 4, max = 0.75 }`.
  (`folke/which-key.nvim:lua/which-key/presets.lua`.) snacks.win defaults:
  `height = 0.9`, `width = 0.9` for the `float` style, i.e. 90% of the editor
  by default, with explicit `min_height/max_height/min_width/max_width`
  fields in the config type.
  (`folke/snacks.nvim:lua/snacks/win.lua`, `defaults`/`snacks.win.Config`
  annotations.) telescope's `layout_config_defaults` follow the same idiom:
  `horizontal = { width = 0.8, height = 0.9, ... }`, `center = { width = 0.5,
  height = 0.4, ... }`.
  (`nvim-telescope/telescope.nvim:lua/telescope/config.lua`,
  `layout_config_defaults`.)
- **Padding is a first-class option, not manual width math.** which-key:
  `padding = { 1, 2 }` ("extra window padding [top/bottom, right/left]").
  (`folke/which-key.nvim:lua/which-key/config.lua`, `win` defaults block.)
  noice adds `border.padding = { 0, 1 }` or `{ 0, 2 }` per view.
  (`folke/noice.nvim:lua/noice/config/views.lua`, `popupmenu`/
  `cmdline_popup`/`hover`/`confirm` blocks.)
- **`no_overlap`**: which-key's win config includes `no_overlap = true` —
  "don't allow the popup to overlap with the cursor" — an explicit UX rule
  that the floating helper must never obscure the thing the user is editing.
  (`folke/which-key.nvim:lua/which-key/config.lua`, `win` defaults block.)
- **zindex stacking is deliberate, not accidental.** which-key's popup uses
  `zindex = 1000` (far above its own content window) while its mapping
  footer and noice's nested popups use smaller, carefully chosen values
  (noice: `popupmenu = 65`, `cmdline_popupmenu`/`cmdline_popup` = 200,
  `confirm` = 210) so that completion menus, cmdline popups, and confirm
  dialogs layer in a predictable, non-overlapping order.
  (`folke/which-key.nvim:lua/which-key/config.lua`, `win.zindex`;
  `folke/noice.nvim:lua/noice/config/views.lua`, `zindex` fields across
  `popupmenu`/`cmdline_popupmenu`/`cmdline_popup`/`mini`/`confirm`.)
- **`style = "minimal"` as the default baseline**, confirmed in snacks'
  window defaults (`minimal = true` by default, resolved against the
  `minimal` style which strips cursorline/cursorcolumn/colorcolumn/foldcolumn/
  signcolumn/statuscolumn/wrap, i.e. exactly the chrome `style=minimal`
  disables at the API level).
  (`folke/snacks.nvim:lua/snacks/win.lua`, `snacks.win.Config.minimal` field
  and the `Snacks.config.style("minimal", ...)` block.)

---

## 4. Keybinding presentation (the "legend")

### which-key.nvim — the reference implementation for key legends

- **Visual key formatting.** Raw key notation (`<C-x>`, `<CR>`, `<Space>`)
  is never shown literally; `which-key.view.format()` splits `<Mod-Key>`
  into parts and substitutes each modifier/special key with an icon glyph
  from `Config.icons.keys` (Nerd Font glyphs for `Up/Down/Left/Right`, `C`
  (Ctrl), `M` (Meta/Alt), `D` (Cmd), `S` (Shift), `CR`, `Esc`, `BS`, `Space`,
  `Tab`, `F1`–`F12`, scroll-wheel events). (`folke/which-key.nvim:lua/
  which-key/view.lua`, function `M.format`; icon glyph table in
  `folke/which-key.nvim:lua/which-key/config.lua`, `icons.keys`.)
- **Separate glyphs for structural roles**, configured under `icons`:
  `breadcrumb = "»"` (shows the active key combo so far in the cmdline),
  `separator = "➜"` (between a key and its label), `group = "+"` (prefixed to
  a group/submenu entry so groups are visually distinct from leaf
  mappings), `ellipsis = "…"` (truncation).
  (`folke/which-key.nvim:lua/which-key/config.lua`, `icons` defaults block.)
- **Description text is sanitized before display** — a `replace.desc` table
  of Lua patterns strips `<Plug>(...)`, leading `+`, `<cmd>`, `<CR>`,
  `<silent>`, leading `lua `/`call `/`:` from raw keymap `rhs`/`desc` so the
  legend reads as a short human label, not raw Vimscript.
  (`folke/which-key.nvim:lua/which-key/config.lua`, `replace.desc` table.)
- **Deterministic sort order for the legend list**: `sort = { "local",
  "order", "group", "alphanum", "mod" }` — buffer-local mappings first, then
  explicit `order`, then groups pushed last, then alphanumeric keys before
  modifier-only keys. (`folke/which-key.nvim:lua/which-key/config.lua`,
  `sort` default; sorter function table in
  `folke/which-key.nvim:lua/which-key/view.lua`, `M.fields`.)
- **Groups auto-expand only when small**: `expand = 0` means "expand groups
  when <= n mappings," i.e. a group with very few children is flattened
  inline instead of forcing an extra navigation step; this is configurable
  to a predicate function too. (`folke/which-key.nvim:lua/which-key/
  config.lua`, `expand` default.)
- **Discoverability feedback in the cmdline itself**: `show_keys = true`
  echoes the keys pressed so far and their resolved label while the popup is
  open, and `show_help = true` shows a one-line usage hint.
  (`folke/which-key.nvim:lua/which-key/config.lua`, `show_help`/`show_keys`.)

### snacks.nvim — inline footer/help legend

- `snacks.win` supports a `footer_keys` option (`boolean|string[]`) that
  renders a key legend in the window's footer border.
  (`folke/snacks.nvim:lua/snacks/win.lua`, `snacks.win.Config.footer_keys`
  field doc comment.)
- Its `toggle_help()` method builds a 2-column-per-row legend directly from
  the live buffer keymap table (`nvim_buf_get_keymap`), truncating each
  key/description to fixed column widths (`key_width = 10`,
  `col_width = 30` by default) and rendering each row as three
  **separately highlighted** virtual-text segments: the key, a `"➜"`
  separator, and the description — i.e. the same three-way key/separator/
  description visual split as which-key, generated generically for any
  window. (`folke/snacks.nvim:lua/snacks/win.lua`, function `M:toggle_help`,
  the `vim.list_extend(help[row], {...})` call building
  `{key,"SnacksWinKey"}, {" "}, {"➜","SnacksWinKeySep"}, {" "},
  {desc,"SnacksWinKeyDesc"}`.)

### telescope.nvim — status-line/footer key hints

Telescope doesn't centralize a single keybinding legend widget, but its
window layering (separate `prompt`/`results`/`preview` floating windows,
each independently titled and bordered) is itself part of the "make the
structure legible" pattern: title text communicates *what* a pane is, while
the border communicates *where one pane ends and another begins*, which is
the pattern worth borrowing even without adopting telescope's fuzzy-finder
machinery. (`nvim-telescope/telescope.nvim:lua/telescope/pickers/
window.lua`, `get_initial_window_options`, which gives `preview`, `results`,
and `prompt` each their own `title`/`border`/`borderchars`.)

---

## 5. Visual distinction: actions vs. legends vs. informational text

The consistent technique across all four plugins is **one highlight group
per semantic role**, linked (not hardcoded) to a sensible built-in default so
themes repaint it automatically, plus a `ColorScheme` autocmd to re-apply
after a colorscheme switch.

### which-key.nvim's role → highlight-group table

```lua
-- folke/which-key.nvim:lua/which-key/colors.lua
M.colors = {
  [""]        = "Function",      -- the key itself
  Separator   = "Comment",       -- the separator between key and description
  Group       = "Keyword",       -- group name (submenu)
  Desc        = "Identifier",    -- description / legend text
  Normal      = "NormalFloat",   -- window body
  Title       = "FloatTitle",    -- window title
  Border      = "FloatBorder",   -- window border
  Value       = "Comment",       -- values shown by plugins (marks, registers)
  Icon        = "@markup.link",  -- icons
  -- IconAzure/IconBlue/IconCyan/... map named icon colors to Diagnostic* groups
}
```

Every entry becomes `WhichKey<Name>` via `vim.api.nvim_set_hl(0, "WhichKey"
.. k, { link = v, default = true })`, re-applied on `ColorScheme`.
(`folke/which-key.nvim:lua/which-key/colors.lua`, `M.colors` table and
`M.setup`.) The key takeaway: **the key glyph, the separator arrow, the
group label, and the description text each get a distinct highlight group**
— nothing is left as plain `Normal` text, so the eye can parse "this is a
keystroke" vs. "this is a submenu" vs. "this is what it does" at a glance.

### snacks.nvim's equivalent table

```lua
-- folke/snacks.nvim:lua/snacks/win.lua
Snacks.util.set_hl({
  Backdrop    = { bg = "#000000" },
  Footer      = "FloatFooter",
  FooterDesc  = "DiagnosticInfo",             -- informational footer text
  FooterKey   = "DiagnosticVirtualTextInfo",  -- the key in a footer legend
  Normal      = "NormalFloat",
  NormalNC    = "NormalFloat",
  Title       = "FloatTitle",
  WinBar      = "Title",
  WinKey      = "Keyword",     -- key in an in-buffer legend/help view
  WinKeySep   = "NonText",     -- separator glyph
  WinKeyDesc  = "Function",    -- description text
  WinSeparator = "WinSeparator",
}, { prefix = "Snacks", default = true })
```

(`folke/snacks.nvim:lua/snacks/win.lua`, the `Snacks.util.set_hl({...})`
call right after the `borders` table.) Note the deliberate distinction
between the **footer legend** palette (`FooterKey`→`DiagnosticVirtualTextInfo`,
`FooterDesc`→`DiagnosticInfo`) and the **in-buffer help view** palette
(`WinKey`→`Keyword`, `WinKeyDesc`→`Function`) — different surfaces, same
three-role split (key / separator / description), each mapped to semantically
appropriate built-in groups (keywords for keys, function-names for
descriptions, "non-text" for separators/decoration).

### noice.nvim's per-view Normal/Border/Title triad

noice.nvim repeats a strict pattern per view: a `*Normal`-ish body group
linked to `NormalFloat`/`Normal`/`Pmenu`, a `*Border` group linked to
`FloatBorder` (or, for cmdline-adjacent popups, to a semantically "active"
diagnostic color so an input box reads as "live"), and separate groups for
matched/selected substrings versus plain text:

```lua
-- folke/noice.nvim:lua/noice/config/highlights.lua (M.defaults, excerpt)
Popup                = "NormalFloat",
PopupBorder          = "FloatBorder",
Popupmenu            = "Pmenu",
PopupmenuBorder      = "FloatBorder",
PopupmenuMatch       = "Special",        -- the matched substring vs...
PopupmenuSelected    = "PmenuSel",       -- ...the selected row
CmdlinePopupBorder   = "DiagnosticSignInfo",
CmdlinePopupBorderSearch = "DiagnosticSignWarn", -- different border color
                                                  -- while in search mode
ConfirmBorder        = "DiagnosticSignInfo",
FormatLevelInfo       = "DiagnosticVirtualTextInfo",
FormatLevelWarn       = "DiagnosticVirtualTextWarn",
FormatLevelError      = "DiagnosticVirtualTextError",
```

(`folke/noice.nvim:lua/noice/config/highlights.lua`, `M.defaults` table.)
Two patterns worth lifting:

1. **State is communicated through border/accent color, not extra text** —
   `CmdlinePopupBorder` vs. `CmdlinePopupBorderSearch` swap `DiagnosticSignInfo`
   for `DiagnosticSignWarn` purely based on mode, with no layout change.
2. **Severity/level reuses the existing `Diagnostic*` family**
   (`DiagnosticVirtualTextInfo/Warn/Error`) instead of inventing new colors,
   so info/warning/error legend text automatically matches whatever
   diagnostic colors the user's colorscheme already defines.

### telescope.nvim's scoped, linked-by-default highlight groups

Telescope registers roughly 40 highlight groups at `plugin/telescope.lua`
load time, every one using `{ default = true, link = ... }` so a theme can
override without `highlight!`. The structurally relevant ones:

```lua
-- nvim-telescope/telescope.nvim:plugin/telescope.lua
TelescopeNormal        = { default = true, link = "Normal" }
TelescopeBorder        = { default = true, link = "TelescopeNormal" }
TelescopePromptBorder  = { default = true, link = "TelescopeBorder" }
TelescopeResultsBorder = { default = true, link = "TelescopeBorder" }
TelescopePreviewBorder = { default = true, link = "TelescopeBorder" }
TelescopeTitle         = { default = true, link = "TelescopeBorder" }
TelescopePromptTitle   = { default = true, link = "TelescopeTitle" }
TelescopeResultsTitle  = { default = true, link = "TelescopeTitle" }
TelescopePreviewTitle  = { default = true, link = "TelescopeTitle" }
TelescopeSelection     = { default = true, link = "Visual" }       -- the active row
TelescopeMatching      = { default = true, link = "Special" }      -- fuzzy-matched chars
TelescopePromptPrefix  = { default = true, link = "Identifier" }    -- prompt icon
TelescopePromptCounter = { default = true, link = "NonText" }       -- "n/total" counter
```

(`nvim-telescope/telescope.nvim:plugin/telescope.lua`, the `highlights`
table and the loop `for k, v in pairs(highlights) do vim.api.nvim_set_hl(0,
k, v) end`.) The hierarchy is: generic `TelescopeNormal`/`TelescopeBorder`/
`TelescopeTitle` act as base groups; each of the three panes
(`Prompt`/`Results`/`Preview`) links its own `*Border`/`*Title` to that base
by default, so a single override (`TelescopeBorder`) recolors all three
panes consistently, while per-pane overrides remain possible.

### Cross-plugin convergence

| Semantic role | which-key.nvim | snacks.nvim | noice.nvim | telescope.nvim |
|---|---|---|---|---|
| Window body | `WhichKeyNormal → NormalFloat` | `SnacksNormal → NormalFloat` | `NoicePopup → NormalFloat` | `TelescopeNormal → Normal` |
| Border | `WhichKeyBorder → FloatBorder` | (inherits `FloatBorder`) | `NoicePopupBorder → FloatBorder` | `TelescopeBorder → TelescopeNormal` |
| Title | `WhichKeyTitle → FloatTitle` | `SnacksTitle → FloatTitle` | `NoiceCmdlinePopupTitle → DiagnosticSignInfo` | `TelescopeTitle → TelescopeBorder` |
| Key glyph (legend) | `WhichKey → Function` | `SnacksWinKey → Keyword` / `SnacksFooterKey → DiagnosticVirtualTextInfo` | n/a (no key legend view) | n/a |
| Separator | `WhichKeySeparator → Comment` | `SnacksWinKeySep → NonText` | n/a | n/a |
| Description/legend text | `WhichKeyDesc → Identifier` | `SnacksWinKeyDesc → Function` / `SnacksFooterDesc → DiagnosticInfo` | n/a | n/a |
| Matched/selected text | n/a | n/a | `NoicePopupmenuMatch → Special`, `NoicePopupmenuSelected → PmenuSel` | `TelescopeMatching → Special`, `TelescopeSelection → Visual` |

The row-by-row convergence is the actual, reusable finding: **every plugin
gives the floating window's body, border, and title three different linked
highlight groups (never one flat color), and every plugin that renders a
keybinding legend gives the key glyph, the separator, and the description
three further distinct groups**, typically linking key→`Keyword`/`Function`
(code-like), description→`Identifier`/`Function` (name-like), and
separator/decoration→`Comment`/`NonText` (de-emphasized). Informational or
state text (search-mode border, severity labels) is routed through the
existing `Diagnostic*`/`Special` groups rather than custom colors, so it
inherits the user's "info/warn/error" semantics automatically.

---

## 6. Summary of reusable patterns

1. Use the named `border = "rounded"` value (not a hand-rolled char array)
   for any standalone floating panel; reserve `"none"`/partial borders for
   UI that should visually fuse with the editor surface it's anchored to.
   Source: `nvim/options.txt:7664-7681`; all four plugins' defaults above.
2. Pass `style = "minimal"` to strip file-buffer chrome (number column,
   cursorline, foldcolumn, etc.) from anything that isn't an editable file
   view. Source: `nvim/api.txt:4020-4029`; snacks `minimal` style.
3. Size floats as a fraction of the editor with explicit min/max clamps
   (`width = 0.9`, `height = { min = 4, max = 25 }`) rather than fixed cell
   counts, and give every floating panel explicit padding
   (`padding = { top_bottom, left_right }`) instead of relying on border
   glyphs alone for breathing room.
4. Give window body / border / title three separate, theme-linked highlight
   groups (`NormalFloat` / `FloatBorder` / `FloatTitle` lineage) rather than
   one flat color — every plugin surveyed does this.
5. For keybinding legends, split each row into at least three highlighted
   segments — key, separator glyph, description — each with its own
   highlight group, and format raw key notation (`<C-x>`) through an
   icon/label table rather than displaying it literally.
6. Route "state"/"severity" coloring (search mode, info/warn/error) through
   existing `Diagnostic*`/`Special` highlight groups instead of inventing
   new ones, so legend/info text automatically matches the user's
   colorscheme semantics.
7. Keep structural chrome (zindex stacking, title/footer position,
   no-overlap-with-cursor rules) explicit and documented in config, since
   it's what keeps multiple floating panels (popupmenu, cmdline popup,
   confirm dialog) layering predictably instead of visually colliding.

## Gaps / not covered

- This document focuses on floating-window chrome and keybinding legends as
  scoped by the request; it does not cover telescope's fuzzy-matching
  algorithm, noice's message-routing engine, or snacks' non-`win` modules
  (picker, notifier, etc.) beyond what's needed to illustrate the shared
  highlight-group conventions.
- `dressing.nvim` is archived/read-only upstream (per its GitHub repository
  state at the time of this research); its config defaults were still read
  directly from source since they remain an accurate, widely-copied
  reference for `vim.ui.input`/`vim.ui.select` floating-window conventions.
- Line numbers for `which-key.nvim`, `snacks.nvim`, `noice.nvim`, and
  `telescope.nvim` excerpts were cross-checked against the fetched file
  content but are cited by file (and, where unambiguous, by containing
  function/table name) rather than exact `start-end` ranges, since the
  raw-content fetch tool used for most of this research does not return
  line numbers; exact line numbers were obtained only for the pinned
  `neovim/neovim` doc excerpts.
