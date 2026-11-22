/* cpseries_c.h -- the C API of the cpseries client.
 *
 * A plain-C face over cpseries::Client (cpseries.hpp): no C++ type crosses
 * it, no exception escapes it, and the C++ runtime stays inside the library,
 * so a program built with any compiler (MSVC included) can load the library
 * without sharing its standard library. Nothing here is thread-safe on one
 * handle; use one handle per thread, or serialise the calls.
 *
 *     cpseries_client* cp = cpseries_new("192.168.1.10", 0, "CP750", NULL);
 *     if (cp && cpseries_connect(cp)) {
 *         char fader[32];
 *         cpseries_set_int(cp, "cp750.sys.mute", 0);   // enqueues, returns at once
 *         cpseries_run(cp);                            // sends what is queued
 *         if (cpseries_get(cp, "cp750.sys.fader", fader, sizeof fader, 0) >= 0)
 *             puts(fader);                             // blocking query
 *         cpseries_disconnect(cp);
 *     }
 *     cpseries_free(cp);
 *
 * Return conventions: `int` results that are a length follow snprintf (the
 * length the text needs, excluding the NUL, so a result >= the buffer size
 * means truncation; the buffer is always NUL-terminated when its size is not
 * 0). A timeout of 0 or less means the library default.
 */
#ifndef CPSERIES_C_H
#define CPSERIES_C_H

#include <stddef.h>

/* Export marks, as in cpseries.hpp: a Windows DLL (-DCPSERIES_DLL) exports on
 * -DCPSERIES_BUILD and imports otherwise; an obfuscated build
 * (-DCPSERIES_OBFUSCATE with -fvisibility=hidden) keeps these names visible. */
#if defined(_WIN32) && defined(CPSERIES_DLL)
#  if defined(CPSERIES_BUILD)
#    define CPSERIES_C_API __declspec(dllexport)
#  else
#    define CPSERIES_C_API __declspec(dllimport)
#  endif
#elif defined(CPSERIES_OBFUSCATE) && (defined(__GNUC__) || defined(__clang__))
#  define CPSERIES_C_API __attribute__((visibility("default")))
#else
#  define CPSERIES_C_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* An open client. Created by cpseries_new, released by cpseries_free. */
typedef struct cpseries_client cpseries_client;

/* Link status, the values of cpseries_status(). */
enum {
    CPSERIES_INITIALIZING = 0,
    CPSERIES_OK = 1,
    CPSERIES_COMPROMISED = 2,
    CPSERIES_MISSING = 3,
    CPSERIES_FAULT = 4
};

/* Tuning. Start from cpseries_options_default() and change what you need. */
typedef struct cpseries_options {
    int auto_reconnect;   /* nonzero: re-open a dropped link inline (default 0) */
    int get_retries;      /* extra attempts of a lost or unanswered query (default 2) */
    double watchdog;      /* seconds without success before MISSING (default 3.0) */
    double gap;           /* seconds between sends; < 0: the model's own (default) */
    double reopen_delay;  /* seconds before a link is reopened; < 0: the model's own */
} cpseries_options;

CPSERIES_C_API void cpseries_options_default(cpseries_options* options);

/* The model's documented TCP port (61412 CP650, 61408 the others), or -1 for
 * a model name that is not CP650, CP750, CP850, CP950 or CP950A. */
CPSERIES_C_API int cpseries_default_port(const char* model);

/* A new client for `host`:`port` of `model` ("CP650", "CP750", "CP850",
 * "CP950" or "CP950A"). `port` 0 picks the model's port; `options` NULL gives
 * the defaults. Returns NULL for an unknown model, a NULL argument or no
 * memory. It does not connect. */
CPSERIES_C_API cpseries_client* cpseries_new(const char* host, int port, const char* model,
                                             const cpseries_options* options);
/* Close the link and release the handle. NULL is accepted. */
CPSERIES_C_API void cpseries_free(cpseries_client* client);

/* 1 when the link is up, 0 when it could not be opened. */
CPSERIES_C_API int cpseries_connect(cpseries_client* client);
CPSERIES_C_API void cpseries_disconnect(cpseries_client* client);
CPSERIES_C_API int cpseries_reconnect(cpseries_client* client);

/* Enqueue a SET (coalesced with a queued SET of the same param) and return at
 * once. 1: queued; 0: the link is down and auto_reconnect is off; -1: the
 * param or value cannot be framed (a CR or LF, or not ASCII), or an argument
 * is NULL: see cpseries_last_error(). The value is written as the Python and
 * Lua clients write it. */
CPSERIES_C_API int cpseries_set_int(cpseries_client* client, const char* param, long long value);
CPSERIES_C_API int cpseries_set_double(cpseries_client* client, const char* param, double value);
CPSERIES_C_API int cpseries_set_bool(cpseries_client* client, const char* param, int value);
CPSERIES_C_API int cpseries_set_text(cpseries_client* client, const char* param, const char* value);

/* Send every queued SET, one in flight; stops when the link is down. */
CPSERIES_C_API void cpseries_run(cpseries_client* client);

/* Query `param` and wait for its answer. Copies the value into `out` and
 * returns its length; -1 when there is no value (timeout, `error`, lost
 * link); -2 for a NULL argument or an unframeable param. */
CPSERIES_C_API int cpseries_get(cpseries_client* client, const char* param, char* out, size_t out_size,
                                double timeout);

/* The last value the client recorded for `param` (from a query or a SET
 * reply), without touching the network. The name is looked up as given.
 * Length as cpseries_get(), or -1 when there is none. */
CPSERIES_C_API int cpseries_state(const cpseries_client* client, const char* param, char* out,
                                  size_t out_size);

/* One of the CPSERIES_* status values, and its name ("OK", "MISSING", ...). */
CPSERIES_C_API int cpseries_status(const cpseries_client* client);
CPSERIES_C_API const char* cpseries_status_name(int status);

/* SETs waiting for cpseries_run(). */
CPSERIES_C_API size_t cpseries_queued(const cpseries_client* client);

/* The text of the last error on this handle, or "" when the last call
 * succeeded. Valid until the next call on the handle. */
CPSERIES_C_API const char* cpseries_last_error(const cpseries_client* client);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* CPSERIES_C_H */
