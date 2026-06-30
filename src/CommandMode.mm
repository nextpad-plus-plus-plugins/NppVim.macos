#include "CommandMode.h"
#include "Utils.h"
#include "NormalMode.h"
#include "Keymap.h"
#include "NppVim.h"
#include "Marks.h"
#include "Scintilla.h"
#include "menuCmdID.h"

extern NormalMode *g_normalMode;
extern NppData nppData;

// macOS NPPM_MENUCOMMAND whitelist (NppPluginManager.mm): only these IDM_* are
// honored by the host. Everything else returns 0 (no-op). The Vim ':' commands
// that map outside this set are reachable only through Scintilla or are
// documented as host-limited. See the port notes / README.
//   41001 IDM_FILE_NEW  41002 IDM_FILE_OPEN  41006 IDM_FILE_SAVE
//   41003 IDM_FILE_CLOSE 41004 IDM_FILE_CLOSEALL
static inline void nppMenuCommand(int idm) {
    NppVim_send(nppData._nppHandle, NPPM_MENUCOMMAND, 0, idm);
}

// Sort the current (or whole-doc) line range directly via Scintilla, since the
// host does not expose IDM_EDIT_SORTLINES_* through NPPM_MENUCOMMAND. Mirrors
// Notepad++'s lexicographic / integer ascending+descending line sort over the
// selected lines (or the entire document when there is no multi-line selection).
void NppVimSortLines(HWND h, bool numeric, bool descending);

static void appendNonKeymapHelp(std::string& help);

void CommandMode::enter(char prompt) {
  state.commandMode = true;
  state.commandBuffer.clear();
  state.commandBuffer.push_back(prompt);

  HWND h = Utils::getCurrentScintillaHandle();
  if (h) {
      initSubstitutionIndicators(h);
  }

  updateStatus();
}

void CommandMode::exit() {
  state.commandMode = false;
  
  HWND h = Utils::getCurrentScintillaHandle();
  if (h) {
      clearSubstitutionPreview(h);
  }

  state.commandBuffer.clear();
  lastPreviewBuffer.clear();

  if (state.mode != VISUAL) {
    Utils::clearSearchHighlights(Utils::getCurrentScintillaHandle());
    state.lastSearchMatchCount = -1;

    if (g_normalMode) {
      g_normalMode->enter();
    }
  } else {
    Utils::setStatus(TEXT("-- VISUAL --"));
  }
}

void CommandMode::updateStatus() {
  if (state.commandBuffer.empty()) {
    Utils::setStatus(TEXT(""));
    return;
  }

  std::string display(state.commandBuffer.begin(), state.commandBuffer.end());

  if (state.lastSearchMatchCount >= 0) {
    const int totalWidth = 60;
    int commandLength = static_cast<int>(display.length());

    std::string matchInfo;
    if (state.lastSearchMatchCount > 0) {
      matchInfo = "[" + std::to_string(state.lastSearchMatchCount) + " matches]";
    } else {
      matchInfo = "[Pattern not found]";
    }

    int padding = totalWidth - commandLength - static_cast<int>(matchInfo.length());
    if (padding > 0) {
      display += std::string(padding, ' ');
    }
    display += matchInfo;
  }

  Utils::setStatus(display.c_str());
}

void CommandMode::handleKey(HWND hwndEdit, char c) {
  if (!hwndEdit) return;

  if (c == 13 || c == 10) {
    handleEnter(hwndEdit);
    return;
  }

  if (c == 27) {
    exit();
    return;
  }

  if (c >= 32 && c <= 126) {
    state.commandBuffer.push_back(c);
    updateStatus();

    if (state.commandBuffer[0] == '/' && state.commandBuffer.size() > 1) {
      std::string currentSearch = state.commandBuffer.substr(1);
      Utils::updateSearchHighlight(hwndEdit, currentSearch, false);
    } else if (state.commandBuffer[0] == '?' && state.commandBuffer.size() > 1) {
      std::string currentPattern = state.commandBuffer.substr(1);
      Utils::updateSearchHighlight(hwndEdit, currentPattern, true);
    } else if (state.commandBuffer.size() == 1) {
      Utils::clearSearchHighlights(hwndEdit);
      state.lastSearchMatchCount = -1;
    }

    previewSubstitutionFromBuffer(hwndEdit);
  }
}

void CommandMode::handleBackspace(HWND hwndEdit) {
  if (!hwndEdit) return;

  if (state.commandBuffer.size() > 1) {
    state.commandBuffer.pop_back();
    updateStatus();

    if (state.commandBuffer[0] == '/' && state.commandBuffer.size() > 1) {
      std::string currentSearch = state.commandBuffer.substr(1);
      Utils::updateSearchHighlight(hwndEdit, currentSearch, false);
    } else if (state.commandBuffer[0] == ':' && state.commandBuffer.size() > 3 &&
             state.commandBuffer[1] == 's' && state.commandBuffer[2] == ' ') {
      std::string currentPattern = state.commandBuffer.substr(3);
      Utils::updateSearchHighlight(hwndEdit, currentPattern, true);
    } else if (state.commandBuffer.size() == 1) {
      Utils::clearSearchHighlights(hwndEdit);
      state.lastSearchMatchCount = -1;
    }

    previewSubstitutionFromBuffer(hwndEdit);
  }
  else {
    exit();
  }
}

void CommandMode::handleEnter(HWND hwndEdit) {
  if (!hwndEdit) return;
  handleCommand(hwndEdit);
}

void CommandMode::handleCommand(HWND hwndEdit) {
  if (state.commandBuffer.empty()) {
    exit();
    return;
  }

  const std::string &buf = state.commandBuffer;
  char firstChar = buf[0];

  try {
    if (firstChar == '/') {
      if (buf.size() > 1) {
        handleSearchCommand(hwndEdit, buf.substr(1));
      } else {
        Utils::setStatus(TEXT("No search pattern"));
      }
    } else if (firstChar == '?') {
      if (buf.size() > 1) {
        handleSearchCommand(hwndEdit, buf.substr(1), true);
      } else {
        Utils::setStatus(TEXT("No regex pattern"));
      }
    } else if (firstChar == ':') {
      if (buf.size() > 1) {
        handleColonCommand(hwndEdit, buf.substr(1));
      } else {
        exit();
      }
    } else {
      Utils::setStatus(TEXT("Unknown command type"));
    }
  } catch (const std::exception &e) {
    std::string error = "Command error: " + std::string(e.what());
    Utils::setStatus(std::string(error.begin(), error.end()).c_str());
  }

  state.commandMode = false;
  state.commandBuffer.clear();

  if (state.mode == VISUAL) {
    Utils::setStatus(TEXT("-- VISUAL --"));
  }
}

