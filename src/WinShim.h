// WinShim.h — Win32 → macOS compatibility shim for the NppVim port.
//
// The Windows NppVim plugin is ~6 source files of platform-independent modal
// editing logic that talk to Scintilla exclusively through ::SendMessage(HWND,…)
// and a couple of Win32 niceties (RGB, MAX_PATH, clipboard, GetTickCount). The
// macOS host exposes a single function pointer — nppData._sendMessage(handle,…) —
// to reach Scintilla and Notepad++. This header lets the mode/motion/text-object
// logic compile essentially verbatim by:
//
//   • mapping HWND → NppHandle (the host's opaque uintptr_t Scintilla handle),
//   • providing ::SendMessage(handle,msg,w,l) → nppData._sendMessage(…),
//   • supplying RGB / MAX_PATH / GetTickCount64 / the Win type aliases,
//   • exposing the clipboard + status surface through small helpers implemented
//     in the ObjC++ glue (NppVim.mm).
//
// It deliberately does NOT pull in <windows.h>. NppPluginInterfaceMac.h already
// defines BOOL/UINT/WPARAM/LPARAM/LRESULT/TCHAR/TEXT for non-Windows builds and
// (critically) a SendMessage(h,m,w,l) macro; here we add the global-scope
// `::SendMessage` spelling the ported code uses, plus the helpers.

#pragma once

#include "NppPluginInterfaceMac.h"   // NppData, NppHandle, NPPM_*, BOOL/UINT/…, SendMessage macro
#include "Scintilla.h"

// The interface header defines a function-like `SendMessage(h,m,w,l)` macro that
// expands to `nppData._sendMessage(...)`. That breaks the explicitly-qualified
// `::SendMessage(...)` spelling the ported Windows code uses (it would expand to
// `::nppData...`). We don't want the macro at all — the ported sources are
// mechanically rewritten to call NppVim_send(...) directly. Drop the macros so
// the rewrite is unambiguous and nothing accidentally relies on them.
#ifdef SendMessage
#undef SendMessage
#endif
#ifdef SendMessageW
#undef SendMessageW
#endif
#ifdef SendMessageA
#undef SendMessageA
#endif

#include <cstdint>
#include <cstring>
#include <cstdio>
#include <string>

// sprintf_s(buf, "fmt", …) — the ported code always uses the fixed-array form
// `sprintf_s(arr, fmt, …)`. Map it to a bounded snprintf over sizeof(arr). This
// only matches the array overload (the explicit-size overload is unused here).
#ifndef sprintf_s
#define sprintf_s(buf, ...) snprintf((buf), sizeof(buf), __VA_ARGS__)
#endif

// ── Handle type the ported code uses as HWND ────────────────────────────────
// Everywhere the Windows source said HWND it meant "a Scintilla window" (or the
// Notepad++ main window). On macOS those are NppHandle (uintptr_t) tokens.
typedef NppHandle HWND;

// The single NppData instance lives in NppVim.mm; the SendMessage macro in
// NppPluginInterfaceMac.h expands to nppData._sendMessage(...), so every TU that
// includes this shim needs it visible.
extern NppData nppData;

// ── Scintilla / Notepad++ message dispatch ──────────────────────────────────
// Single seam replacing every Win32 ::SendMessage(HWND,…) in the ported code.
// The ported sources are rewritten so that ::SendMessage / ::SendMessageW /
// SendMessage / SendMessageW all become NppVim_send(...).
inline intptr_t NppVim_send(uintptr_t h, uint32_t m, uintptr_t w = 0, intptr_t l = 0) {
    return h ? nppData._sendMessage(h, m, w, l) : 0;
}

// PostMessage has no macOS analogue here; the only callers were the Windows
// keyboard-layout switch (dropped on macOS). Stub so any stray call is a no-op.
inline intptr_t NppVim_post(uintptr_t, uint32_t, uintptr_t = 0, intptr_t = 0) { return 0; }

// HKL (Windows keyboard-layout handle) — macOS has no equivalent the plugin
// needs; the IME/layout-switching feature is dropped. Keep the type so the
// VimState/VimConfig structs that mention it still compile; values stay nullptr.
typedef void* HKL;

// ── Win32 helpers used by the ported code ───────────────────────────────────
#ifndef MAX_PATH
#define MAX_PATH 1024
#endif

// Scintilla colour packing (0x00BBGGRR) — identical formula to Win32 RGB().
#ifndef RGB
#define RGB(r, g, b) ((uint32_t)(((uint8_t)(r)) | (((uint8_t)(g)) << 8) | (((uint8_t)(b)) << 16)))
#endif

// Monotonic millisecond clock (replaces GetTickCount64 for the escape-sequence
// timeout). Implemented in NppVim.mm via mach_absolute_time.
uint64_t NppVimTickCount();
#ifndef GetTickCount64
#define GetTickCount64 NppVimTickCount
#endif

// ── Mode-indicator + clipboard surfaces (implemented in NppVim.mm) ──────────
// The Windows plugin pushed "-- NORMAL --" etc. to the Notepad++ status bar via
// NPPM_SETSTATUSBAR. That message is a documented no-op on the macOS host, so
// these route to a Scintilla call-tip overlay instead (see NppVim.mm).
void NppVimSetStatusUTF8(const char* msg);

// System clipboard (NSPasteboard) — replaces OpenClipboard/SetClipboardData/…
std::string NppVimClipboardGet();
void        NppVimClipboardSet(const std::string& text);

// Modal y/n/a/q chooser for :s///c confirm-each substitution (NSAlert).
// Returns one of 'y','n','a','q' (Win32 used a nested GetMessage loop).
int NppVimConfirmPrompt();

// Present multi-line text in a fresh, read-only document (NPPM-driven).
// Used by :tutor / :help / :reg, which on Windows opened a new tab and filled
// it via SCI_SETTEXT. Implemented in NppVim.mm so it can create the tab.
void NppVimShowTextInNewDoc(const std::string& text, const char* statusMsg);

// Show an informational message box (NSAlert) — replaces Win32 MessageBox
// (used by :marks to list marks).
void NppVimInfoBox(const char* title, const char* body);

// Open a URL in the default browser (NSWorkspace) — replaces ShellExecute.
void NppVimOpenURL(const char* url);

// Resolve a possibly-relative path against the current file's directory (for the
// `gf` motion). Returns the absolute path if it exists, else "" (caller falls
// back to opening the raw text). Replaces the Win32 PathCombine/PathFileExists.
std::string NppVimResolveFilePath(const std::string& text);
