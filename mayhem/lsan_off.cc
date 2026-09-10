// mayhem/lsan_off.cc — build-time LeakSanitizer off-switch (SPEC.md §6.2 item 15, fleet policy).
//
// `-fsanitize=address` always bundles LeakSanitizer in; there is no flag to keep ASan while
// dropping just leak detection. Leaks are not the bug class this fleet fuzzes for, so every
// ASan-built binary (every libFuzzer target and its -standalone reproducer) links this
// strong definition of the sanitizer runtime's weak-interface hook: the runtime calls it at
// exit and skips the leak check. ASan's memory-corruption checks and UBSan stay fully active.
// Compiled by mayhem/build.sh with $SANITIZER_FLAGS $DEBUG_FLAGS and appended to every
// sanitized link line. This is the ONLY sanctioned way to turn LSan off: never a runtime
// disable/enable wrap, never a compiled-in sanitizer default-options override, never a
// Mayhemfile ASAN_OPTIONS line (Mayhem alone owns the runtime option set).
extern "C" int __lsan_is_turned_off(void) { return 1; }