void CommandMode::handleSearchCommand(HWND hwndEdit, const std::string &searchTerm, bool useRegex) {
  performSearch(hwndEdit, searchTerm, useRegex);
}

void CommandMode::handleColonCommand(HWND hwndEdit, const std::string &cmd) {
  if (cmd.empty()) return;

  if (cmd == "marks" || cmd == "m" || cmd.find("delm") == 0 || cmd.find("dm") == 0) {
    handleMarksCommand(hwndEdit, cmd);
    return;
  }

  bool isNumber = true;
  for (char ch : cmd) {
    if (!std::isdigit(static_cast<unsigned char>(ch))) {
      isNumber = false;
      break;
    }
  }

  if (isNumber) {
    int lineNum = std::stoi(cmd);
    if (lineNum > 0) {
      int lineCount = (int)NppVim_send(hwndEdit, SCI_GETLINECOUNT, 0, 0);
      if (lineNum <= lineCount) {
        NppVim_send(hwndEdit, SCI_GOTOLINE, lineNum - 1, 0);
        NppVim_send(hwndEdit, SCI_SCROLLCARET, 0, 0);
        std::string msg = "Jumped to line " + std::to_string(lineNum);
        Utils::setStatus(msg.c_str());
      } else {
        Utils::setStatus(TEXT("Line number out of range"));
      }
    }
    return;
  }

   if (cmd.find("sort") == 0) {
        // Host has no NPPM path for IDM_EDIT_SORTLINES_*, so sort via Scintilla.
        if (cmd == "sort") {
            NppVimSortLines(hwndEdit, false, false);
            Utils::setStatus(TEXT("Lines sorted"));
        } else if (cmd == "sort!") {
            NppVimSortLines(hwndEdit, false, true);
            Utils::setStatus(TEXT("Lines sorted (descending)"));
        } else if (cmd == "sort n") {
            NppVimSortLines(hwndEdit, true, false);
            Utils::setStatus(TEXT("Lines sorted (numeric)"));
        } else if (cmd == "sort n!") {
            NppVimSortLines(hwndEdit, true, true);
            Utils::setStatus(TEXT("Lines sorted (numeric descending)"));
        } else {
            Utils::setStatus(TEXT("Use: sort, sort!, sort n, sort n!"));
        }
        return;
    }

  if ((cmd.size() >= 2 && cmd[0] == 's' && !std::isalnum(cmd[1])) || 
      (cmd.size() >= 3 && cmd[0] == '%' && cmd[1] == 's' && !std::isalnum(cmd[2])) )
  {
    handleSubstitutionCommand(hwndEdit, cmd);
    return;
  }

  if (cmd == "wrap" || cmd == "wrapmode" || cmd == "wrap on") {
    NppVim_send(hwndEdit, SCI_SETWRAPMODE, SC_WRAP_WORD, 0);
    Utils::setStatus(TEXT("Word wrap enabled"));
    return;
  }
  if (cmd == "nowrap" || cmd == "wrap off") {
      NppVim_send(hwndEdit, SCI_SETWRAPMODE, SC_WRAP_NONE, 0);
      Utils::setStatus(TEXT("Word wrap disabled"));
      return;
  }
  if (cmd == "wrap char") {
      NppVim_send(hwndEdit, SCI_SETWRAPMODE, SC_WRAP_CHAR, 0);
      Utils::setStatus(TEXT("Character wrap enabled"));
      return;
  }
  if (cmd == "wrap whitespace") {
      NppVim_send(hwndEdit, SCI_SETWRAPMODE, SC_WRAP_WHITESPACE, 0);
      Utils::setStatus(TEXT("Whitespace wrap enabled"));
      return;
  }

  if (cmd.rfind("set tw=", 0) == 0) {
    try {
        int width = std::stoi(cmd.substr(7));
        NppVim_send(hwndEdit, SCI_SETEDGECOLUMN, width, 0);
        NppVim_send(hwndEdit, SCI_SETEDGEMODE, EDGE_LINE, 0);
        Utils::setStatus(TEXT("Text width set"));
    } catch (...) {
        Utils::setStatus(TEXT("Invalid text width"));
    }
    return;
  }

  for (char c : cmd) {
    if (!g_commandKeymap->handleKey(hwndEdit, c)) {
        break;
    }
  }
  g_commandKeymap->reset();
  return;

}

auto tutorHandler = [](HWND, int) {
    // Open a fresh document (NPPM_MENUCOMMAND IDM_FILE_NEW is host-supported) and
    // fill it with the tutor text — same UX as the Windows new-tab tutor.
    std::string tutor = Utils::buildTutorText();
    NppVimShowTextInNewDoc(tutor, "-- TUTOR --");
};

auto helpHandler = [](HWND, int) {
    std::string help =
        "NppVim — Command Mode Help\n"
        "=========================\n\n";

    const size_t CMD_COL = 18;

    for (const auto& b : g_commandKeymap->getBindings()) {
        std::string cmd = ":" + b.keys;

        help += cmd;
        if (cmd.size() < CMD_COL)
            help += std::string(CMD_COL - cmd.size(), ' ');

        help += " - ";
        help += b.desc;
        help += "\n";
    }

    appendNonKeymapHelp(help);
    NppVimShowTextInNewDoc(help, "-- HELP --");
};

