// NppVim.mm — macOS platform layer for the NppVim (Vim mode) plugin.
//
// Original Windows plugin: "NppVim" by Himanshu (h-jangra), MIT.
//   https://github.com/h-jangra/NppVim
//
// The modal-editing engine (Normal / Insert / Visual / Command modes; motions,
// operators, text objects, registers, marks, macros, : commands) is ported
// almost verbatim from the Windows sources — see NormalMode/VisualMode/
// CommandMode/Motion/TextObject/Marks/Keymap/Utils. Those files talk to Scintilla
// only through NppVim_send(...) (the WinShim.h seam over nppData._sendMessage).
//
// This file replaces the Windows platform layer (NppVim.cpp):
//
//   • Keyboard interception. Windows subclassed each Scintilla HWND
//     (SetWindowLongPtr → ScintillaHookProc). macOS uses a process-wide
//     +[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown]; the
//     handler returns nil to swallow a key (the equivalent of the Windows hook
//     consuming the message) and the original event to let it through. The
//     monitor is GATED so it only consumes keys when (a) Vim is enabled, (b) a
//     Scintilla editor view is first responder, and (c) the current Vim mode
//     consumes keys (Normal/Visual/Command swallow; Insert passes through except
//     Esc / the configured jj-style escape). Find fields, dialogs and menus are
//     never hijacked.
//
//   • Mode indicator. Windows pushed "-- NORMAL --" etc. to the status bar via
//     NPPM_SETSTATUSBAR, a no-op on the macOS host. Instead the indicator is
//     shown as a Scintilla call-tip anchored at the caret (toggleable), so there
//     IS a visible mode readout without any host change.
//
//   • Clipboard. OpenClipboard/SetClipboardData → NSPasteboard.
//   • About / Configuration dialogs. Win32 DIALOG templates → programmatic
//     AppKit modal windows driving the same config.ini.
//   • config.ini lives in NPPM_GETPLUGINSCONFIGDIR (shared format with Windows).
//
// HOST LIMITATIONS (documented, no host changes):
//   • Tab switching (gt/gT, :bn/:bp), block-comment (gcc), window split (:sp/:vs)
//     and reload (:e) are not reachable through the macOS NPPM_MENUCOMMAND
//     whitelist; those commands report "not available on macOS host". File
//     save/close/close-all (:w/:q/:qa/:wq/:wqa) and new-doc (:tutor/:help/:reg)
//     DO work via NPPM_SAVECURRENTFILE / NPPM_MENUCOMMAND(IDM_FILE_*).
//   • Per-window keyboard-layout switching is dropped (no macOS plugin API).

#import <Cocoa/Cocoa.h>
#include <mach/mach_time.h>

#include "WinShim.h"
#include "NppVim.h"
#include "NormalMode.h"
#include "VisualMode.h"
#include "CommandMode.h"
#include "Utils.h"
#include "Marks.h"
#include "menuCmdID.h"

#include <algorithm>
#include <fstream>
#include <string>
#include <vector>
#include <cstdlib>
#include <cstring>
#include <cctype>

// ── Globals shared with the ported engine ───────────────────────────────────
NppData nppData;
VimState state;
VimConfig g_config;

NormalMode*  g_normalMode  = nullptr;
VisualMode*  g_visualMode  = nullptr;
CommandMode* g_commandMode = nullptr;

// HKL globals referenced by the engine (inert on macOS).
HKL g_userLayout    = nullptr;
HKL g_englishLayout = nullptr;

static const char* PLUGIN_NAME = "NppVim";
static const int   NB_FUNC = 4;   // Toggle | Configuration | (sep) | About
static FuncItem    funcItem[NB_FUNC];

static id   gKeyMonitor = nil;    // NSEvent local monitor token
static bool gReady = false;       // NPPN_READY seen
static bool gShowIndicator = true;  // call-tip mode indicator on/off

// Escape-sequence state (jj/jk/kj/custom) — mirrors NppVim.cpp g_firstKey.
static char     gFirstKey = 0;
static uint64_t gFirstKeyTime = 0;

// Forward decls
static void toggleVimMode();
static void showConfigDialog_impl();
static void aboutDialog_impl();
static void loadConfig_impl();
static void saveConfig();
static void installKeyMonitor();
static void removeKeyMonitor();
static void updateCaretForMode();

// friend of Utils (defined below) — sets Utils' private nppData copy.
void setNppData(NppData data);

// Engine entry points declared in NppVim.h
void showConfigDialog() { showConfigDialog_impl(); }
void about()            { aboutDialog_impl(); }

// ════════════════════════════════════════════════════════════════════════════
//  WinShim helper implementations (status / clipboard / dialogs / sort / paths)
// ════════════════════════════════════════════════════════════════════════════

uint64_t NppVimTickCount() {
    static mach_timebase_info_data_t tb = {0, 0};
    if (tb.denom == 0) mach_timebase_info(&tb);
    uint64_t t = mach_absolute_time();
    return (t * tb.numer / tb.denom) / 1000000ULL;   // → milliseconds
}

// ── Scintilla helpers (local) ───────────────────────────────────────────────
static NppHandle curSci() {
    int which = 0;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle
         : (which == 1) ? nppData._scintillaSecondHandle
                        : nppData._scintillaMainHandle;
}
static intptr_t sci(NppHandle h, uint32_t m, uintptr_t w = 0, intptr_t l = 0) {
    return h ? nppData._sendMessage(h, m, w, l) : 0;
}

