// Utils.mm — macOS port of Utils.cpp
#include "Utils.h"
#include "NppVim.h"
#include "NormalMode.h"
#include "VisualMode.h"
#include <vector>
#include <cstring>

NppData Utils::nppData;

extern NormalMode* g_normalMode;
extern VisualMode* g_visualMode;

int Utils::sci(HWND h, int msg, WPARAM w, LPARAM l) {
    return (int)NppVim_send(h, msg, w, l);
}

// ── ID slot resolution (see Utils.h) ─────────────────────────────────────
// Resolved lazily on first use, once. On remapped hosts, allocation failure
// (pool exhausted) falls back to the legacy numbers — any fixed number can
// collide at that point, and the legacy ones at least match the shipped
// behavior.
namespace {
struct VimSlots {
    int subMatch = 20, subRepl = 21;   // legacy indicator defaults
    int localMk  = 20, globalMk = 21;  // legacy marker defaults
};
}
static const VimSlots &resolvedSlots(const NppData &npp) {
    static VimSlots s;
    static bool resolved = false;
    if (resolved) return s;
    resolved = true;
    if (NppVim_send(npp._nppHandle, NPPM_GETBOOKMARKID, 0, 0) == 20) {
        int ind = -1;
        if (NppVim_send(npp._nppHandle, NPPM_ALLOCATEINDICATOR, 2, (LPARAM)&ind) && ind > 0) {
            s.subMatch = ind;
            s.subRepl  = ind + 1;
        } else {
            s.subMatch = 27;           // the one unowned slot in the new layout
            s.subRepl  = 20;           // inside the plugin pool; last resort
        }
        int mk = -1;
        if (NppVim_send(npp._nppHandle, NPPM_ALLOCATEMARKER, 2, (LPARAM)&mk) && mk > 0) {
            s.localMk  = mk;
            s.globalMk = mk + 1;
        }
    }
    return s;
}
int Utils::subMatchIndicator()  { return resolvedSlots(nppData).subMatch; }
int Utils::subReplIndicator()   { return resolvedSlots(nppData).subRepl; }
int Utils::localMarkMarker()    { return resolvedSlots(nppData).localMk; }
int Utils::globalMarkMarker()   { return resolvedSlots(nppData).globalMk; }

HWND Utils::getCurrentScintillaHandle()
{
  int which = 0;
  NppVim_send(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (LPARAM)&which);
  return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

void Utils::setStatus(const TCHAR *msg)
{
  // Windows pushed mode text ("-- NORMAL --") to the Notepad++ status bar via
  // NPPM_SETSTATUSBAR. That message is a no-op on the macOS host, so route the
  // text to the call-tip mode indicator implemented in NppVim.mm instead.
  NppVimSetStatusUTF8(msg ? msg : "");
}

void Utils::clearSearchHighlights(HWND hwndEdit)
{
  if (!hwndEdit)
    return;

  int docLen = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);
  NppVim_send(hwndEdit, SCI_SETINDICATORCURRENT, 0, 0);
  NppVim_send(hwndEdit, SCI_INDICATORCLEARRANGE, 0, docLen);
}

std::pair<int, int> Utils::findWordBounds(HWND hwndEdit, int pos)
{
  // For lowercase 'w'
  return findWordBoundsEx(hwndEdit, pos, false);
}

std::pair<int, int> Utils::findWordBoundsEx(HWND hwndEdit, int pos, bool bigWord) {
    int docLen = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);
    if (pos >= docLen) return {pos, pos};
    
    int style = bigWord ? 1 : 0;
    
    int wordStart = (int)NppVim_send(hwndEdit, SCI_WORDSTARTPOSITION, pos, style);
    int wordEnd = (int)NppVim_send(hwndEdit, SCI_WORDENDPOSITION, pos, style);
    
    return {wordStart, wordEnd};
}

int Utils::findMatchingBracket(HWND hwndEdit, int pos, char openChar, char closeChar) {
    int m = (int)NppVim_send(hwndEdit, SCI_BRACEMATCH, pos, 0);
    if (m == -1)
        m = (int)NppVim_send(hwndEdit, SCI_BRACEMATCH, pos - 1, 0);
    return m;
}