CommandMode::CommandMode(VimState &state) : state(state)
{
  g_commandKeymap = std::make_unique<Keymap>(state);
  g_commandKeymap->setAllowCount(false);

  g_commandKeymap
    ->set("w", "Save current file", [](HWND, int) {
        NppVim_send(nppData._nppHandle, NPPM_SAVECURRENTFILE, 0, 0);
        Utils::setStatus(TEXT("File saved"));
    })
    .set("e", "Reload current file", [](HWND, int) {
        // No host NPPM path for reload-from-disk; closest reachable behaviour is
        // none, so report it rather than silently doing nothing.
        Utils::setStatus(TEXT(":e reload not available on macOS host"));
    })
    .set("q", "Close current file", [](HWND, int) {
        nppMenuCommand(IDM_FILE_CLOSE);   // 41003 — host-supported
    })
    .set("qa", "Close all files", [](HWND, int) {
        nppMenuCommand(IDM_FILE_CLOSEALL); // 41004 — host-supported
    })
    .set("wq", "Save and close file", [](HWND, int) {
        NppVim_send(nppData._nppHandle, NPPM_SAVECURRENTFILE, 0, 0);
        nppMenuCommand(IDM_FILE_CLOSE);
    })
    .set("wqa", "Save all and close all files", [](HWND, int) {
        // NPPM_SAVEALLFILES is unimplemented on the host; save the current file
        // (best reachable) then close all.
        NppVim_send(nppData._nppHandle, NPPM_SAVECURRENTFILE, 0, 0);
        nppMenuCommand(IDM_FILE_CLOSEALL);
    })
    .set("bn", "Next tab", [](HWND, int) {
        Utils::setStatus(TEXT(":bn tab switch not available on macOS host"));
    })
    .set("bp", "Previous tab", [](HWND, int) {
        Utils::setStatus(TEXT(":bp tab switch not available on macOS host"));
    })
    .set("bd", "Close current tab", [](HWND, int) {
        nppMenuCommand(IDM_FILE_CLOSE);
    })
    .set("sp", "Split window", [](HWND, int) {
        Utils::setStatus(TEXT(":sp split not available on macOS host"));
    })
    .set("vs", "Vertical split", [](HWND, int) {
        Utils::setStatus(TEXT(":vs split not available on macOS host"));
    })
    .set("gh", "Open GitHub", [](HWND, int) {
        NppVimOpenURL("https://github.com/h-jangra/nppvim");
    })
    .set("paypal", "Donate via PayPal", [](HWND, int) {
        NppVimOpenURL("https://paypal.me/h8imansh8u");
    })
    .set("donate", "Donate via PayPal", [](HWND, int) {
        NppVimOpenURL("https://paypal.me/h8imansh8u");
    })
    .set("about", "About NppVim", [](HWND, int) {
        about();
    })
    .set("config", "NppVim Configuration", [](HWND, int) {
        showConfigDialog();
    })
    .set("noh", "Clear search highlight", [](HWND hwnd, int) {
      Utils::clearSearchHighlights(hwnd);
      Utils::setStatus(TEXT("Search highlight cleared"));
    })
    .set("nohl", "Clear search highlight", [](HWND hwnd, int) {
        Utils::clearSearchHighlights(hwnd);
        Utils::setStatus(TEXT("Search highlight cleared"));
    })
    .set("nohlsearch", "Clear search highlight", [](HWND hwnd, int) {
        Utils::clearSearchHighlights(hwnd);
        Utils::setStatus(TEXT("Search highlight cleared"));
    })
    .set("set nu", "Enable line numbers", [](HWND hwnd, int) {
        NppVim_send(hwnd, SCI_SETMARGINWIDTHN, 0, 50);
        Utils::setStatus(TEXT("Line numbers enabled"));
    })
    .set("set number", "Enable line numbers", [](HWND hwnd, int) {
        NppVim_send(hwnd, SCI_SETMARGINWIDTHN, 0, 50);
        Utils::setStatus(TEXT("Line numbers enabled"));
    })
    .set("set nonu", "Disable line numbers", [](HWND hwnd, int) {
        NppVim_send(hwnd, SCI_SETMARGINWIDTHN, 0, 0);
        Utils::setStatus(TEXT("Line numbers disabled"));
    })
    .set("set nonumber", "Disable line numbers", [](HWND hwnd, int) {
        NppVim_send(hwnd, SCI_SETMARGINWIDTHN, 0, 0);
        Utils::setStatus(TEXT("Line numbers disabled"));
    })
    .set("m", "Move line to specific line number", [](HWND h, int c) {
        int currentLine = NppVim_send(h, SCI_LINEFROMPOSITION, Utils::caretPos(h), 0);
        int targetLine = c > 0 ? c - 1 : 0;
        if (targetLine >= 0 && targetLine != currentLine) {
            NppVim_send(h, SCI_MOVESELECTEDLINESUP, currentLine < targetLine ? 0 : 1, 0);
            if (currentLine < targetLine) {
                for (int i = currentLine; i < targetLine; ++i) {
                    NppVim_send(h, SCI_MOVESELECTEDLINESDOWN, 0, 0);
                }
            } else {
                for (int i = currentLine; i > targetLine; --i) {
                    NppVim_send(h, SCI_MOVESELECTEDLINESUP, 0, 0);
                }
            }
            NppVim_send(h, SCI_GOTOLINE, targetLine, 0);
        }
    })
    .set("reg", "Show registers", [this](HWND, int) {
        showRegisters();
    })
    .set("registers", "Show registers", [this](HWND, int) {
        showRegisters();
    })
    .set("di", "Show registers", [this](HWND, int) {
        showRegisters();
    })
    .set("display", "Show registers", [this](HWND, int) {
        showRegisters();
    })
    .set("h",    "Open command help", helpHandler)
    .set("help", "Open command help", helpHandler)
    .set("tutor", "Open tutor", tutorHandler)
    .set("tut",   "Open tutor", tutorHandler)
    .set("t",     "Open tutor", tutorHandler);
}

