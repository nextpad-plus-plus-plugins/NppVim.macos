#include "Marks.h"
#include "Utils.h"
#include "Scintilla.h"
#include <sstream>
#include <cctype>
#include <algorithm>
#include <cstring>

extern NppData nppData;

std::map<char, MarkInfo> Marks::localMarks;
std::map<char, MarkInfo> Marks::globalMarks;
MarkInfo Marks::lastJumpMark;
MarkInfo Marks::lastChangeMark;

void Marks::initializeMarkers(HWND hwndEdit) {
    if (!hwndEdit) return;

    // Local marks (a-z): small circle (marker 20 on legacy hosts,
    // NPPM_ALLOCATEMARKER slot on remapped hosts — see Utils.h)
    int localMarkerNum = Utils::localMarkMarker();
    NppVim_send(hwndEdit, SCI_MARKERDEFINE, localMarkerNum, SC_MARK_CIRCLE);
    NppVim_send(hwndEdit, SCI_MARKERSETFORE, localMarkerNum, RGB(0, 0, 255)); // Blue
    NppVim_send(hwndEdit, SCI_MARKERSETBACK, localMarkerNum, RGB(255, 255, 255));

    // Global marks (A-Z): small rectangle
    int globalMarkerNum = Utils::globalMarkMarker();
    NppVim_send(hwndEdit, SCI_MARKERDEFINE, globalMarkerNum, SC_MARK_SMALLRECT);
    NppVim_send(hwndEdit, SCI_MARKERSETFORE, globalMarkerNum, RGB(255, 0, 0)); // Red
    NppVim_send(hwndEdit, SCI_MARKERSETBACK, globalMarkerNum, RGB(255, 255, 255));

    // Ensure the margin is visible
    NppVim_send(hwndEdit, SCI_SETMARGINWIDTHN, 1, 16);
    NppVim_send(hwndEdit, SCI_SETMARGINTYPEN, 1, SC_MARGIN_SYMBOL);

    // No line highlighting
    NppVim_send(hwndEdit, SCI_MARKERENABLEHIGHLIGHT, 0, 0);
}

bool Marks::isValidMark(char mark) {
    return (mark >= 'a' && mark <= 'z') ||  // Local marks
        (mark >= 'A' && mark <= 'Z') ||  // Global marks
        mark == '.';                      // Last change position
}

int Marks::getMarkerNumber(char mark) {
    if (mark >= 'a' && mark <= 'z') {
        return Utils::localMarkMarker(); // circle marker for local marks
    }
    else if (mark >= 'A' && mark <= 'Z') {
        return Utils::globalMarkMarker(); // rectangle marker for global marks
    }
    return -1;
}

std::string Marks::getCurrentFilename() {
    // Host returns the full path as a UTF-8 char* (no UTF-16 conversion needed,
    // unlike Windows where NPPM_GETFULLCURRENTPATH yields wchar_t).
    char filename[MAX_PATH] = {0};
    NppVim_send(nppData._nppHandle, NPPM_GETFULLCURRENTPATH, MAX_PATH, (LPARAM)filename);
    return std::string(filename);
}

void Marks::setMark(HWND hwndEdit, char mark) {
    if (!hwndEdit || !isValidMark(mark)) return;

    int pos = (int)NppVim_send(hwndEdit, SCI_GETCURRENTPOS, 0, 0);
    int line = (int)NppVim_send(hwndEdit, SCI_LINEFROMPOSITION, pos, 0);
    int lineStart = (int)NppVim_send(hwndEdit, SCI_POSITIONFROMLINE, line, 0);
    int column = pos - lineStart;

    MarkInfo markInfo;
    markInfo.line = line;
    markInfo.column = column;
    markInfo.filename = getCurrentFilename();
    markInfo.isGlobal = (mark >= 'A' && mark <= 'Z');

    if (mark >= 'a' && mark <= 'z') {
        localMarks[mark] = markInfo;
        updateMarkerDisplay(hwndEdit, mark);

        char statusMsg[64];
        sprintf_s(statusMsg, "Local mark '%c' set at line %d", mark, line + 1);
        Utils::setStatus(std::string(statusMsg, statusMsg + strlen(statusMsg)).c_str());
    }
    else if (mark >= 'A' && mark <= 'Z') {
        globalMarks[mark] = markInfo;
        updateMarkerDisplay(hwndEdit, mark);

        char statusMsg[64];
        sprintf_s(statusMsg, "Global mark '%c' set at line %d", mark, line + 1);
        Utils::setStatus(std::string(statusMsg, statusMsg + strlen(statusMsg)).c_str());
    }
    else if (mark == '.') {
        lastChangeMark = markInfo;
        Utils::setStatus(TEXT("Last change mark set"));
    }
}