std::pair<int, int> Utils::findQuoteBounds(HWND hwndEdit, int pos, char quoteChar) {
    int line = NppVim_send(hwndEdit, SCI_LINEFROMPOSITION, pos, 0);
    int lineStart = NppVim_send(hwndEdit, SCI_POSITIONFROMLINE, line, 0);
    int lineEnd = NppVim_send(hwndEdit, SCI_GETLINEENDPOSITION, line, 0);

    int startPos = -1;
    int endPos = -1;
    int minDistance = lineEnd - lineStart;

    bool inQuote = false;
    int quoteStart = -1;

    for (int i = lineStart; i <= lineEnd; i++) {
        char ch = (char)NppVim_send(hwndEdit, SCI_GETCHARAT, i, 0);
        
        if (ch == quoteChar) {
            if (!inQuote) {
                quoteStart = i;
                inQuote = true;
            } else {
                if (pos >= quoteStart && pos <= i) {
                    return { quoteStart, i };
                } else {
                    int distance = (std::min)(abs(pos - quoteStart), abs(pos - i));
                    if (distance < minDistance) {
                        minDistance = distance;
                        startPos = quoteStart;
                        endPos = i;
                    }
                }
                inQuote = false;
            }
        }
    }

    if (startPos == -1 || endPos == -1) {
        return { -1, -1 };
    }

    return { startPos, endPos };
}

void Utils::updateSearchHighlight(HWND hwndEdit, const std::string &searchTerm, bool useRegex)
{
  if (searchTerm.empty())
  {
    clearSearchHighlights(hwndEdit);
    return;
  }

  int docLen = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);

  NppVim_send(hwndEdit, SCI_SETINDICATORCURRENT, 0, 0);
  NppVim_send(hwndEdit, SCI_INDICATORCLEARRANGE, 0, docLen);

  NppVim_send(hwndEdit, SCI_INDICSETSTYLE, 0, INDIC_ROUNDBOX);
  NppVim_send(hwndEdit, SCI_INDICSETFORE, 0, RGB(255, 255, 0));
  NppVim_send(hwndEdit, SCI_INDICSETALPHA, 0, 100);
  NppVim_send(hwndEdit, SCI_INDICSETOUTLINEALPHA, 0, 255);

  int flags = (useRegex ? SCFIND_REGEXP : 0);
  NppVim_send(hwndEdit, SCI_SETSEARCHFLAGS, flags, 0);

  int pos = 0;
  while (pos < docLen)
  {
    NppVim_send(hwndEdit, SCI_SETTARGETSTART, pos, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETEND, docLen, 0);

    int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                   (WPARAM)searchTerm.length(), (LPARAM)searchTerm.c_str());

    if (found == -1)
      break;

    int start = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
    int end = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);

    NppVim_send(hwndEdit, SCI_SETINDICATORCURRENT, 0, 0);
    NppVim_send(hwndEdit, SCI_INDICATORFILLRANGE, start, end - start);

    pos = end;
    if (end <= start)
      pos = start + 1;
  }
}

void Utils::showCurrentMatchPosition(HWND hwndEdit, const std::string &searchTerm, bool useRegex)
{
  if (searchTerm.empty())
    return;

  int docLen = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);
  int currentPos = (int)NppVim_send(hwndEdit, SCI_GETCURRENTPOS, 0, 0);

  int flags = (useRegex ? SCFIND_REGEXP : 0);
  NppVim_send(hwndEdit, SCI_SETSEARCHFLAGS, flags, 0);

  int totalMatches = 0;
  int currentMatchIndex = 0;
  int pos = 0;

  while (pos < docLen)
  {
    NppVim_send(hwndEdit, SCI_SETTARGETSTART, pos, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETEND, docLen, 0);

    int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                   (WPARAM)searchTerm.length(), (LPARAM)searchTerm.c_str());

    if (found == -1)
      break;

    int start = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
    int end = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);

    totalMatches++;

    if (currentPos >= start && currentPos <= end && currentMatchIndex == 0)
    {
      currentMatchIndex = totalMatches;
    }

    pos = end;
    if (end <= start)
      pos = start + 1;
  }

  if (totalMatches > 0 && currentMatchIndex > 0)
  {
    std::string status = "Match " + std::to_string(currentMatchIndex) + " of " + std::to_string(totalMatches);
    std::string wstatus(status.begin(), status.end());
    setStatus(wstatus.c_str());
  }
}