static void appendNonKeymapHelp(std::string& help) {
    help += "\nOther Commands\n";
    help += "--------------\n";
    help += ":<number>          - Jump to line number\n";
    help += ":q!                - Force close file\n";
    help += ":quit!             - Force close file\n";
    help += ":marks, :m         - Show marks\n";
    help += ":delm, :dm         - Delete marks\n";
    help += ":sort              - Sort lines (A→Z)\n";
    help += ":sort!             - Sort lines (Z→A)\n";
    help += ":sort n            - Numeric sort\n";
    help += ":sort n!           - Numeric sort (desc)\n";
    help += ":s/old/new/        - Substitute\n";
    help += ":set tw=NN         - Set text width\n";
    help += ":wrap              - Enable word wrap\n";
    help += ":nowrap            - Disable wrap\n";
    help += ":wrap char         - Character wrap\n";
    help += ":wrap whitespace   - Whitespace wrap\n";
    help += "/pattern           - Search forward\n";
    help += "?pattern           - Search backward\n";
}

void CommandMode::handleSubstitutionCommand(HWND hwndEdit, const std::string &cmd) {
  clearSubstitutionPreview(hwndEdit);

  std::string command = cmd;
  bool globalReplace = false;
  int startPos = 0;
  int endPos = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);
  int startLine = 0;
  int endLine = (int)NppVim_send(hwndEdit, SCI_GETLINECOUNT, 0, 0) - 1;

  if (command[0] == '%')
  {
    globalReplace = true;
    command = command.substr(1);
  }

  size_t commaPos = command.find(',');
  size_t sPos = command.find('s');

  if (commaPos != std::string::npos && commaPos < sPos)
  {
    std::string range = command.substr(0, sPos);
    command = command.substr(sPos);

    size_t commaPos2 = range.find(',');
    if (commaPos2 != std::string::npos)
    {
      try
      {
        std::string startStr = range.substr(0, commaPos2);
        if (startStr == "." || startStr.empty())
        {
          startLine = (int)NppVim_send(hwndEdit, SCI_LINEFROMPOSITION,
                                        (int)NppVim_send(hwndEdit, SCI_GETCURRENTPOS, 0, 0), 0);
        }
        else if (startStr == "$")
        {
          startLine = (int)NppVim_send(hwndEdit, SCI_GETLINECOUNT, 0, 0) - 1;
        }
        else
        {
          startLine = std::stoi(startStr) - 1;
        }

        std::string endStr = range.substr(commaPos2 + 1);
        if (endStr == "." || endStr.empty())
        {
          endLine = startLine;
        }
        else if (endStr == "$")
        {
          endLine = (int)NppVim_send(hwndEdit, SCI_GETLINECOUNT, 0, 0) - 1;
        }
        else
        {
          endLine = std::stoi(endStr) - 1;
        }

        if (startLine < 0) startLine = 0;
        if (endLine >= (int)NppVim_send(hwndEdit, SCI_GETLINECOUNT, 0, 0))
          endLine = (int)NppVim_send(hwndEdit, SCI_GETLINECOUNT, 0, 0) - 1;
        if (startLine > endLine) std::swap(startLine, endLine);

        startPos = (int)NppVim_send(hwndEdit, SCI_POSITIONFROMLINE, startLine, 0);
        endPos = (int)NppVim_send(hwndEdit, SCI_POSITIONFROMLINE, endLine + 1, 0);
        if (endPos < 0) endPos = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);

        globalReplace = true;
      }
      catch (...)
      {
        Utils::setStatus(TEXT("Invalid range"));
        return;
      }
    }
  }

  if (command.size() < 4 || command[0] != 's')
  {
    Utils::setStatus(TEXT("Invalid substitution command"));
    return;
  }

  char delimiter = command[1];
  size_t patternStart = 2;
  size_t patternEnd = command.find(delimiter, patternStart);

  if (patternEnd == std::string::npos)
  {
    Utils::setStatus(TEXT("Missing pattern delimiter"));
    return;
  }

  std::string pattern = command.substr(patternStart, patternEnd - patternStart);
  if (pattern.empty())
  {
    Utils::setStatus(TEXT("Empty pattern"));
    return;
  }

  size_t replacementStart = patternEnd + 1;
  size_t replacementEnd = command.find(delimiter, replacementStart);

  if (replacementEnd == std::string::npos)
  {
    replacementEnd = command.length();
  }

  std::string replacement = command.substr(replacementStart, replacementEnd - replacementStart);

  bool caseInsensitive = false;
  bool confirmEach = false;
  bool replaceAll = false;
  bool useRegex = true;

  if (replacementEnd < command.length())
  {
    std::string flags = command.substr(replacementEnd + 1);
    for (char flag : flags)
    {
      switch (flag)
      {
        case 'i': caseInsensitive = true; break;
        case 'I': caseInsensitive = true; break;
        case 'c': confirmEach = true; break;
        case 'g': replaceAll = true; break;
        case 'l': useRegex = false; break;
        default: break;
      }
    }
  }

  performSubstitution(hwndEdit, pattern, replacement, useRegex, caseInsensitive,
                     replaceAll, confirmEach, globalReplace, startPos, endPos);
}