// ── Mode indicator via Scintilla call-tip ───────────────────────────────────
void NppVimSetStatusUTF8(const char* msg) {
    if (!gShowIndicator || !state.vimEnabled) return;
    NppHandle h = curSci();
    if (!h) return;
    if (!msg || !*msg) { sci(h, SCI_CALLTIPCANCEL); return; }
    // Anchor the tip at the start of the caret line so it doesn't cover typing.
    int pos  = (int)sci(h, SCI_GETCURRENTPOS);
    int line = (int)sci(h, SCI_LINEFROMPOSITION, pos);
    int show = (int)sci(h, SCI_POSITIONFROMLINE, line);
    sci(h, SCI_CALLTIPSHOW, (uintptr_t)show, (intptr_t)msg);
}

// ── Clipboard (NSPasteboard) ────────────────────────────────────────────────
std::string NppVimClipboardGet() {
    @autoreleasepool {
        NSString* s = [[NSPasteboard generalPasteboard] stringForType:NSPasteboardTypeString];
        return s ? std::string([s UTF8String]) : std::string();
    }
}
void NppVimClipboardSet(const std::string& text) {
    @autoreleasepool {
        NSPasteboard* pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:[NSString stringWithUTF8String:text.c_str()]
              forType:NSPasteboardTypeString];
    }
}