int Utils::countSearchMatches(HWND hwndEdit, const std::string &searchTerm, bool useRegex)
{
  if (!hwndEdit || searchTerm.empty())
    return 0;

  int flags = (useRegex ? SCFIND_REGEXP : 0);
  NppVim_send(hwndEdit, SCI_SETSEARCHFLAGS, flags, 0);

  int docLen = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);
  int count = 0;
  int pos = 0;

  while (pos < docLen)
  {
    NppVim_send(hwndEdit, SCI_SETTARGETSTART, pos, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETEND, docLen, 0);

    int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                   (WPARAM)searchTerm.length(), (LPARAM)searchTerm.c_str());

    if (found == -1)
      break;

    count++;
    pos = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);
  }

  return count;
}

void Utils::handleIndent(HWND hwndEdit, int count) {
    NppVim_send(hwndEdit, SCI_BEGINUNDOACTION, 0, 0);

    NppVim_send(hwndEdit, SCI_TAB, 0, 0);

    NppVim_send(hwndEdit, SCI_ENDUNDOACTION, 0, 0);

}

void Utils::handleUnindent(HWND hwndEdit, int count) {
    NppVim_send(hwndEdit, SCI_BEGINUNDOACTION, 0, 0);

    NppVim_send(hwndEdit, SCI_BACKTAB, 0, 0);

    NppVim_send(hwndEdit, SCI_ENDUNDOACTION, 0, 0);

}

void Utils::handleAutoIndent(HWND hwndEdit, int count) {
    NppVim_send(hwndEdit, SCI_BEGINUNDOACTION, 0, 0);

    int lineStart = (int)NppVim_send(hwndEdit, SCI_LINEFROMPOSITION,
                      (int)NppVim_send(hwndEdit, SCI_GETSELECTIONSTART, 0, 0), 0);
    int lineEnd = (int)NppVim_send(hwndEdit, SCI_LINEFROMPOSITION,
                    (int)NppVim_send(hwndEdit, SCI_GETSELECTIONEND, 0, 0), 0);

    for (int line = lineStart; line <= lineEnd; line++) {
        int lineStartPos = (int)NppVim_send(hwndEdit, SCI_POSITIONFROMLINE, line, 0);
        int lineEndPos = (int)NppVim_send(hwndEdit, SCI_GETLINEENDPOSITION, line, 0);

        int firstNonSpace = lineStartPos;
        while (firstNonSpace < lineEndPos) {
            char ch = (char)NppVim_send(hwndEdit, SCI_GETCHARAT, firstNonSpace, 0);
            if (ch != ' ' && ch != '\t') break;
            firstNonSpace++;
        }

        if (firstNonSpace > lineStartPos) {
            NppVim_send(hwndEdit, SCI_DELETERANGE, lineStartPos, firstNonSpace - lineStartPos);
        }
    }

    NppVim_send(hwndEdit, SCI_ENDUNDOACTION, 0, 0);

    if (state.mode == VISUAL && g_normalMode) {
        g_normalMode->enter();
    }
}

int Utils::caretPos(HWND hwnd) {
    return (int)NppVim_send(hwnd, SCI_GETCURRENTPOS, 0, 0);
}

int Utils::caretColumn(HWND hwnd) {
    return (int)NppVim_send(hwnd, SCI_GETCOLUMN, caretPos(hwnd), 0);
}

int Utils::caretLine(HWND hwnd) {
    int pos = caretPos(hwnd);
    return (int)NppVim_send(hwnd, SCI_LINEFROMPOSITION, pos, 0);
}

int Utils::lineStart(HWND hwnd, int line) {
    return (int)NppVim_send(hwnd, SCI_POSITIONFROMLINE, line, 0);
}