void CommandMode::performSubstitution(HWND hwndEdit, const std::string &pattern,
                                     const std::string &replacement, bool useRegex,
                                     bool caseInsensitive, bool replaceAll,
                                     bool confirmEach, bool globalReplace,
                                     int startPos, int endPos)
{
   Utils::beginUndo(hwndEdit);

    if (pattern.empty())
    {
      Utils::setStatus(TEXT("Empty pattern"));
      Utils::endUndo(hwndEdit);
      return;
    }

    int flags = 0;
    if (useRegex) flags |= SCFIND_REGEXP;
    if (!caseInsensitive) flags |= SCFIND_MATCHCASE;

    NppVim_send(hwndEdit, SCI_SETSEARCHFLAGS, flags, 0);

    int originalPos = (int)NppVim_send(hwndEdit, SCI_GETCURRENTPOS, 0, 0);
    int originalAnchor = (int)NppVim_send(hwndEdit, SCI_GETANCHOR, 0, 0);
    int originalLine = (int)NppVim_send(hwndEdit, SCI_LINEFROMPOSITION, originalPos, 0);

    int searchStart;
    int searchEnd;

    if (globalReplace) {
        searchStart = startPos;
        searchEnd = endPos;
    } else {
        int lineStart = (int)NppVim_send(hwndEdit, SCI_POSITIONFROMLINE, originalLine, 0);
        int lineEnd   = (int)NppVim_send(hwndEdit, SCI_GETLINEENDPOSITION, originalLine, 0);
        searchStart = lineStart;
        searchEnd = lineEnd;
    }

    int replacements = 0;
    int skipped = 0;

    NppVim_send(hwndEdit, SCI_SETTARGETSTART, searchStart, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETEND, searchEnd, 0);

    if (confirmEach)
    {
      NppVim_send(hwndEdit, SCI_SETTARGETSTART, searchStart, 0);
      NppVim_send(hwndEdit, SCI_SETTARGETEND, searchEnd, 0);

      while (true)
      {
          int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                        (WPARAM)pattern.length(),
                                        (LPARAM)pattern.c_str());

          if (found == -1)
              break;

          int matchStart = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
          int matchEnd   = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);

          NppVim_send(hwndEdit, SCI_SETSEL, matchStart, matchEnd);
          NppVim_send(hwndEdit, SCI_SCROLLCARET, 0, 0);

          std::string prompt = "Replace with \"" +
                                std::string(replacement.begin(), replacement.end()) +
                                "\"? (y/n/a/q)";
          Utils::setStatus(prompt.c_str());

          char response = (char)Utils::getCharBlocking();

          if (response == 'y' || response == 'Y')
          {
              NppVim_send(hwndEdit,
                  useRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
                  replacement.length(),
                  (LPARAM)replacement.c_str());

              replacements++;

              int diff = (int)replacement.length() - (matchEnd - matchStart);
              searchEnd += diff;
              matchEnd += diff;

              NppVim_send(hwndEdit, SCI_SETTARGETSTART, matchEnd, 0);
              NppVim_send(hwndEdit, SCI_SETTARGETEND, searchEnd, 0);
          }
          else if (response == 'n' || response == 'N')
          {
              skipped++;
              NppVim_send(hwndEdit, SCI_SETTARGETSTART, matchEnd, 0);
              NppVim_send(hwndEdit, SCI_SETTARGETEND, searchEnd, 0);
          }
          else if (response == 'a' || response == 'A')
          {
              NppVim_send(hwndEdit,
                  useRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
                  replacement.length(),
                  (LPARAM)replacement.c_str());

              replacements++;

              int diff = (int)replacement.length() - (matchEnd - matchStart);
              searchEnd += diff;
              matchEnd += diff;

              NppVim_send(hwndEdit, SCI_SETTARGETSTART, matchEnd, 0);
              NppVim_send(hwndEdit, SCI_SETTARGETEND, searchEnd, 0);

              found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                        (WPARAM)pattern.length(), (LPARAM)pattern.c_str());

              while (found != -1)
              {
                matchStart = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
                matchEnd = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);

                NppVim_send(hwndEdit, useRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
                            replacement.length(), (LPARAM)replacement.c_str());
                replacements++;

                int newLength = (int)replacement.length();
                int oldLength = matchEnd - matchStart;
                int lengthDiff = newLength - oldLength;

                searchEnd += lengthDiff;
                matchEnd += lengthDiff;

                NppVim_send(hwndEdit, SCI_SETTARGETSTART, matchEnd, 0);
                NppVim_send(hwndEdit, SCI_SETTARGETEND, searchEnd, 0);

                found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                          (WPARAM)pattern.length(), (LPARAM)pattern.c_str());
              }
              break;
          }
          else if (response == 'q' || response == 'Q')
          {
              break;
          }
      }
    }
    else
    {
      if (replaceAll)
      {
        int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                      (WPARAM)pattern.length(), (LPARAM)pattern.c_str());

        while (found != -1)
        {
          int matchStart = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
          int matchEnd = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);

          NppVim_send(hwndEdit, useRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
                      replacement.length(), (LPARAM)replacement.c_str());
          replacements++;

          int newLength = (int)replacement.length();
          int oldLength = matchEnd - matchStart;
          int lengthDiff = newLength - oldLength;

          searchEnd += lengthDiff;
          matchEnd += lengthDiff;

          NppVim_send(hwndEdit, SCI_SETTARGETSTART, matchEnd, 0);
          NppVim_send(hwndEdit, SCI_SETTARGETEND, searchEnd, 0);

          found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                    (WPARAM)pattern.length(), (LPARAM)pattern.c_str());
        }
      }
      else
      {
        int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                      (WPARAM)pattern.length(), (LPARAM)pattern.c_str());

        if (found != -1)
        {
          NppVim_send(hwndEdit, useRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
                      replacement.length(), (LPARAM)replacement.c_str());
          replacements++;

          int matchEnd = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);
          NppVim_send(hwndEdit, SCI_SETCURRENTPOS, matchEnd, 0);
          NppVim_send(hwndEdit, SCI_SETSEL, matchEnd, matchEnd);
        }
        else
        {
          NppVim_send(hwndEdit, SCI_SETTARGETSTART, 0, 0);
          NppVim_send(hwndEdit, SCI_SETTARGETEND, originalPos, 0);

          found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                    (WPARAM)pattern.length(), (LPARAM)pattern.c_str());

          if (found != -1)
          {
            NppVim_send(hwndEdit, useRegex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
                        replacement.length(), (LPARAM)replacement.c_str());
            replacements++;

            int matchEnd = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);
            NppVim_send(hwndEdit, SCI_SETCURRENTPOS, matchEnd, 0);
            NppVim_send(hwndEdit, SCI_SETSEL, matchEnd, matchEnd);
            Utils::setStatus(TEXT("Search wrapped to top"));
          }
        }
      }
    }

  if (replacements == 0 && !globalReplace)
  {
    NppVim_send(hwndEdit, SCI_SETCURRENTPOS, originalPos, 0);
    NppVim_send(hwndEdit, SCI_SETANCHOR, originalAnchor, 0);
  }

  Utils::endUndo(hwndEdit);

  if (replacements > 0)
  {
    std::string msg = std::to_string(replacements) + " replacement" +
                      (replacements > 1 ? "s" : "") + " made";
    if (skipped > 0)
    {
      msg += ", " + std::to_string(skipped) + " skipped";
    }
    Utils::setStatus(msg.c_str());
  }
  else
  {
    Utils::setStatus(TEXT("Pattern not found"));
  }
}

