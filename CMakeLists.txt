cmake_minimum_required(VERSION 3.20)
project(NppVim VERSION 1.13.3 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Host plugin interface + Scintilla (read-only; NO host changes)
set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")
set(SCINTILLA_INCLUDE  "${NPP_MACOS_DIR}/scintilla/include")

# The Vim engine (ported ~verbatim) + the macOS platform layer (NppVim.mm).
set(SOURCES
    src/NppVim.mm
    src/Keymap.mm
    src/Motion.mm
    src/NormalMode.mm
    src/VisualMode.mm
    src/CommandMode.mm
    src/TextObject.mm
    src/Marks.mm
    src/Utils.mm
)

add_library(NppVim SHARED ${SOURCES})
target_include_directories(NppVim PRIVATE
    ${NPP_PLUGIN_INCLUDE} ${SCINTILLA_INCLUDE} "${CMAKE_SOURCE_DIR}/src")
target_link_libraries(NppVim PRIVATE "-framework Cocoa")
target_compile_options(NppVim PRIVATE
    -Wall -Wno-unused-parameter -Wno-unused-variable
    -Wno-unused-lambda-capture -Wno-unused-function -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)

# CRITICAL: the host loads plugins as plugins/<Folder>/<Folder>.dylib. The folder
# is NppVim.macos, so the dylib MUST be named NppVim.dylib (no lib prefix).
set_target_properties(NppVim PROPERTIES PREFIX "" SUFFIX ".dylib" OUTPUT_NAME "NppVim")
target_link_options(NppVim PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

# Install / stage (folder name = dylib base name, no .macos suffix).
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins-new/NppVim")
install(TARGETS NppVim DESTINATION "${PLUGIN_INSTALL_DIR}")
