#pragma once
#include "NppVim.h"
#include "WinShim.h"
#include <string>

// Host-layout-aware slots (legacy hosts: 20/21) — see Utils.h.
#include "Utils.h"
#define IND_SUB_MATCH    (Utils::subMatchIndicator())
#define IND_SUB_REPL     (Utils::subReplIndicator())

class CommandMode {
public:
    CommandMode(VimState& state);

    void enter(char prompt);
    void exit();
    void handleKey(HWND hwndEdit, char c);
    void handleBackspace(HWND hwndEdit);
    void handleEnter(HWND hwndEdit);
    void updateStatus();

    // Search functions
    void performSearch(HWND hwndEdit, const std::string& searchTerm, bool useRegex = false);
    void searchNext(HWND hwndEdit);
    void searchPrevious(HWND hwndEdit);
    void handleMarksCommand(HWND hwndEdit, const std::string& commandLine);

private:
    VimState& state;
    std::string lastPreviewBuffer;

    void handleCommand(HWND hwndEdit);
    void handleColonCommand(HWND hwndEdit, const std::string& cmd);
    void handleSearchCommand(HWND hwndEdit, const std::string& searchTerm, bool useRegex = false);
    void handleSubstitutionCommand(HWND hwndEdit, const std::string& cmd);
    void performSubstitution(HWND hwndEdit, const std::string& pattern, const std::string& replacement,
         bool useRegex, bool caseInsensitive, bool replaceAll, bool confirmEach, bool globalReplace, int startPos, int endPos);

    void initSubstitutionIndicators(HWND h);
    void clearSubstitutionPreview(HWND h);
    void previewSubstitutionFromBuffer(HWND h);
    void showRegisters();
    void previewSubstitution(HWND h, const std::string &pat, const std::string &rep, bool regex, bool global);
    bool parseSubstitution(const std::string& buf,std::string& pat,std::string& rep,bool& regex,bool& global, bool& confirm);
};