void CommandMode::performSearch(HWND hwndEdit, const std::string &searchTerm, bool useRegex)
{
  if (searchTerm.empty())
  {
    Utils::setStatus(TEXT("Empty search pattern"));
    return;
  }

  state.lastSearchTerm = searchTerm;
  state.useRegex = useRegex;
  state.lastSearchMatchCount = Utils::countSearchMatches(hwndEdit, searchTerm, useRegex);
  Utils::updateSearchHighlight(hwndEdit, searchTerm, useRegex);

  int docLen = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);
  int flags = (useRegex ? SCFIND_REGEXP : 0);
  NppVim_send(hwndEdit, SCI_SETSEARCHFLAGS, flags, 0);

  int startPos;
  if (state.mode == VISUAL && state.visualSearchAnchor != -1)
  {
    startPos = state.visualSearchAnchor;
  }
  else
  {
    startPos = (int)NppVim_send(hwndEdit, SCI_GETCURRENTPOS, 0, 0);
  }

  NppVim_send(hwndEdit, SCI_SETTARGETSTART, startPos, 0);
  NppVim_send(hwndEdit, SCI_SETTARGETEND, docLen, 0);

  int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                 (WPARAM)searchTerm.length(), (LPARAM)searchTerm.c_str());

  if (found == -1)
  {
    NppVim_send(hwndEdit, SCI_SETTARGETSTART, 0, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETEND, startPos, 0);
    found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                               (WPARAM)searchTerm.length(), (LPARAM)searchTerm.c_str());

    if (found != -1)
    {
      Utils::setStatus(TEXT("Search wrapped to top"));
    }
  }

  if (found != -1)
  {
    int start = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
    int end = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);

    if (state.mode == VISUAL && state.visualSearchAnchor != -1)
    {
      if (state.visualSearchAnchor <= start)
      {
        NppVim_send(hwndEdit, SCI_SETSEL, state.visualSearchAnchor, end);
      }
      else
      {
        NppVim_send(hwndEdit, SCI_SETSEL, end, state.visualSearchAnchor);
      }
    }
    else
    {
      NppVim_send(hwndEdit, SCI_SETSEL, start, end);
    }

    NppVim_send(hwndEdit, SCI_SCROLLCARET, 0, 0);
    Utils::showCurrentMatchPosition(hwndEdit, searchTerm, useRegex);
  }
  else
  {
    Utils::setStatus(TEXT("Pattern not found"));
  }
}

void CommandMode::searchNext(HWND hwndEdit)
{
  if (state.lastSearchTerm.empty())
  {
    Utils::setStatus(TEXT("No previous search"));
    return;
  }

  int docLen = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);
  int startPos = (int)NppVim_send(hwndEdit, SCI_GETSELECTIONEND, 0, 0);

  int flags = (state.useRegex ? SCFIND_REGEXP : 0);
  NppVim_send(hwndEdit, SCI_SETSEARCHFLAGS, flags, 0);

  NppVim_send(hwndEdit, SCI_SETTARGETSTART, startPos, 0);
  NppVim_send(hwndEdit, SCI_SETTARGETEND, docLen, 0);

  int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                 (WPARAM)state.lastSearchTerm.length(), (LPARAM)state.lastSearchTerm.c_str());

  if (found == -1)
  {
    NppVim_send(hwndEdit, SCI_SETTARGETSTART, 0, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETEND, docLen, 0);
    found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                               (WPARAM)state.lastSearchTerm.length(), (LPARAM)state.lastSearchTerm.c_str());

    if (found != -1)
    {
      Utils::setStatus(TEXT("Search wrapped to top"));
    }
  }

  if (found != -1)
  {
    int start = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
    int end = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);
    NppVim_send(hwndEdit, SCI_SETSEL, start, end);
    NppVim_send(hwndEdit, SCI_SCROLLCARET, 0, 0);
    Utils::showCurrentMatchPosition(hwndEdit, state.lastSearchTerm, state.useRegex);
  }
  else
  {
    Utils::setStatus(TEXT("Pattern not found"));
  }
}

void CommandMode::searchPrevious(HWND hwndEdit)
{
  if (state.lastSearchTerm.empty())
  {
    Utils::setStatus(TEXT("No previous search"));
    return;
  }

  int startPos = (int)NppVim_send(hwndEdit, SCI_GETSELECTIONSTART, 0, 0);
  if (startPos > 0) startPos--;

  int flags = (state.useRegex ? SCFIND_REGEXP : 0);
  NppVim_send(hwndEdit, SCI_SETSEARCHFLAGS, flags, 0);

  NppVim_send(hwndEdit, SCI_SETTARGETSTART, 0, 0);
  NppVim_send(hwndEdit, SCI_SETTARGETEND, startPos, 0);

  int found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                 (WPARAM)state.lastSearchTerm.length(), (LPARAM)state.lastSearchTerm.c_str());

  int lastFound = -1;
  int lastStart = -1, lastEnd = -1;

  while (found != -1)
  {
    lastFound = found;
    lastStart = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
    lastEnd = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETSTART, lastEnd, 0);
    found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                               (WPARAM)state.lastSearchTerm.length(), (LPARAM)state.lastSearchTerm.c_str());
  }

  if (lastFound != -1)
  {
    NppVim_send(hwndEdit, SCI_SETSEL, lastStart, lastEnd);
    NppVim_send(hwndEdit, SCI_SCROLLCARET, 0, 0);
    Utils::showCurrentMatchPosition(hwndEdit, state.lastSearchTerm, state.useRegex);
  }
  else
  {
    int docLen = (int)NppVim_send(hwndEdit, SCI_GETTEXTLENGTH, 0, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETSTART, startPos, 0);
    NppVim_send(hwndEdit, SCI_SETTARGETEND, docLen, 0);

    found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                               (WPARAM)state.lastSearchTerm.length(), (LPARAM)state.lastSearchTerm.c_str());

    lastFound = -1;
    while (found != -1)
    {
      lastFound = found;
      lastStart = (int)NppVim_send(hwndEdit, SCI_GETTARGETSTART, 0, 0);
      lastEnd = (int)NppVim_send(hwndEdit, SCI_GETTARGETEND, 0, 0);
      NppVim_send(hwndEdit, SCI_SETTARGETSTART, lastEnd, 0);
      found = (int)NppVim_send(hwndEdit, SCI_SEARCHINTARGET,
                                 (WPARAM)state.lastSearchTerm.length(), (LPARAM)state.lastSearchTerm.c_str());
    }

    if (lastFound != -1)
    {
      NppVim_send(hwndEdit, SCI_SETSEL, lastStart, lastEnd);
      NppVim_send(hwndEdit, SCI_SCROLLCARET, 0, 0);
      Utils::setStatus(TEXT("Search wrapped to bottom"));
      Utils::showCurrentMatchPosition(hwndEdit, state.lastSearchTerm, state.useRegex);
    }
    else
    {
      Utils::setStatus(TEXT("Pattern not found"));
    }
  }
}

