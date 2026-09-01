/* mayhem/lsan_off.c — disable LeakSanitizer at BUILD time for the fuzz binary.
 *
 * `-Zsanitizer=address` always bundles LSan into ASan, with no flag that keeps ASan's
 * memory-corruption checks while dropping only leak detection. ASan calls this weak hook
 * at startup; a strong definition linked into the binary wins. mayhem/build.sh compiles
 * this and prepends the object to the fuzz link through a -Clinker wrapper. The KAT probe
 * and the test-suite builds do not get it.
 */
int __lsan_is_turned_off(void) { return 1; }