int Utils::lineEnd(HWND hwnd, int line) {
    return (int)NppVim_send(hwnd, SCI_GETLINEENDPOSITION, line, 0);
}

int Utils::lineCount(HWND hwnd) {
    return (int)NppVim_send(hwnd, SCI_GETLINECOUNT, 0, 0);
}

std::pair<int,int> Utils::lineRange(HWND hwnd, int line, bool includeNewline) {
    int start = lineStart(hwnd, line);
    int total = lineCount(hwnd);
    int end = (line < total - 1)
        ? lineStart(hwnd, line + 1)
        : lineEnd(hwnd, line) + 1;
    if (!includeNewline && end > start) end--;
    return {start, end};
}

std::pair<int,int> Utils::lineRangeFromPos(HWND hwnd, int pos, bool includeNewline) {
    int line = (int)NppVim_send(hwnd, SCI_LINEFROMPOSITION, pos, 0);
    return lineRange(hwnd, line, includeNewline);
}

void Utils::beginUndo(HWND hwnd) {
    NppVim_send(hwnd, SCI_BEGINUNDOACTION, 0, 0);
}

void Utils::endUndo(HWND hwnd) {
    NppVim_send(hwnd, SCI_ENDUNDOACTION, 0, 0);
}

void Utils::select(HWND hwnd, int a, int b) {
    NppVim_send(hwnd, SCI_SETSEL, a, b);
}

void Utils::cut(HWND hwnd, int a, int b) {
    select(hwnd, a, b);
    NppVim_send(hwnd, SCI_CUT, 0, 0);
}

void Utils::copy(HWND hwnd, int a, int b) {
    select(hwnd, a, b);
    NppVim_send(hwnd, SCI_COPY, 0, 0);
}

void Utils::clear(HWND hwnd, int a, int b) {
    select(hwnd, a, b);
    NppVim_send(hwnd, SCI_CLEAR, 0, 0);
}

void Utils::toUpper(HWND hwnd, int a, int b) {
    select(hwnd, a, b);
    NppVim_send(hwnd, SCI_UPPERCASE, 0, 0);
}

void Utils::toLower(HWND hwnd, int a, int b) {
    select(hwnd, a, b);
    NppVim_send(hwnd, SCI_LOWERCASE, 0, 0);
}

void Utils::replaceChar(HWND hwnd, int pos, char ch) {
    NppVim_send(hwnd, SCI_SETTARGETRANGE, pos, pos + 1);
    NppVim_send(hwnd, SCI_REPLACETARGET, 1, (LPARAM)&ch);
}

void Utils::replaceRange(HWND hwnd, int a, int b, char ch) {
    for (int i = a; i < b; i++) {
        char c = (char)NppVim_send(hwnd, SCI_GETCHARAT, i, 0);
        if (c != '\r' && c != '\n') {
            replaceChar(hwnd, i, ch);
        }
    }
}

BlockSelection Utils::blockSelection(HWND hwnd) {
    int a = (int)NppVim_send(hwnd, SCI_GETRECTANGULARSELECTIONANCHOR, 0, 0);
    int c = (int)NppVim_send(hwnd, SCI_GETRECTANGULARSELECTIONCARET, 0, 0);

    int la = (int)NppVim_send(hwnd, SCI_LINEFROMPOSITION, a, 0);
    int lc = (int)NppVim_send(hwnd, SCI_LINEFROMPOSITION, c, 0);

    int ca = (int)NppVim_send(hwnd, SCI_GETCOLUMN, a, 0);
    int cc = (int)NppVim_send(hwnd, SCI_GETCOLUMN, c, 0);

    return {
        (std::min)(la, lc),
        (std::max)(la, lc),
        (std::min)(ca, cc),
        (std::max)(ca, cc)
    };
}

void Utils::setBlockSelection(HWND hwnd, int anchor, int caret) {
    NppVim_send(hwnd, SCI_SETSELECTIONMODE, SC_SEL_RECTANGLE, 0);
    NppVim_send(hwnd, SCI_SETRECTANGULARSELECTIONANCHOR, anchor, 0);
    NppVim_send(hwnd, SCI_SETRECTANGULARSELECTIONCARET, caret, 0);
    NppVim_send(hwnd, SCI_SETCURRENTPOS, caret, 0);
}