void CommandMode::handleMarksCommand(HWND hwndEdit, const std::string &commandLine)
{
  if (commandLine == "marks" || commandLine == "m")
  {
    std::string marksList = Marks::listMarks(hwndEdit);
    NppVimInfoBox("Marks", marksList.c_str());   // Win32 MessageBox → NSAlert
    Utils::setStatus(TEXT("-- Marks list shown --"));
    return;
  }

  if (commandLine.find("delm") == 0 || commandLine.find("dm") == 0)
  {
    size_t startPos = (commandLine.length() > 4 && commandLine[4] == ' ') ? 5 : 4;

    if (commandLine.find("!") != std::string::npos || commandLine.find("a") != std::string::npos)
    {
      Marks::clearAllMarks(hwndEdit);
      Utils::setStatus(TEXT("-- All marks deleted --"));
      return;
    }

    if (startPos < commandLine.length())
    {
      std::string marks = commandLine.substr(startPos);
      int deletedCount = 0;

      for (char ch : marks)
      {
        if (ch != ' ' && Marks::isValidMark(ch))
        {
          Marks::deleteMark(hwndEdit, ch);
          deletedCount++;
        }
      }

      if (deletedCount > 0)
      {
        Utils::setStatus(TEXT("-- Marks deleted --"));
      }
      else
      {
        Utils::setStatus(TEXT("-- No valid marks specified --"));
      }
    }
    else
    {
      Utils::setStatus(TEXT("-- Specify marks to delete --"));
    }
    return;
  }

  Utils::setStatus(TEXT("-- Unknown marks command --"));
}

void CommandMode::initSubstitutionIndicators(HWND h) {
    NppVim_send(h, SCI_INDICSETSTYLE, IND_SUB_MATCH, INDIC_ROUNDBOX);
    NppVim_send(h, SCI_INDICSETFORE, IND_SUB_MATCH, RGB(255, 180, 0));

    NppVim_send(h, SCI_INDICSETSTYLE, IND_SUB_REPL, INDIC_STRAIGHTBOX);
    NppVim_send(h, SCI_INDICSETFORE, IND_SUB_REPL, RGB(0, 200, 120));
}

void CommandMode::clearSubstitutionPreview(HWND h) {
    int firstLine = (int)NppVim_send(h, SCI_GETFIRSTVISIBLELINE, 0, 0);
    int linesOnScreen = (int)NppVim_send(h, SCI_LINESONSCREEN, 0, 0);

    int start = (int)NppVim_send(h, SCI_POSITIONFROMLINE, firstLine, 0);
    int end = (int)NppVim_send(
        h,
        SCI_POSITIONFROMLINE,
        firstLine + linesOnScreen + 1,
        0
    );

    NppVim_send(h, SCI_SETINDICATORCURRENT, IND_SUB_MATCH, 0);
    NppVim_send(h, SCI_INDICATORCLEARRANGE, start, end - start);

    NppVim_send(h, SCI_SETINDICATORCURRENT, IND_SUB_REPL, 0);
    NppVim_send(h, SCI_INDICATORCLEARRANGE, start, end - start);
}

void CommandMode::previewSubstitution(
    HWND h,
    const std::string& pat,
    const std::string& rep,
    bool regex,
    bool global
) {
    clearSubstitutionPreview(h);

    int firstLine = (int)NppVim_send(h, SCI_GETFIRSTVISIBLELINE, 0, 0);
    int linesOnScreen = (int)NppVim_send(h, SCI_LINESONSCREEN, 0, 0);

    int startPos = (int)NppVim_send(h, SCI_POSITIONFROMLINE, firstLine, 0);
    int endPos = (int)NppVim_send(
        h,
        SCI_POSITIONFROMLINE,
        firstLine + linesOnScreen + 1,
        0
    );

    int flags = regex ? SCFIND_REGEXP : 0;
    NppVim_send(h, SCI_SETSEARCHFLAGS, flags, 0);
    NppVim_send(h, SCI_SETTARGETSTART, startPos, 0);
    NppVim_send(h, SCI_SETTARGETEND, endPos, 0);

    bool firstOnly = !global;

    int found = (int)NppVim_send(
        h,
        SCI_SEARCHINTARGET,
        pat.size(),
        (LPARAM)pat.c_str()
    );

    while (found != -1) {
        int s = (int)NppVim_send(h, SCI_GETTARGETSTART, 0, 0);
        int e = (int)NppVim_send(h, SCI_GETTARGETEND, 0, 0);

        NppVim_send(h, SCI_SETINDICATORCURRENT, IND_SUB_MATCH, 0);
        NppVim_send(h, SCI_INDICATORFILLRANGE, s, e - s);

        NppVim_send(h, SCI_SETINDICATORCURRENT, IND_SUB_REPL, 0);
        NppVim_send(h, SCI_INDICATORFILLRANGE, s, e - s);

        if (firstOnly) break;

        NppVim_send(h, SCI_SETTARGETSTART, e, 0);
        found = (int)NppVim_send(
            h,
            SCI_SEARCHINTARGET,
            pat.size(),
            (LPARAM)pat.c_str()
        );
    }
}

