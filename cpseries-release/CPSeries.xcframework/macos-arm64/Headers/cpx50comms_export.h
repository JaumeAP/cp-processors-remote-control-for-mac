/* cpx50comms_export.h -- the export marks for both the C++ API (cpx50comms.hpp)
 * and the C API (cpx50comms_c.h). Both headers include this one, so the policy
 * is written once. A C-compatible header: no C++ constructs.
 *
 * Only the symbols marked CPX50COMMS_API / CPX50COMMS_C_API are exported:
 *   - the obfuscation build (cmake -DCPX50COMMS_OBFUSCATE=ON, -fvisibility=hidden):
 *     visibility("default"), the internals left hidden.
 *   - otherwise empty. See cpp/README.md, "Hiding the client".
 *
 * CPX50COMMS_C_ONLY makes the C API the library's only export. It turns off the
 * C++ marks (CPX50COMMS_API is empty) and leaves the C marks to the rules above.
 */
#ifndef CPX50COMMS_EXPORT_H
#define CPX50COMMS_EXPORT_H

/* The visibility rule is written once, for the C API. */
#if defined(CPX50COMMS_OBFUSCATE) && (defined(__GNUC__) || defined(__clang__))
#  define CPX50COMMS_C_API __attribute__((visibility("default")))
#else
#  define CPX50COMMS_C_API
#endif

/* The C++ API follows the same rule, unless the library's only export is the C
 * API (cpx50comms_c.h): then the C++ marks are empty. */
#if defined(CPX50COMMS_C_ONLY)
#  define CPX50COMMS_API
#else
#  define CPX50COMMS_API CPX50COMMS_C_API
#endif

#endif /* CPX50COMMS_EXPORT_H */