// ── y/n/a/q confirm prompt for :s///c ───────────────────────────────────────
int NppVimConfirmPrompt() {
    __block int result = 'q';
    void (^work)(void) = ^{
        @autoreleasepool {
            NSAlert* a = [[NSAlert alloc] init];
            a.messageText = @"Replace match?";
            a.informativeText = @"Yes / No / All / Quit";
            [a addButtonWithTitle:@"Yes"];   // 1000
            [a addButtonWithTitle:@"No"];    // 1001
            [a addButtonWithTitle:@"All"];   // 1002
            [a addButtonWithTitle:@"Quit"];  // 1003
            NSModalResponse r = [a runModal];
            switch (r) {
                case NSAlertFirstButtonReturn:  result = 'y'; break;
                case NSAlertSecondButtonReturn: result = 'n'; break;
                case NSAlertThirdButtonReturn:  result = 'a'; break;
                default:                        result = 'q'; break;
            }
        }
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return result;
}

// ── Info box (replaces MessageBox) ──────────────────────────────────────────
void NppVimInfoBox(const char* title, const char* body) {
    @autoreleasepool {
        NSAlert* a = [[NSAlert alloc] init];
        a.messageText = title ? [NSString stringWithUTF8String:title] : @"";
        a.informativeText = body ? [NSString stringWithUTF8String:body] : @"";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

// ── Open URL (replaces ShellExecute) ────────────────────────────────────────
void NppVimOpenURL(const char* url) {
    @autoreleasepool {
        if (!url || !*url) return;
        NSString* s = [NSString stringWithUTF8String:url];
        NSURL* u = [NSURL URLWithString:s];
        if (u) [[NSWorkspace sharedWorkspace] openURL:u];
    }
}

// ── Resolve a (possibly relative) file path for `gf` ────────────────────────
std::string NppVimResolveFilePath(const std::string& text) {
    @autoreleasepool {
        if (text.empty()) return "";
        NSString* candidate = [NSString stringWithUTF8String:text.c_str()];
        NSFileManager* fm = [NSFileManager defaultManager];

        if ([candidate hasPrefix:@"/"]) {
            return [fm fileExistsAtPath:candidate] ? std::string([candidate UTF8String]) : "";
        }
        // Relative: join against the current file's directory.
        char cur[MAX_PATH] = {0};
        nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLCURRENTPATH, MAX_PATH, (intptr_t)cur);
        NSString* curPath = [NSString stringWithUTF8String:cur];
        NSString* dir = [curPath stringByDeletingLastPathComponent];
        NSString* full = [[dir stringByAppendingPathComponent:candidate] stringByStandardizingPath];
        return [fm fileExistsAtPath:full] ? std::string([full UTF8String]) : "";
    }
}

// ── Present text in a fresh read-only document (tutor / help / registers) ────
void NppVimShowTextInNewDoc(const std::string& text, const char* statusMsg) {
    std::string body = text;
    std::string status = statusMsg ? statusMsg : "";
    void (^work)(void) = ^{
        // IDM_FILE_NEW (41001) is host-supported. Create the tab, then fill the
        // now-current Scintilla view (resolved AFTER creation to avoid staleness).
        nppData._sendMessage(nppData._nppHandle, NPPM_MENUCOMMAND, 0, IDM_FILE_NEW);
        NppHandle h = curSci();
        if (!h) return;
        sci(h, SCI_SETREADONLY, 0, 0);
        sci(h, SCI_SETTEXT, 0, (intptr_t)body.c_str());
        sci(h, SCI_SETSAVEPOINT, 0, 0);
        sci(h, SCI_SETREADONLY, 1, 0);
        sci(h, SCI_SETFIRSTVISIBLELINE, 0, 0);
        if (gShowIndicator && !status.empty())
            sci(h, SCI_CALLTIPSHOW, 0, (intptr_t)status.c_str());
    };
    if ([NSThread isMainThread]) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

// ── Sort lines via Scintilla (replaces IDM_EDIT_SORTLINES_*) ─────────────────
void NppVimSortLines(HWND h, bool numeric, bool descending) {
    if (!h) return;
    int total = (int)sci(h, SCI_GETLINECOUNT);
    int selStart = (int)sci(h, SCI_GETSELECTIONSTART);
    int selEnd   = (int)sci(h, SCI_GETSELECTIONEND);

    int firstLine, lastLine;
    if (selStart != selEnd) {
        firstLine = (int)sci(h, SCI_LINEFROMPOSITION, (uintptr_t)selStart);
        lastLine  = (int)sci(h, SCI_LINEFROMPOSITION, (uintptr_t)selEnd);
        // A selection that ends at column 0 doesn't include that last line.
        if (selEnd == (int)sci(h, SCI_POSITIONFROMLINE, (uintptr_t)lastLine) && lastLine > firstLine)
            lastLine--;
    } else {
        firstLine = 0;
        lastLine  = total - 1;
    }
    if (lastLine <= firstLine) return;

    // Gather line texts.
    std::vector<std::string> lines;
    lines.reserve(lastLine - firstLine + 1);
    for (int ln = firstLine; ln <= lastLine; ln++) {
        int s = (int)sci(h, SCI_POSITIONFROMLINE, (uintptr_t)ln);
        int e = (int)sci(h, SCI_GETLINEENDPOSITION, (uintptr_t)ln);
        lines.push_back(Utils::getTextRange(h, s, e));
    }

    auto toNum = [](const std::string& s) -> long long {
        size_t i = 0; while (i < s.size() && isspace((unsigned char)s[i])) i++;
        char* end = nullptr;
        long long v = strtoll(s.c_str() + i, &end, 10);
        return (end == s.c_str() + i) ? 0 : v;   // non-numeric → 0
    };

    std::stable_sort(lines.begin(), lines.end(),
        [&](const std::string& a, const std::string& b) {
            if (numeric) return toNum(a) < toNum(b);
            return a < b;
        });
    if (descending) std::reverse(lines.begin(), lines.end());

    std::string joined;
    for (size_t i = 0; i < lines.size(); i++) {
        joined += lines[i];
        if (i + 1 < lines.size()) joined += "\n";
    }

    int repStart = (int)sci(h, SCI_POSITIONFROMLINE, (uintptr_t)firstLine);
    int repEnd   = (int)sci(h, SCI_GETLINEENDPOSITION, (uintptr_t)lastLine);
    sci(h, SCI_BEGINUNDOACTION);
    sci(h, SCI_SETTARGETRANGE, (uintptr_t)repStart, (intptr_t)repEnd);
    sci(h, SCI_REPLACETARGET, (uintptr_t)joined.size(), (intptr_t)joined.c_str());
    sci(h, SCI_ENDUNDOACTION);
}

// ════════════════════════════════════════════════════════════════════════════
//  config.ini  (NPPM_GETPLUGINSCONFIGDIR; shared key format with Windows)
// ════════════════════════════════════════════════════════════════════════════
static std::string configPath() {
    @autoreleasepool {
        char buf[2048] = {0};
        nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR,
                             (uintptr_t)sizeof(buf), (intptr_t)buf);
        NSString* root = (buf[0] != '\0')
            ? [NSString stringWithUTF8String:buf]
            : [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                  NSUserDomainMask, YES).firstObject
                  stringByAppendingPathComponent:@"Nextpad++/plugins/Config"];
        NSString* dir = [root stringByAppendingPathComponent:@"NppVim"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
            withIntermediateDirectories:YES attributes:nil error:nil];
        return std::string([[dir stringByAppendingPathComponent:@"config.ini"] UTF8String]);
    }
}

static std::string trimStr(const std::string& s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

static void loadConfig_impl() {
    // Defaults (mirror NppVim.cpp loadConfig()).
    g_config.escapeKey = "esc";
    g_config.customEscape = "";
    g_config.enableKeyboardLayoutSwitching = false;
    g_config.escapeTimeout = 300;
    g_config.overrideCtrlD = false;
    g_config.overrideCtrlU = false;
    g_config.overrideCtrlR = false;
    g_config.overrideCtrlF = false;
    g_config.overrideCtrlB = false;
    g_config.overrideCtrlO = false;
    g_config.overrideCtrlI = false;
    g_config.xStoreClipboard = true;
    g_config.dStoreClipboard = true;
    g_config.cStoreClipboard = true;
    g_config.vimEnabled = DEFAULT_VIM_ENABLED;

    std::ifstream f(configPath());
    if (!f.is_open()) return;
    std::string line;
    while (std::getline(f, line)) {
        std::string t = trimStr(line);
        if (t.empty() || t[0] == '#' || t[0] == ';') continue;
        size_t eq = t.find('=');
        if (eq == std::string::npos) continue;
        std::string k = trimStr(t.substr(0, eq));
        std::string v = trimStr(t.substr(eq + 1));
        auto truthy = [&]{ return v == "1" || v == "true"; };
        if      (k == "escape_key")        g_config.escapeKey = v;
        else if (k == "custom_escape")     g_config.customEscape = v;
        else if (k == "escape_timeout")    { try { int n = std::stoi(v); if (n >= 100 && n <= 1000) g_config.escapeTimeout = n; } catch (...) {} }
        else if (k == "override_ctrl_d")   g_config.overrideCtrlD = truthy();
        else if (k == "override_ctrl_u")   g_config.overrideCtrlU = truthy();
        else if (k == "override_ctrl_r")   g_config.overrideCtrlR = truthy();
        else if (k == "override_ctrl_f")   g_config.overrideCtrlF = truthy();
        else if (k == "override_ctrl_b")   g_config.overrideCtrlB = truthy();
        else if (k == "override_ctrl_o")   g_config.overrideCtrlO = truthy();
        else if (k == "override_ctrl_i")   g_config.overrideCtrlI = truthy();
        else if (k == "x_store_clipboard") g_config.xStoreClipboard = truthy();
        else if (k == "d_store_clipboard") g_config.dStoreClipboard = truthy();
        else if (k == "c_store_clipboard") g_config.cStoreClipboard = truthy();
        else if (k == "vim_enabled")       g_config.vimEnabled = truthy();
        else if (k == "show_mode_indicator") gShowIndicator = truthy();
    }
}
void loadConfig() { loadConfig_impl(); }

static void saveConfig() {
    std::ofstream f(configPath(), std::ios::trunc);
    if (!f.is_open()) return;
    f << "# NppVim configuration (macOS)\n";
    f << "# escape_key: esc, jj, jk, kj, custom\n";
    f << "escape_key=" << g_config.escapeKey << "\n";
    f << "custom_escape=" << g_config.customEscape << "\n";
    f << "escape_timeout=" << g_config.escapeTimeout << "\n";
    f << "override_ctrl_d=" << (g_config.overrideCtrlD ? 1 : 0) << "\n";
    f << "override_ctrl_u=" << (g_config.overrideCtrlU ? 1 : 0) << "\n";
    f << "override_ctrl_r=" << (g_config.overrideCtrlR ? 1 : 0) << "\n";
    f << "override_ctrl_f=" << (g_config.overrideCtrlF ? 1 : 0) << "\n";
    f << "override_ctrl_b=" << (g_config.overrideCtrlB ? 1 : 0) << "\n";
    f << "x_store_clipboard=" << (g_config.xStoreClipboard ? 1 : 0) << "\n";
    f << "d_store_clipboard=" << (g_config.dStoreClipboard ? 1 : 0) << "\n";
    f << "c_store_clipboard=" << (g_config.cStoreClipboard ? 1 : 0) << "\n";
    f << "vim_enabled=" << (g_config.vimEnabled ? 1 : 0) << "\n";
    f << "show_mode_indicator=" << (gShowIndicator ? 1 : 0) << "\n";
}

// ════════════════════════════════════════════════════════════════════════════
//  Caret style per mode (block in Normal/Visual, line in Insert)
// ════════════════════════════════════════════════════════════════════════════
static void updateCaretForMode() {
    NppHandle h = curSci();
    if (!h) return;
    if (state.vimEnabled) {
        if (state.mode == NORMAL || state.mode == VISUAL) {
            sci(h, SCI_SETCARETSTYLE, CARETSTYLE_BLOCK);
            sci(h, SCI_SETCARETSTICKY, state.mode == VISUAL ? SC_CARETSTICKY_ON : SC_CARETSTICKY_OFF);
        } else {
            sci(h, SCI_SETCARETSTYLE, CARETSTYLE_LINE);
            sci(h, SCI_SETCARETSTICKY, SC_CARETSTICKY_OFF);
        }
    } else {
        sci(h, SCI_SETCARETSTYLE, CARETSTYLE_LINE);
        sci(h, SCI_SETCARETSTICKY, SC_CARETSTICKY_OFF);
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  Keyboard interception (NSEvent local monitor) — replaces ScintillaHookProc
// ════════════════════════════════════════════════════════════════════════════

// Is the key window's first responder a Scintilla editor view? (Don't hijack
// Find/Replace fields, dialogs, the menu, etc.) Same approach as the
// SurroundSelection / Compose macOS ports.
static BOOL firstResponderIsEditor() {
    NSWindow* kw = [NSApp keyWindow];
    if (!kw) return NO;
    NSResponder* r = kw.firstResponder;
    while (r) {
        NSString* cls = NSStringFromClass([r class]);
        if ([cls containsString:@"Scintilla"] || [cls containsString:@"SCI"])
            return YES;
        // An NSTextView field editor (Find box, rename field…) → not the editor.
        if ([cls containsString:@"TextView"] || [cls containsString:@"SearchField"] ||
            [cls containsString:@"TextField"])
            return NO;
        if ([r isKindOfClass:[NSView class]]) r = [(NSView*)r superview];
        else break;
    }
    return NO;
}

// Two-key escape detector (jj/jk/kj/custom). Mirrors NppVim.cpp::checkEscapeSequence.
static bool checkEscapeSequence(char c) {
    uint64_t now = NppVimTickCount();
    if (gFirstKey != 0 && now - gFirstKeyTime > (uint64_t)g_config.escapeTimeout)
        gFirstKey = 0;

    if (g_config.escapeKey == "custom" && !g_config.customEscape.empty()) {
        const std::string& ce = g_config.customEscape;
        if (ce.rfind("ctrl+", 0) == 0 || ce.rfind("alt+", 0) == 0 || ce.rfind("shift+", 0) == 0)
            return false;   // modifier combos handled separately
        if (ce.length() == 2) {
            if (gFirstKey == 0) {
                if (c == ce[0]) { gFirstKey = c; gFirstKeyTime = now; return false; }
            } else if (gFirstKey == ce[0] && c == ce[1]) {
                gFirstKey = 0; return true;
            }
        }
    }

    if (gFirstKey == 0) {
        if ((g_config.escapeKey == "jj" && c == 'j') ||
            (g_config.escapeKey == "jk" && c == 'j') ||
            (g_config.escapeKey == "kj" && c == 'k')) {
            gFirstKey = c; gFirstKeyTime = now; return false;
        }
        return false;
    }
    if ((g_config.escapeKey == "jj" && gFirstKey == 'j' && c == 'j') ||
        (g_config.escapeKey == "jk" && gFirstKey == 'j' && c == 'k') ||
        (g_config.escapeKey == "kj" && gFirstKey == 'k' && c == 'j')) {
        gFirstKey = 0; return true;
    }
    gFirstKey = 0;
    return false;
}

// Returns nil to swallow the event, or the event to pass it through.
// Reproduces NppVim.cpp::ScintillaHookProc's per-mode routing.
static NSEvent* handleKeyEvent(NSEvent* event) {
    if (!state.vimEnabled) return event;
    if (!firstResponderIsEditor()) return event;

    NppHandle h = curSci();
    if (!h) return event;

    NSEventModifierFlags mods =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    bool cmd   = (mods & NSEventModifierFlagCommand) != 0;
    bool ctrl  = (mods & NSEventModifierFlagControl) != 0;
    bool alt   = (mods & NSEventModifierFlagOption)  != 0;

    // Never interfere with Command shortcuts (Cmd-S, Cmd-Q, Cmd-C…).
    if (cmd) { gFirstKey = 0; return event; }

    unsigned short kc = event.keyCode;
    bool isEsc       = (kc == 53);
    bool isReturn    = (kc == 36 || kc == 76);
    bool isBackspace = (kc == 51);
    bool isArrowOrNav = (kc == 123 || kc == 124 || kc == 125 || kc == 126 || // arrows
                         kc == 115 || kc == 119 || kc == 116 || kc == 121 || // home/end/pgup/pgdn
                         kc == 117);                                          // fwd-delete

    NSString* chars = event.characters;
    char ch = (chars.length == 1 && [chars characterAtIndex:0] <= 0x7F)
                ? (char)[chars characterAtIndex:0] : 0;

    // ── Ctrl overrides (Normal/Visual): block-visual toggle + paging/redo ────
    if (ctrl && !alt && (state.mode == NORMAL || state.mode == VISUAL)) {
        NSString* ci = event.charactersIgnoringModifiers;
        char base = (ci.length == 1) ? (char)toupper([ci characterAtIndex:0]) : 0;
        if (base == 'Q') {   // Ctrl+Q → visual block (or exit block)
            if (state.mode == VISUAL && state.isBlockVisual) g_normalMode->enter();
            else g_visualMode->enterBlock(h);
            updateCaretForMode();
            return nil;
        }
        if (base == 'D' && g_config.overrideCtrlD) { Motion::pageDown(h); state.repeatCount = 0; return nil; }
        if (base == 'U' && g_config.overrideCtrlU) { Motion::pageUp(h);   state.repeatCount = 0; return nil; }
        if (base == 'R' && g_config.overrideCtrlR && state.mode == NORMAL) { sci(h, SCI_REDO); return nil; }
        if (base == 'F' && g_config.overrideCtrlF) { Motion::pageDown(h); state.repeatCount = 0; return nil; }
        if (base == 'B' && g_config.overrideCtrlB) { Motion::pageUp(h);   state.repeatCount = 0; return nil; }
        // Other Ctrl combos fall through (the engine's keymaps map a handful of
        // Ctrl-letters via control characters; deliver those below).
    }

    // ── COMMAND-LINE mode ────────────────────────────────────────────────────
    if (state.commandMode) {
        if (isReturn)    { g_commandMode->handleEnter(h); updateCaretForMode(); return nil; }
        if (isEsc)       { Utils::clearSearchHighlights(h); state.lastSearchMatchCount = -1;
                           g_commandMode->exit(); updateCaretForMode(); return nil; }
        if (isBackspace) { g_commandMode->handleBackspace(h); return nil; }
        if (ch >= 32 && ch != 127) { g_commandMode->handleKey(h, ch); return nil; }
        return nil;   // swallow everything while the : / / ? prompt is open
    }

    // ── INSERT mode: pass through; only Esc / escape-sequence return to Normal ─
    if (state.mode == INSERT) {
        if (isEsc) {
            sci(h, SCI_SETOVERTYPE, 0);
            gFirstKey = 0;
            if (state.recordingInsertMacro && !state.insertMacroBuffers.empty()) {
                state.insertMacroBuffers.back().push_back('\x1B');
                state.recordingInsertMacro = false;
            }
            g_normalMode->enter();
            updateCaretForMode();
            return nil;
        }
        if (g_config.escapeKey != "esc" && ch != 0 && !ctrl && !alt) {
            if (state.recordingInsertMacro && !state.insertMacroBuffers.empty())
                state.insertMacroBuffers.back().push_back(ch);
            if (checkEscapeSequence(ch)) {
                // Remove the just-typed leading sequence char(s) that Scintilla
                // already inserted, then leave insert mode (mirrors Windows).
                if (state.recordingInsertMacro && !state.insertMacroBuffers.empty()) {
                    auto& buf = state.insertMacroBuffers.back();
                    size_t rm = (g_config.escapeKey.size() == 2) ? 2 : 0;
                    while (rm-- && !buf.empty()) buf.pop_back();
                    buf.push_back('\x1B');
                    state.recordingInsertMacro = false;
                }
                int pos = (int)sci(h, SCI_GETCURRENTPOS);
                if (pos >= 1) {                       // delete the first 'j'/'k'
                    sci(h, SCI_SETSEL, (uintptr_t)(pos - 1), (intptr_t)pos);
                    sci(h, SCI_REPLACESEL, 0, (intptr_t)"");
                }
                sci(h, SCI_SETOVERTYPE, 0);
                g_normalMode->enter();
                updateCaretForMode();
                return nil;   // swallow the second key of the sequence
            }
        }
        return event;   // normal typing flows to Scintilla
    }

    // ── NORMAL / VISUAL modes: consume keys ──────────────────────────────────
    if (isEsc) { gFirstKey = 0; g_normalMode->enter(); updateCaretForMode(); return nil; }

    // Arrow/navigation keys: let Scintilla move the caret (and reset sequence).
    if (isArrowOrNav) { gFirstKey = 0; return event; }

    if (isReturn) {
        // In Normal mode with nothing pending, Enter = down to first non-blank
        // (vim's <CR>). If an operator or multi-key sequence is pending, or in
        // Visual mode, just swallow it (don't let Scintilla insert a newline).
        if (state.mode == NORMAL && !state.opPending && !state.replacePending &&
            !state.awaitingMarkSet && !state.awaitingMarkJump &&
            !g_normalKeymap->hasPending()) {
            Motion::lineDown(h, 1); sci(h, SCI_VCHOME);
        }
        return nil;
    }

    // Map Ctrl+letter (not otherwise overridden) to its control character so the
    // engine's Ctrl bindings (Ctrl+E/Y/D/U/F/B/R, Ctrl+A/X increment) fire.
    if (ctrl && !alt) {
        NSString* ci = event.charactersIgnoringModifiers;
        if (ci.length == 1) {
            char base = (char)toupper([ci characterAtIndex:0]);
            if (base >= 'A' && base <= 'Z') {
                char ctl = (char)(base - 'A' + 1);
                if (state.mode == NORMAL) g_normalMode->handleKey(h, ctl);
                else                      g_visualMode->handleKey(h, ctl);
                updateCaretForMode();
                return nil;
            }
        }
        return event;
    }

    if (ch == 0) return event;   // non-ASCII / dead key — leave it

    // Replace-pending (r<char>) in Normal mode — intercepted at the platform
    // layer exactly as the Windows hook did (before handleKey, so r<d/c/y> still
    // replaces rather than starting an operator).
    if (state.replacePending && state.mode == NORMAL) {
        int pos = (int)sci(h, SCI_GETCURRENTPOS);
        int docLen = (int)sci(h, SCI_GETTEXTLENGTH);
        if (pos < docLen) {
            char cur = (char)sci(h, SCI_GETCHARAT, (uintptr_t)pos);
            if (cur != '\r' && cur != '\n') {
                sci(h, SCI_SETSEL, (uintptr_t)pos, (intptr_t)(pos + 1));
                char rep[2] = { ch, 0 };
                sci(h, SCI_REPLACESEL, 0, (intptr_t)rep);
                sci(h, SCI_SETCURRENTPOS, (uintptr_t)(pos + 1));
            }
        }
        state.replacePending = false;
        state.repeatCount = 0;
        updateCaretForMode();
        return nil;
    }

    if (state.mode == NORMAL) g_normalMode->handleKey(h, ch);
    else                      g_visualMode->handleKey(h, ch);
    updateCaretForMode();
    return nil;
}

static void installKeyMonitor() {
    if (gKeyMonitor) return;
    gKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                        handler:^NSEvent*(NSEvent* e) {
        @autoreleasepool { return handleKeyEvent(e); }
    }];
}
static void removeKeyMonitor() {
    if (!gKeyMonitor) return;
    [NSEvent removeMonitor:gKeyMonitor];
    gKeyMonitor = nil;
}

// ════════════════════════════════════════════════════════════════════════════
//  Toggle command
// ════════════════════════════════════════════════════════════════════════════
static void toggleVimMode() {
    state.vimEnabled = !state.vimEnabled;
    g_config.vimEnabled = state.vimEnabled;
    saveConfig();

    if (gReady)
        nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                             (uintptr_t)funcItem[0]._cmdID, state.vimEnabled ? 1 : 0);

    if (state.vimEnabled) {
        installKeyMonitor();
        g_normalMode->enter();
        updateCaretForMode();
        Utils::setStatus(TEXT("-- NORMAL --"));
    } else {
        NppHandle h = curSci();
        if (h) {
            sci(h, SCI_CALLTIPCANCEL);
            sci(h, SCI_SETCARETSTYLE, CARETSTYLE_LINE);
            sci(h, SCI_SETOVERTYPE, 0);
            int pos = (int)sci(h, SCI_GETCURRENTPOS);
            sci(h, SCI_SETSEL, (uintptr_t)pos, (intptr_t)pos);
        }
        removeKeyMonitor();
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  About dialog (programmatic AppKit; port of IDD_ABOUT)
// ════════════════════════════════════════════════════════════════════════════
@interface NppVimAbout : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow* window;
@end
@implementation NppVimAbout
- (void)run {
    NSRect r = NSMakeRect(0, 0, 420, 230);
    self.window = [[NSWindow alloc] initWithContentRect:r
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
          backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"About NppVim";
    self.window.delegate = self;
    [self.window setReleasedWhenClosed:NO];
    NSView* v = self.window.contentView;

    NSTextField* title = [NSTextField labelWithString:@"NppVim"];
    title.font = [NSFont boldSystemFontOfSize:20];
    title.frame = NSMakeRect(20, 184, 380, 28);
    title.alignment = NSTextAlignmentCenter;
    [v addSubview:title];

    NSTextField* d1 = [NSTextField labelWithString:@"Vim emulation for Notepad++ (macOS port)"];
    d1.frame = NSMakeRect(20, 156, 380, 18); d1.alignment = NSTextAlignmentCenter;
    [v addSubview:d1];

    NSTextField* d2 = [NSTextField labelWithString:@"Explore features with :tutor / :t and :help / :h"];
    d2.frame = NSMakeRect(20, 134, 380, 18); d2.alignment = NSTextAlignmentCenter;
    d2.textColor = [NSColor secondaryLabelColor];
    [v addSubview:d2];

    NSTextField* author = [NSTextField labelWithString:@"Original Windows plugin by Himanshu (h-jangra) — MIT"];
    author.frame = NSMakeRect(20, 104, 380, 18); author.alignment = NSTextAlignmentCenter;
    author.textColor = [NSColor secondaryLabelColor];
    [v addSubview:author];

    NSButton* gh = [NSButton buttonWithTitle:@"GitHub" target:self action:@selector(openGH:)];
    gh.frame = NSMakeRect(60, 54, 90, 30); [v addSubview:gh];
    NSButton* dn = [NSButton buttonWithTitle:@"Donate" target:self action:@selector(openDonate:)];
    dn.frame = NSMakeRect(165, 54, 90, 30); [v addSubview:dn];
    NSButton* close = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeIt:)];
    close.frame = NSMakeRect(270, 54, 90, 30); close.keyEquivalent = @"\r"; [v addSubview:close];

    [self.window center];
    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];
}
- (void)openGH:(id)s     { NppVimOpenURL("https://github.com/h-jangra/nppvim"); }
- (void)openDonate:(id)s { NppVimOpenURL("https://paypal.me/h8imansh8u"); }
- (void)closeIt:(id)s    { [NSApp stopModal]; }
- (void)windowWillClose:(NSNotification*)n { [NSApp stopModal]; }
@end

static void aboutDialog_impl() {
    @autoreleasepool { NppVimAbout* a = [[NppVimAbout alloc] init]; [a run]; }
}

// ════════════════════════════════════════════════════════════════════════════
//  Configuration dialog (programmatic AppKit; port of IDD_CONFIG)
// ════════════════════════════════════════════════════════════════════════════
@interface NppVimConfig : NSObject <NSWindowDelegate>
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSPopUpButton* escapePopup;
@property(nonatomic, strong) NSTextField* customField;
@property(nonatomic, strong) NSTextField* timeoutField;
@property(nonatomic, strong) NSButton* ctrlD;
@property(nonatomic, strong) NSButton* ctrlU;
@property(nonatomic, strong) NSButton* ctrlR;
@property(nonatomic, strong) NSButton* dClip;
@property(nonatomic, strong) NSButton* cClip;
@property(nonatomic, strong) NSButton* xClip;
@property(nonatomic, strong) NSButton* indicator;
@end
@implementation NppVimConfig
- (void)run {
    NSRect r = NSMakeRect(0, 0, 430, 330);
    self.window = [[NSWindow alloc] initWithContentRect:r
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
          backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"NppVim Configuration";
    self.window.delegate = self;
    [self.window setReleasedWhenClosed:NO];
    NSView* v = self.window.contentView;
    CGFloat y = 290;

    NSTextField* escLbl = [NSTextField labelWithString:@"Escape sequence:"];
    escLbl.frame = NSMakeRect(20, y, 130, 20); [v addSubview:escLbl];
    self.escapePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(155, y - 2, 150, 26)];
    [self.escapePopup addItemsWithTitles:@[@"Escape key only", @"jj", @"jk", @"kj", @"Custom"]];
    int sel = 0;
    if (g_config.escapeKey == "jj") sel = 1; else if (g_config.escapeKey == "jk") sel = 2;
    else if (g_config.escapeKey == "kj") sel = 3; else if (g_config.escapeKey == "custom") sel = 4;
    [self.escapePopup selectItemAtIndex:sel];
    self.escapePopup.target = self; self.escapePopup.action = @selector(escChanged:);
    [v addSubview:self.escapePopup];

    y -= 34;
    NSTextField* cLbl = [NSTextField labelWithString:@"Custom (2 chars):"];
    cLbl.frame = NSMakeRect(20, y, 130, 20); [v addSubview:cLbl];
    self.customField = [[NSTextField alloc] initWithFrame:NSMakeRect(155, y - 2, 150, 24)];
    self.customField.stringValue = [NSString stringWithUTF8String:g_config.customEscape.c_str()];
    self.customField.enabled = (sel == 4);
    [v addSubview:self.customField];

    y -= 34;
    NSTextField* tLbl = [NSTextField labelWithString:@"Escape timeout (ms):"];
    tLbl.frame = NSMakeRect(20, y, 150, 20); [v addSubview:tLbl];
    self.timeoutField = [[NSTextField alloc] initWithFrame:NSMakeRect(175, y - 2, 80, 24)];
    self.timeoutField.stringValue = [NSString stringWithFormat:@"%d", g_config.escapeTimeout];
    [v addSubview:self.timeoutField];

    y -= 38;
    NSTextField* ovLbl = [NSTextField labelWithString:@"Ctrl overrides (Normal/Visual):"];
    ovLbl.frame = NSMakeRect(20, y, 280, 18); ovLbl.textColor = [NSColor secondaryLabelColor];
    [v addSubview:ovLbl];
    y -= 26;
    self.ctrlD = [NSButton checkboxWithTitle:@"Ctrl+D / Ctrl+F (page down)" target:nil action:nil];
    self.ctrlD.frame = NSMakeRect(30, y, 250, 20);
    self.ctrlD.state = g_config.overrideCtrlD ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:self.ctrlD];
    y -= 24;
    self.ctrlU = [NSButton checkboxWithTitle:@"Ctrl+U / Ctrl+B (page up)" target:nil action:nil];
    self.ctrlU.frame = NSMakeRect(30, y, 250, 20);
    self.ctrlU.state = g_config.overrideCtrlU ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:self.ctrlU];
    y -= 24;
    self.ctrlR = [NSButton checkboxWithTitle:@"Ctrl+R (redo)" target:nil action:nil];
    self.ctrlR.frame = NSMakeRect(30, y, 250, 20);
    self.ctrlR.state = g_config.overrideCtrlR ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:self.ctrlR];

    y -= 34;
    NSTextField* clipLbl = [NSTextField labelWithString:@"Store deleted/changed text to clipboard:"];
    clipLbl.frame = NSMakeRect(20, y, 320, 18); clipLbl.textColor = [NSColor secondaryLabelColor];
    [v addSubview:clipLbl];
    y -= 26;
    self.dClip = [NSButton checkboxWithTitle:@"d" target:nil action:nil];
    self.dClip.frame = NSMakeRect(30, y, 60, 20);
    self.dClip.state = g_config.dStoreClipboard ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:self.dClip];
    self.cClip = [NSButton checkboxWithTitle:@"c" target:nil action:nil];
    self.cClip.frame = NSMakeRect(95, y, 60, 20);
    self.cClip.state = g_config.cStoreClipboard ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:self.cClip];
    self.xClip = [NSButton checkboxWithTitle:@"x" target:nil action:nil];
    self.xClip.frame = NSMakeRect(160, y, 60, 20);
    self.xClip.state = g_config.xStoreClipboard ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:self.xClip];

    y -= 30;
    self.indicator = [NSButton checkboxWithTitle:@"Show mode indicator (call-tip)" target:nil action:nil];
    self.indicator.frame = NSMakeRect(20, y, 320, 20);
    self.indicator.state = gShowIndicator ? NSControlStateValueOn : NSControlStateValueOff;
    [v addSubview:self.indicator];

    NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.frame = NSMakeRect(245, 14, 80, 30); cancel.keyEquivalent = @"\e"; [v addSubview:cancel];
    NSButton* ok = [NSButton buttonWithTitle:@"Save" target:self action:@selector(ok:)];
    ok.frame = NSMakeRect(332, 14, 80, 30); ok.keyEquivalent = @"\r"; [v addSubview:ok];

    [self.window center];
    [NSApp runModalForWindow:self.window];
    [self.window orderOut:nil];
}
- (void)escChanged:(id)s { self.customField.enabled = (self.escapePopup.indexOfSelectedItem == 4); }
- (void)ok:(id)s {
    switch (self.escapePopup.indexOfSelectedItem) {
        case 1: g_config.escapeKey = "jj"; break;
        case 2: g_config.escapeKey = "jk"; break;
        case 3: g_config.escapeKey = "kj"; break;
        case 4: g_config.escapeKey = "custom";
                g_config.customEscape = std::string([self.customField.stringValue UTF8String]); break;
        default: g_config.escapeKey = "esc"; break;
    }
    int to = [self.timeoutField intValue];
    if (to >= 100 && to <= 1000) g_config.escapeTimeout = to;
    g_config.overrideCtrlD = (self.ctrlD.state == NSControlStateValueOn);
    g_config.overrideCtrlU = (self.ctrlU.state == NSControlStateValueOn);
    g_config.overrideCtrlR = (self.ctrlR.state == NSControlStateValueOn);
    g_config.dStoreClipboard = (self.dClip.state == NSControlStateValueOn);
    g_config.cStoreClipboard = (self.cClip.state == NSControlStateValueOn);
    g_config.xStoreClipboard = (self.xClip.state == NSControlStateValueOn);
    gShowIndicator = (self.indicator.state == NSControlStateValueOn);
    saveConfig();
    [NSApp stopModal];
}
- (void)cancel:(id)s { [NSApp stopModal]; }
- (void)windowWillClose:(NSNotification*)n { [NSApp stopModal]; }
@end