void Utils::clearBlockSelection(HWND hwnd) {
    NppVim_send(hwnd, SCI_SETSELECTIONMODE, SC_SEL_STREAM, 0);
}

void Utils::forEachBlockCell(HWND hwnd, const BlockSelection& blk, void (*fn)(HWND,int)) {
    for (int line = blk.startLine; line <= blk.endLine; line++) {
        int ls = lineStart(hwnd, line);
        int le = lineEnd(hwnd, line);
        int cs = (int)NppVim_send(hwnd, SCI_FINDCOLUMN, line, blk.startCol);
        int ce = (int)NppVim_send(hwnd, SCI_FINDCOLUMN, line, blk.endCol);
        if (cs > le) cs = le;
        if (ce > le) ce = le;
        for (int p = cs; p < ce; p++) fn(hwnd, p);
    }
}

void Utils::pasteAfter(HWND hwnd, int count, bool linewise) {
    int pos = caretPos(hwnd);
    int line = caretLine(hwnd);
    if (linewise) {
        auto r = lineRange(hwnd, line, true);
        NppVim_send(hwnd, SCI_GOTOPOS, r.second, 0);
    } else {
        NppVim_send(hwnd, SCI_GOTOPOS, (int)NppVim_send(hwnd, SCI_POSITIONAFTER, pos, 0), 0);
    }
    for (int i = 0; i < count; i++) { NppVim_send(hwnd, SCI_PASTE, 0, 0); }

     int newPos = caretPos(hwnd);
    NppVim_send(hwnd, SCI_SETSEL, newPos, newPos);
}

void Utils::pasteBefore(HWND hwnd, int count, bool linewise) {
    int pos = caretPos(hwnd);
    int line = caretLine(hwnd);
    if (linewise) {
        NppVim_send(hwnd, SCI_GOTOPOS, lineStart(hwnd, line), 0);
    } else {
        NppVim_send(hwnd, SCI_GOTOPOS, pos, 0);
    }
    for (int i = 0; i < count; i++) {
        NppVim_send(hwnd, SCI_PASTE, 0, 0);
    }
}

void Utils::joinLines(HWND hwnd, int startLine, int count, bool withSpace) {
    for (int i = 0; i < count; i++) {
        int end = lineEnd(hwnd, startLine);
        int next = lineStart(hwnd, startLine + 1);
        if (startLine + i + 1 >= lineCount(hwnd)) break;
        select(hwnd, end, next);
        NppVim_send(hwnd, SCI_REPLACESEL, 0, (LPARAM)(withSpace ? " " : ""));
    }
}

void Utils::charSearch(HWND hwnd, VimState& state, char type, char ch, int count) {
    bool forward = (type == 'f' || type == 't');
    bool till = (type == 't' || type == 'T');

    if (till) {
        if (forward) Motion::tillChar(hwnd, count, ch);
        else Motion::tillCharBack(hwnd, count, ch);
    } else {
        if (forward) Motion::nextChar(hwnd, count, ch);
        else Motion::prevChar(hwnd, count, ch);
    }

    state.lastSearchChar = ch;
    state.lastSearchForward = forward;
    state.lastSearchTill = till;
}

void Utils::setClipboardText(const std::string& text) {
    // Win32 clipboard (OpenClipboard/SetClipboardData) → NSPasteboard (NppVim.mm).
    NppVimClipboardSet(text);
}

static void appendSection(std::string& out, const std::string& title, const Keymap& km) {
    out += "\n";
    out += title;
    out += "\n";
    out += std::string(title.size(), '-');
    out += "\n";

    size_t maxKey = 0;
    for (const auto& b : km.getBindings())
        maxKey = (std::max)(maxKey, b.keys.size());

    for (const auto& b : km.getBindings()) {
        out += ":";
        out += b.keys;
        out += std::string(maxKey - b.keys.size() + 2, ' ');
        out += "- ";
        out += b.desc;
        out += "\n";
    }
}

