// cpp_client_example.cpp
//
// Calls PineLib (built with either Delphi or Free Pascal - see
// demo/PineLib.dpr) from C++, using dynamic loading (LoadLibrary/dlopen)
// rather than static linking against an import library. This works
// regardless of which compiler built the DLL and needs no .lib/.def file
// on the C++ side at all - just the .dll/.so itself, next to this
// executable (or anywhere your loader searches).
//
// Build (MSVC):   cl /EHsc cpp_client_example.cpp
// Build (MinGW):  g++ -o cpp_client_example cpp_client_example.cpp
// Build (Linux):  g++ -o cpp_client_example cpp_client_example.cpp -ldl
//
// Run with PineLib.dll (Windows) or libPineLib.so (Linux - pass
// "./libPineLib.so" or set LD_LIBRARY_PATH) in the working directory.

#include <cstdio>
#include <cstring>
#include <string>

#if defined(_WIN32)
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  typedef HMODULE PineHandle;
  static const char* kLibraryPath = "PineLib.dll";
#else
  #include <dlfcn.h>
  typedef void* PineHandle;
  static const char* kLibraryPath = "./libPineLib.so";
#endif

// The library's three exports - see src/Pine.DllApi.pas for the full
// contract (UTF-8 C strings in and out, cdecl, free every returned
// pointer with PineFreeString).
typedef char* (*PineRunJsonFn)(const char* script, const char* candlesJson,
                                const char* settingsJson);
typedef void  (*PineFreeStringFn)(char* str);
typedef char* (*PineVersionFn)();

static PineHandle        g_handle = nullptr;
static PineRunJsonFn     PineRunJson = nullptr;
static PineFreeStringFn  PineFreeString = nullptr;
static PineVersionFn     PineVersion = nullptr;

static void* LoadSymbol(PineHandle handle, const char* name) {
#if defined(_WIN32)
  return reinterpret_cast<void*>(GetProcAddress(handle, name));
#else
  return dlsym(handle, name);
#endif
}

static bool LoadPineLib(const char* path) {
#if defined(_WIN32)
  g_handle = LoadLibraryA(path);
#else
  g_handle = dlopen(path, RTLD_NOW);
#endif
  if (!g_handle) {
    return false;
  }
  PineRunJson = reinterpret_cast<PineRunJsonFn>(LoadSymbol(g_handle, "PineRunJson"));
  PineFreeString = reinterpret_cast<PineFreeStringFn>(LoadSymbol(g_handle, "PineFreeString"));
  PineVersion = reinterpret_cast<PineVersionFn>(LoadSymbol(g_handle, "PineVersion"));
  return PineRunJson && PineFreeString && PineVersion;
}

// Copies the UTF-8 C string the library returned into a std::string, then
// releases the library's own copy via PineFreeString. Never call
// free()/delete on a pointer PineRunJson or PineVersion returned - it was
// allocated by the library's own heap, not this program's.
static std::string Consume(char* ptr) {
  if (!ptr) {
    return "";
  }
  std::string result(ptr);
  PineFreeString(ptr);
  return result;
}

int main() {
  if (!LoadPineLib(kLibraryPath)) {
    std::fprintf(stderr, "Could not load %s or find its exports\n", kLibraryPath);
    return 1;
  }

  std::printf("Library version: %s\n\n", Consume(PineVersion()).c_str());

  const char* script =
      "//@version=5\n"
      "indicator(\"C++ client example\")\n"
      "plot(close, \"Close\")\n"
      "plot(ta.sma(close, 10), \"SMA 10\")\n";
  const char* settings = "{\"syntheticBars\": 30, \"pretty\": true}";

  std::string result = Consume(PineRunJson(script, "[]", settings));
  std::printf("Result JSON:\n%s\n", result.c_str());
  return 0;
}