void Marks::updateMarkerDisplay(HWND hwndEdit, char mark) {
    if (!hwndEdit) return;

    int markerNum = getMarkerNumber(mark);
    if (markerNum == -1) return;

    auto it = (mark >= 'a' && mark <= 'z') ? localMarks.find(mark) : globalMarks.find(mark);
    if (it == ((mark >= 'a' && mark <= 'z') ? localMarks.end() : globalMarks.end())) return;

    // For local marks, only show if in current file
    if (mark >= 'a' && mark <= 'z') {
        if (it->second.filename != getCurrentFilename()) {
            NppVim_send(hwndEdit, SCI_MARKERDELETE, it->second.line, markerNum);
            return;
        }
    }

    // Remove any existing marker at this line
    NppVim_send(hwndEdit, SCI_MARKERDELETE, it->second.line, markerNum);

    // Add marker at the marked line
    NppVim_send(hwndEdit, SCI_MARKERADD, it->second.line, markerNum);
}

void Marks::removeMarkerDisplay(HWND hwndEdit, char mark) {
    if (!hwndEdit) return;

    int markerNum = getMarkerNumber(mark);
    if (markerNum == -1) return;

    auto it = (mark >= 'a' && mark <= 'z') ? localMarks.find(mark) : globalMarks.find(mark);
    if (it != ((mark >= 'a' && mark <= 'z') ? localMarks.end() : globalMarks.end())) {
        NppVim_send(hwndEdit, SCI_MARKERDELETE, it->second.line, markerNum);
    }
}
bool Marks::jumpToMark(HWND hwndEdit, char mark, bool isBacktick) {
    if (!hwndEdit || !isValidMark(mark)) {
        Utils::setStatus(TEXT("Invalid mark or no editor"));
        return false;
    }

    MarkInfo* markInfo = nullptr;
    bool fileSwitched = false;

    if (mark >= 'a' && mark <= 'z') {
        auto it = localMarks.find(mark);
        if (it == localMarks.end()) {
            Utils::setStatus(TEXT("Local mark not set"));
            return false;
        }
        if (it->second.filename != getCurrentFilename()) {
            Utils::setStatus(TEXT("Local mark in different file"));
            return false;
        }
        markInfo = &it->second;
    }
    else if (mark >= 'A' && mark <= 'Z') {
        auto it = globalMarks.find(mark);
        if (it == globalMarks.end()) {
            Utils::setStatus(TEXT("Global mark not set"));
            return false;
        }

        // Switch files for global marks if needed (UTF-8 path direct to host)
        std::string currentFile = getCurrentFilename();
        if (it->second.filename != currentFile) {
            NppVim_send(nppData._nppHandle, NPPM_DOOPEN, 0, (LPARAM)it->second.filename.c_str());

            hwndEdit = Utils::getCurrentScintillaHandle();
            if (!hwndEdit) {
                Utils::setStatus(TEXT("Failed to switch file"));
                return false;
            }
            fileSwitched = true;
        }
        markInfo = &it->second;
    }
    else if (mark == '.') {
        if (lastChangeMark.line == -1) {
            Utils::setStatus(TEXT("Last change mark not set"));
            return false;
        }
        markInfo = &lastChangeMark;
    }

    if (!markInfo || markInfo->line == -1) {
        Utils::setStatus(TEXT("Mark position invalid"));
        return false;
    }

    // Jump to the mark
    int lineCount = (int)NppVim_send(hwndEdit, SCI_GETLINECOUNT, 0, 0);
    if (markInfo->line >= lineCount) {
        Utils::setStatus(TEXT("Mark line out of range"));
        return false;
    }

    int targetPos;
    if (isBacktick) {
        // ` jumps to exact position
        int linePos = (int)NppVim_send(hwndEdit, SCI_POSITIONFROMLINE, markInfo->line, 0);
        int lineEnd = (int)NppVim_send(hwndEdit, SCI_GETLINEENDPOSITION, markInfo->line, 0);
        targetPos = linePos + markInfo->column;
        if (targetPos > lineEnd) targetPos = lineEnd;
    }
    else {
        // ' jumps to first non-blank character of line
        targetPos = (int)NppVim_send(hwndEdit, SCI_POSITIONFROMLINE, markInfo->line, 0);
        int lineEnd = (int)NppVim_send(hwndEdit, SCI_GETLINEENDPOSITION, markInfo->line, 0);

        while (targetPos < lineEnd) {
            char c = (char)NppVim_send(hwndEdit, SCI_GETCHARAT, targetPos, 0);
            if (!std::isspace(static_cast<unsigned char>(c))) break;
            targetPos++;
        }
    }

    NppVim_send(hwndEdit, SCI_GOTOPOS, targetPos, 0);
    NppVim_send(hwndEdit, SCI_SCROLLCARET, 0, 0);

    if (fileSwitched) {
        NppVim_send(hwndEdit, SCI_SETCARETSTYLE, CARETSTYLE_BLOCK, 0);

        int caret = (int)NppVim_send(hwndEdit, SCI_GETCURRENTPOS, 0, 0);
        NppVim_send(hwndEdit, SCI_SETSEL, caret, caret);

        Utils::setStatus(TEXT("-- NORMAL --"));
    }

    char statusMsg[64];
    sprintf_s(statusMsg, "Jumped to mark '%c' at line %d", mark, markInfo->line + 1);
    Utils::setStatus(std::string(statusMsg, statusMsg + strlen(statusMsg)).c_str());

    return true;
}