std::string Utils::buildTutorText() {
    std::string out;

    out += "NppVim Tutor\n";
    out += "============\n\n";

    auto append = [&](const char* title, const Keymap* km) {
        if (!km) return;

        out += title;
        out += "\n";
        out += std::string(strlen(title), '-') + "\n";

        size_t pad = 0;
        for (const auto& b : km->getBindings())
            pad = (std::max)(pad, b.keys.size());

        for (const auto& b : km->getBindings()) {
            out += "  ";
            out += b.keys;
            out += std::string(pad - b.keys.size() + 2, ' ');
            out += "- ";
            out += b.desc;
            out += "\n";
        }
        out += "\n";
    };

    append("Normal Mode", g_normalKeymap.get());
    append("Visual Mode", g_visualKeymap.get());
    append("Command Mode", g_commandKeymap.get());
    out += "\n";
    out += ":s/foo/bar/g        - Replace all matches in line\n";
    out += ":s/foo/bar/c        - Replace with confirmation\n";
    out += ":s/foo/bar/gc       - Replace all in line (confirm)\n";
    out += ":s/foo/bar/i        - Case-insensitive replace\n";
    out += ":s/foo/bar/l        - Literal (no regex) replace\n";
    out += ":%s/foo/bar/gc      - Replace in whole file (confirm)\n";

    return out;
}

int Utils::getCharBlocking() {
    // Windows pumped a nested GetMessage loop to read the next typed character
    // for the :s///c confirm prompt (y/n/a/q). Under the macOS NSEvent local
    // monitor that approach doesn't apply, so NppVim.mm surfaces a modal
    // y/n/a/q chooser (NSAlert) and returns the chosen character.
    return NppVimConfirmPrompt();
}

std::string Utils::getRegisterContent(char reg) {
    if (state.registers.find(reg) != state.registers.end()) {
        return state.registers[reg];
    }
    return "";
}

void Utils::setRegisterContent(char reg, const std::string& content) {
    state.registers[reg] = content;
}

void Utils::appendToRegister(char reg, const std::string& content) {
    if (state.registers.find(reg) != state.registers.end()) {
        state.registers[reg] += content;
    } else {
        state.registers[reg] = content;
    }
}

bool Utils::isValidRegister(char c) {
    // Valid registers: a-z (named), 0-9 (numbered), " (default), _ (blackhole), 
    // +/* (clipboard), / (search), : (command), . (last inserted)
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || 
           c == '"' || c == '_' || c == '+' || c == '*' || 
           c == '/' || c == ':' || c == '.';
}

char Utils::getCurrentRegister() {
    return state.defaultRegister;
}

void Utils::setCurrentRegister(char reg) {
    if (isValidRegister(reg)) {
        state.defaultRegister = reg;
    }
}

void Utils::storeRegister(char reg, const std::string& text){
    if (reg == '+' || reg == '*')
        Utils::setClipboardText(text);
    else
        Utils::setRegisterContent(reg, text);
        if(reg=='"')
            Utils::setClipboardText(text);
}

std::string Utils::getTextRange(HWND h, int start, int end){
    std::vector<char> buffer(end - start + 1);
    Sci_TextRangeFull tr;
    tr.chrg.cpMin = start;
    tr.chrg.cpMax = end;
    tr.lpstrText = buffer.data();
    NppVim_send(h, SCI_GETTEXTRANGEFULL, 0, (LPARAM)&tr);
    return std::string(buffer.data());
}

void Utils::rot13(HWND hwnd, int start, int end) {
    if (start >= end) return;

    std::string text = getTextRange(hwnd, start, end);

    for (char &c : text) {
        if (c >= 'a' && c <= 'z')
            c = 'a' + (c - 'a' + 13) % 26;
        else if (c >= 'A' && c <= 'Z')
            c = 'A' + (c - 'A' + 13) % 26;
    }

    NppVim_send(hwnd, SCI_SETTARGETSTART, start, 0);
    NppVim_send(hwnd, SCI_SETTARGETEND, end, 0);
    NppVim_send(hwnd, SCI_REPLACETARGET, text.size(), (LPARAM)text.c_str());
}