bool CommandMode::parseSubstitution(
    const std::string& buf,
    std::string& pat,
    std::string& rep,
    bool& regex,
    bool& global,
    bool& confirm
) {
    if (buf.size() < 4) return false;

    size_t i = 0;
    if (buf[i] == ':') i++;

    if (i >= buf.size() || buf[i] != 's')
        return false;

    if (i + 1 >= buf.size())
        return false;

    char d = buf[i + 1];

    size_t p1 = i + 2;
    size_t p2 = buf.find(d, p1);
    if (p2 == std::string::npos) return false;

    size_t p3 = buf.find(d, p2 + 1);
    if (p3 == std::string::npos) return false;

    pat = buf.substr(p1, p2 - p1);
    rep = buf.substr(p2 + 1, p3 - (p2 + 1));

    if (pat.empty()) return false;

    regex = true;
    global = false;
    confirm = false;

    for (size_t k = p3 + 1; k < buf.size(); k++) {
        if (buf[k] == 'g') global = true;
        else if (buf[k] == 'c') confirm = true;
        else if (buf[k] == 'l') regex = false;
    }

    return true;
}

void CommandMode::previewSubstitutionFromBuffer(HWND h) {
    std::string pat, rep;
    bool regex, global, confirm;

    if (state.commandBuffer == lastPreviewBuffer)
        return;

    lastPreviewBuffer = state.commandBuffer;

    if (!parseSubstitution(state.commandBuffer, pat, rep, regex, global, confirm)) {
        clearSubstitutionPreview(h);
        return;
    }

    if (confirm || pat.size() < 2) {
        clearSubstitutionPreview(h);
        return;
    }

    previewSubstitution(h, pat, rep, regex, global);
}

void CommandMode::showRegisters() {
    std::string registersText;
    registersText += "NppVim Registers\n";
    registersText += "════════════════\n\n";
    
    auto getPreview = [](const std::string& content, int maxLength = 40) -> std::string {
        if (content.empty()) return "";
        
        std::string preview;
        int charCount = 0;
        bool truncated = false;
        
        for (size_t i = 0; i < content.size() && charCount < maxLength; i++) {
            char ch = content[i];
            
            if (ch == '\n' || ch == '\r') {
                if (charCount + 4 < maxLength) {
                    preview += "\\n";
                    charCount += 2;
                } else {
                    truncated = true;
                    break;
                }
                
                // Skip \r\n pairs
                if (ch == '\r' && i + 1 < content.size() && content[i + 1] == '\n') {
                    i++;
                }
            } else if (ch == '\t') {
                if (charCount + 2 < maxLength) {
                    preview += "\\t";
                    charCount += 2;
                } else {
                    truncated = true;
                    break;
                }
            } else if (ch >= 32 && ch <= 126) {
                preview += ch;
                charCount++;
            } else {
                if (charCount + 4 < maxLength) {
                    char hex[5];
                    sprintf_s(hex, "\\x%02X", (unsigned char)ch);
                    preview += hex;
                    charCount += 4;
                } else {
                    truncated = true;
                    break;
                }
            }
        }
        
        if (truncated || charCount >= maxLength) {
            preview += "...";
        }
        
        return preview;
    };
    
    auto countLines = [](const std::string& content) -> int {
        int lines = 0;
        for (char ch : content) {
            if (ch == '\n') lines++;
        }
        return lines + (content.empty() ? 0 : 1);
    };
    
    // Named registers table
    registersText += "Named registers:\n";
    registersText += "Type Name  Preview                              Lines\n";
    registersText += "──── ───── ──────────────────────────────────── ─────\n";
    
    for (char reg = 'a'; reg <= 'z'; reg++) {
        std::string content = Utils::getRegisterContent(reg);
        if (!content.empty()) {
            std::string preview = getPreview(content, 35);
            int lines = countLines(content);
            
            char line[80];
            sprintf_s(line, "char  \"%c   %-35s %4d\n", 
                     reg, preview.c_str(), lines);
            registersText += line;
        }
    }
    
    registersText += "\n";
    
    // Numbered registers table
    registersText += "Numbered registers:\n";
    registersText += "Type Name  Preview                              Lines\n";
    registersText += "──── ───── ──────────────────────────────────── ─────\n";
    
    for (char reg = '0'; reg <= '9'; reg++) {
        std::string content = Utils::getRegisterContent(reg);
        if (!content.empty()) {
            std::string preview = getPreview(content, 35);
            int lines = countLines(content);
            
            char line[80];
            sprintf_s(line, "char  \"%c   %-35s %4d\n", 
                     reg, preview.c_str(), lines);
            registersText += line;
        }
    }
    
    registersText += "\n";
    
    // Special registers
    registersText += "Special registers:\n";
    registersText += "Type Name  Description                         Content\n";
    registersText += "──── ───── ─────────────────────────────────── ───────\n";
    
    // System clipboard (NSPasteboard via NppVim.mm)
    std::string clipboardPreview;
    {
        std::string clip = NppVimClipboardGet();
        if (!clip.empty()) clipboardPreview = getPreview(clip, 30);
    }

    char line[80];
    sprintf_s(line, "sys   \"+   System clipboard               %s\n", 
             clipboardPreview.empty() ? "(empty)" : clipboardPreview.c_str());
    registersText += line;
    
    sprintf_s(line, "sys   \"*   System clipboard (selection)   %s\n", 
             clipboardPreview.empty() ? "(empty)" : clipboardPreview.c_str());
    registersText += line;
    
    // Last search
    if (!state.lastSearchTerm.empty()) {
        sprintf_s(line, "spec  \"/   Last search pattern           \"%s\"\n", 
                 getPreview(state.lastSearchTerm, 30).c_str());
        registersText += line;
    } else {
        registersText += "spec  \"/   Last search pattern           (none)\n";
    }
    
    // Black hole
    std::string blackhole = Utils::getRegisterContent('_');
    if (!blackhole.empty()) {
        sprintf_s(line, "spec  \"_   Black hole register           %s\n", 
                 getPreview(blackhole, 30).c_str());
        registersText += line;
    } else {
        registersText += "spec  \"_   Black hole register           (empty)\n";
    }
    
    // Present in a new read-only document (creates the tab on the main thread,
    // then fills it — avoids the async IDM_FILE_NEW ordering hazard).
    NppVimShowTextInNewDoc(registersText, "-- REGISTERS --");
}