void Marks::deleteMark(HWND hwndEdit, char mark) {
    if (!isValidMark(mark)) return;

    if (mark >= 'a' && mark <= 'z') {
        removeMarkerDisplay(hwndEdit, mark);
        localMarks.erase(mark);
        Utils::setStatus(TEXT("Local mark deleted"));
    }
    else if (mark >= 'A' && mark <= 'Z') {
        removeMarkerDisplay(hwndEdit, mark);
        globalMarks.erase(mark);
        Utils::setStatus(TEXT("Global mark deleted"));
    }
}

void Marks::clearAllMarks(HWND hwndEdit) {
    if (hwndEdit) {
        // Clear all markers from the editor
        NppVim_send(hwndEdit, SCI_MARKERDELETEALL, Utils::localMarkMarker(), 0);
        NppVim_send(hwndEdit, SCI_MARKERDELETEALL, Utils::globalMarkMarker(), 0);
    }

    localMarks.clear();
    globalMarks.clear();
    lastChangeMark = MarkInfo(-1, -1, "", false);

    Utils::setStatus(TEXT("All marks cleared"));
}

std::string Marks::listMarks(HWND hwndEdit) {
    std::ostringstream oss;
    oss << "Marks:\n";
    oss << "-----\n";

    if (!localMarks.empty()) {
        oss << "Local marks (a-z):\n";
        for (auto& pair : localMarks) {
            oss << "  " << pair.first << " : line " << (pair.second.line + 1)
                << ", col " << pair.second.column << "\n";
        }
    }

    if (!globalMarks.empty()) {
        oss << "\nGlobal marks (A-Z):\n";
        for (auto& pair : globalMarks) {
            oss << "  " << pair.first << " : line " << (pair.second.line + 1)
                << ", col " << pair.second.column
                << " [" << pair.second.filename << "]\n";
        }
    }

    if (lastChangeMark.line != -1) {
        oss << "\nLast change position:\n";
        oss << "  . : line " << (lastChangeMark.line + 1)
            << ", col " << lastChangeMark.column << "\n";
    }

    if (localMarks.empty() && globalMarks.empty() && lastChangeMark.line == -1) {
        oss << "No marks set\n";
    }

    return oss.str();
}