static void showConfigDialog_impl() {
    @autoreleasepool { NppVimConfig* c = [[NppVimConfig alloc] init]; [c run]; }
}

// ════════════════════════════════════════════════════════════════════════════
//  Plugin exports
// ════════════════════════════════════════════════════════════════════════════
// friend of Utils — copies the handle table into Utils::nppData (private).
void setNppData(NppData data) { Utils::nppData = data; }

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    setNppData(data);   // mirror into Utils::nppData (Utils uses its own copy)

    loadConfig_impl();

    g_normalMode  = new NormalMode(state);
    g_visualMode  = new VisualMode(state);
    g_commandMode = new CommandMode(state);

    state.vimEnabled = g_config.vimEnabled;

    memset(funcItem, 0, sizeof(funcItem));
    strncpy(funcItem[0]._itemName, "Toggle Vim Mode", NPP_MENU_ITEM_SIZE - 1);
    funcItem[0]._pFunc = toggleVimMode;
    funcItem[0]._init2Check = g_config.vimEnabled;
    funcItem[0]._pShKey = nullptr;

    strncpy(funcItem[1]._itemName, "Configuration...", NPP_MENU_ITEM_SIZE - 1);
    funcItem[1]._pFunc = showConfigDialog_impl;
    funcItem[1]._pShKey = nullptr;

    funcItem[2]._itemName[0] = '\0';   // separator
    funcItem[2]._pFunc = nullptr;

    strncpy(funcItem[3]._itemName, "About...", NPP_MENU_ITEM_SIZE - 1);
    funcItem[3]._pFunc = aboutDialog_impl;
    funcItem[3]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char* getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem* getFuncsArray(int* nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification* n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_READY:
            gReady = true;
            if (state.vimEnabled) {
                installKeyMonitor();
                g_normalMode->enter();
                updateCaretForMode();
            }
            nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                                 (uintptr_t)funcItem[0]._cmdID, state.vimEnabled ? 1 : 0);
            break;
        case NPPN_BUFFERACTIVATED:
            if (state.vimEnabled) updateCaretForMode();
            break;
        case NPPN_SHUTDOWN:
            saveConfig();
            removeKeyMonitor();
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) { return 1; }
