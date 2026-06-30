# NppVim — macOS port

Vim-style modal editing inside **Nextpad++** (the macOS port of Notepad++).
This is the macOS port of [NppVim](https://github.com/h-jangra/NppVim) by
Himanshu (h-jangra), MIT-licensed. The modal-editing engine — modes, motions,
operators, text objects, registers, marks, macros and `:` commands — is ported
almost verbatim from the Windows source; only the platform layer is rewritten.

## How it works on macOS

| Windows | macOS port |
|---|---|
| `SetWindowLongPtr` Scintilla subclass (keyboard hook) | process-wide `+[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown]`; returning `nil` swallows the key |
| `::SendMessage(scintilla, SCI_*, …)` | `nppData._sendMessage(…)` (via a thin `WinShim.h` seam — the engine is unchanged) |
| Mode text on the status bar (`NPPM_SETSTATUSBAR`) | a Scintilla **call-tip** mode indicator (the host status-bar message is a no-op) |
| Win32 clipboard | `NSPasteboard` |
| Win32 About / Config `DIALOG`s | programmatic AppKit modal windows |
| `config.ini` in the plugin config dir | same file/format under `NPPM_GETPLUGINSCONFIGDIR/NppVim/config.ini` |

The key monitor is **gated**: it only consumes keystrokes when (a) Vim mode is
enabled, (b) a Scintilla editor view (`SCIContentView`) is the first responder,
and (c) the current Vim mode consumes keys. **Normal / Visual / Command** modes
swallow keys; **Insert** mode passes typing straight through to the editor and
only intercepts `Esc` (and the configured `jj`/`jk`/`kj`/custom escape). Find
fields, dialogs and menus are never hijacked, and `Cmd`-shortcuts always pass
through.

Enable Vim mode from **Plugins → NppVim → Toggle Vim Mode** (off by default).

## Ported command set (faithful to the Windows plugin)

**Modes:** Normal, Insert, Visual (charwise `v`, linewise `V`, blockwise
`Ctrl+Q`), Command-line (`:` `/` `?`).

**Motions:** `h j k l w W b B e E ge gE 0 ^ $ _ g_ g0 g$ { } ( ) % H L M | gg G
gj gk gm` · char-find `f F t T ; ,` · `gd gD gf gx` · jumps ` `` ` `''` and
counts (`3w`, `d2w`, …).

**Operators / edits:** `d c y` (+ motions/text-objects), `dd yy cc`, `D C S s x
X r R ~ J gJ p P gp gP > < =` , `gu gU g~ guu gUU g?` (rot13), `Ctrl+A`/`Ctrl+X`
increment/decrement, `.` repeat, `u` undo / `Ctrl+R` redo.

**Text objects:** `iw aw iW aW ip ap is as i( a( i[ a[ i{ a{ i" a" i' a' i\` a\`
it at` (work after an operator and in Visual mode).

**Registers:** named `a–z`, numbered `0–9`, unnamed `"`, blackhole `_`, system
clipboard `+`/`*`; `"x` to select a register; `:reg`/`:registers`/`:di` to list.

**Marks:** `m{a-zA-Z}` set, `'{mark}` / `` `{mark} `` jump, `:marks`, `:delm`.

**Macros:** `q{reg}` record, `@{reg}` replay (with recursion/iteration guards).

**Search:** `/` `?` `n` `N` `*` `#` `g*` `g#`, incremental highlight, match count.

**Insert variants:** `i a I A o O gi gI`.

**Folds / scroll:** `za zo zc zt zb zz`, `Ctrl+E/Y/D/U/F/B`.

**`:` commands that work on macOS:** `:w` (save), `:wq`, `:q` / `:bd` (close
tab), `:qa` / `:wqa` (close all), `:<number>` (goto line), `:s/…/…/[flags]` and
`:%s/…` (substitute, flags `g c i I l` incl. confirm prompt), `:sort` / `:sort!`
/ `:sort n` / `:sort n!` (line sort, done via Scintilla), `:noh`,
`:set nu`/`:set nonu`, `:set tw=N`, `:wrap`/`:nowrap`/`:wrap char`/`:wrap
whitespace`, `:marks`/`:delm`, `:reg`, `:tutor`/`:t`, `:help`/`:h`, `:about`,
`:config`.

## Differences from the Windows plugin (host limitations)

These features depend on Notepad++ commands the macOS host does **not** expose
to plugins (`NPPM_MENUCOMMAND` only honors a small `IDM_FILE_*` whitelist), so
the closest reachable behaviour is to report that they're unavailable rather
than silently do nothing:

- **Tab switching** — `gt` / `gT`, `:bn` / `:bp` (no host tab-navigation API).
- **Block comment** — `gcc` (no host `IDM_EDIT_BLOCK_COMMENT` path; use the
  CommentToggler plugin or the editor's own comment shortcut).
- **Window split** — `:sp` / `:vs` (no host split-view command for plugins).
- **Reload from disk** — `:e` (no host reload command for plugins).
- **Save-all** — `:wqa` saves the current file then closes all (the host has no
  `NPPM_SAVEALLFILES`).

Other intentional changes:

- **Keyboard-layout switching** (the Windows option that flipped the IME to
  English in Normal mode) is **dropped** — macOS exposes no per-window
  input-source switch to a plugin. The config flag is inert.
- **Mode indicator** is a Scintilla call-tip (toggle in Configuration), since
  `NPPM_SETSTATUSBAR` is a no-op on the host.
- The `:s///c` confirm prompt uses a small **Yes/No/All/Quit** dialog instead of
  reading the next keystroke from a nested message loop.

## Building

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

Produces a universal (`arm64` + `x86_64`) `NppVim.dylib`. Install it at
`~/Library/Application Support/Nextpad++/plugins/NppVim/NppVim.dylib`.

## License

MIT (see `LICENSE`). Original Windows plugin © Himanshu (h-jangra).
