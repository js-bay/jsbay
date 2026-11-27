#ifdef _MSC_VER

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

// clang-format off
#include <windows.h>
#include <delayimp.h>
#include <string.h>
// clang-format on

static FARPROC WINAPI jsbayLoadHostExecutable(unsigned int event, DelayLoadInfo *info) {
    if (event != dliNotePreLoadLibrary || _stricmp(info->szDll, "node.exe") != 0)
        return nullptr;
    return reinterpret_cast<FARPROC>(GetModuleHandleW(nullptr));
}

extern "C" decltype(__pfnDliNotifyHook2) __pfnDliNotifyHook2 = jsbayLoadHostExecutable;

#endif
