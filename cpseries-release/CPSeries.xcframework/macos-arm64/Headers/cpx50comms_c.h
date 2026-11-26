/* cpx50comms_c.h -- the C API of the cpx50comms client.
 *
 * A plain-C face over cpx50comms::Client (cpx50comms.hpp): no C++ type crosses
 * it, no exception escapes it, and the C++ runtime stays inside the library,
 * so a program built with any compiler (MSVC included) can load the library
 * without sharing its standard library. Nothing here is thread-safe on one
 * handle; use one handle per thread, or serialise the calls.
 *
 *     cpx50comms_client* cp = cpx50comms_new("192.168.1.10", 0, "CP750", NULL);
 *     if (cp && cpx50comms_connect(cp)) {
 *         char fader[32];
 *         cpx50comms_set_int(cp, "cp750.sys.mute", 0);   // enqueues, returns at once
 *         cpx50comms_run(cp);                            // sends what is queued
 *         if (cpx50comms_get(cp, "cp750.sys.fader", fader, sizeof fader, 0) >= 0)
 *             puts(fader);                             // blocking query
 *         cpx50comms_disconnect(cp);
 *     }
 *     cpx50comms_free(cp);
 *
 * Return conventions: `int` results that are a length follow snprintf (the
 * length the text needs, excluding the NUL, so a result >= the buffer size
 * means truncation; the buffer is always NUL-terminated when its size is not
 * 0). A timeout of 0 or less means the library default.
 */
#ifndef CPX50COMMS_C_H
#define CPX50COMMS_C_H

#include <stddef.h>

/* Export marks (CPX50COMMS_C_API), shared with cpx50comms.hpp. */
#include "cpx50comms_export.h"

#ifdef __cplusplus
extern "C" {
#endif

/* An open client. Created by cpx50comms_new, released by cpx50comms_free. */
typedef struct cpx50comms_client cpx50comms_client;

/* Link status, the values of cpx50comms_status(). */
enum {
    CPX50COMMS_INITIALIZING = 0,
    CPX50COMMS_OK = 1,
    CPX50COMMS_COMPROMISED = 2,
    CPX50COMMS_MISSING = 3,
    CPX50COMMS_FAULT = 4
};

/* The kinds of a wire-log line, the `kind` of cpx50comms_wire_log_fn. */
enum {
    CPX50COMMS_WIRE_RECEIVED = 0,     /* a line from the processor, LF removed, a CR before it kept */
    CPX50COMMS_WIRE_RECEIVED_CUT = 1, /* bytes from the processor that never got their LF */
    CPX50COMMS_WIRE_SENT = 2          /* a line sent, without the model's terminator */
};

/* Called with every line the processor sends, as it arrives (an `error`, a
 * front-panel line or a stale reply included, whether or not anything reads
 * it as an answer), and with every line sent. `line` is NUL-terminated and
 * `length` long (it can hold a NUL of its own); it is valid only during the
 * call. The call happens inside the library call on the same handle
 * (cpx50comms_disconnect and cpx50comms_free included), so `context` must stay
 * valid until cpx50comms_free returns. */
typedef void (*cpx50comms_wire_log_fn)(void* context, int kind, const char* line, size_t length);

/* Tuning. Start from cpx50comms_options_default() and change what you need. */
typedef struct cpx50comms_options {
    int auto_reconnect;   /* nonzero: re-open a dropped link inline (default 0) */
    int get_retries;      /* extra attempts of a lost or unanswered query (default 2) */
    double watchdog;      /* seconds without success before MISSING (default 3.0) */
    double gap;           /* seconds between sends; < 0: the model's own (default) */
    double reopen_delay;  /* seconds before a link is reopened; < 0: the model's own */
} cpx50comms_options;

CPX50COMMS_C_API void cpx50comms_options_default(cpx50comms_options* options);

/* The model's documented TCP port (61412 CP650, 61408 the others), or -1 for
 * a model name that is not CP650, CP750, CP850, CP950 or CP950A. */
CPX50COMMS_C_API int cpx50comms_default_port(const char* model);

/* A new client for `host`:`port` of `model` ("CP650", "CP750", "CP850",
 * "CP950" or "CP950A"). `port` 0 picks the model's port; `options` NULL gives
 * the defaults. Returns NULL for an unknown model, a NULL argument or no
 * memory. It does not connect. */
CPX50COMMS_C_API cpx50comms_client* cpx50comms_new(const char* host, int port, const char* model,
                                                   const cpx50comms_options* options);
/* Close the link and release the handle. NULL is accepted. */
CPX50COMMS_C_API void cpx50comms_free(cpx50comms_client* client);

/* Send the wire log to `fn` (see cpx50comms_wire_log_fn); NULL turns it off. */
CPX50COMMS_C_API void cpx50comms_set_wire_log(cpx50comms_client* client, cpx50comms_wire_log_fn fn, void* context);

/* 1 when the link is up, 0 when it could not be opened. */
CPX50COMMS_C_API int cpx50comms_connect(cpx50comms_client* client);
CPX50COMMS_C_API void cpx50comms_disconnect(cpx50comms_client* client);
CPX50COMMS_C_API int cpx50comms_reconnect(cpx50comms_client* client);

/* Enqueue a SET (coalesced with a queued SET of the same param) and return at
 * once. 1: queued; 0: the link is down and auto_reconnect is off; -1: the
 * param or value cannot be framed (a CR or LF, or not ASCII), or an argument
 * is NULL: see cpx50comms_last_error(). The value is written as the Python and
 * Lua clients write it. */
CPX50COMMS_C_API int cpx50comms_set_int(cpx50comms_client* client, const char* param, long long value);
CPX50COMMS_C_API int cpx50comms_set_double(cpx50comms_client* client, const char* param, double value);
CPX50COMMS_C_API int cpx50comms_set_bool(cpx50comms_client* client, const char* param, int value);
CPX50COMMS_C_API int cpx50comms_set_text(cpx50comms_client* client, const char* param, const char* value);

/* Send every queued SET, one in flight; stops when the link is down. */
CPX50COMMS_C_API void cpx50comms_run(cpx50comms_client* client);

/* Query `param` and wait for its answer. Copies the value into `out` and
 * returns its length; -1 when there is no value (timeout, `error`, lost
 * link), with each attempt's line and what came back in
 * cpx50comms_last_error(); -2 for a NULL argument or an unframeable param.
 * On the CP650 the query is `key=?` and nothing else: the `key?` fallback was
 * removed (the manual's form is the one a real unit answers, see
 * docs/field-logs/cp650-qsys-plugin-capture). */
CPX50COMMS_C_API int cpx50comms_get(cpx50comms_client* client, const char* param, char* out, size_t out_size,
                                    double timeout);

/* The last value the client recorded for `param` (from a query or a SET
 * reply), without touching the network. The name is looked up as given.
 * Length as cpx50comms_get(), or -1 when there is none. */
CPX50COMMS_C_API int cpx50comms_state(const cpx50comms_client* client, const char* param, char* out,
                                      size_t out_size);

/* One of the CPX50COMMS_* status values, and its name ("OK", "MISSING", ...). */
CPX50COMMS_C_API int cpx50comms_status(const cpx50comms_client* client);
CPX50COMMS_C_API const char* cpx50comms_status_name(int status);

/* SETs waiting for cpx50comms_run(). */
CPX50COMMS_C_API size_t cpx50comms_queued(const cpx50comms_client* client);

/* The text of the last error on this handle. Every call that goes through the
 * client (set, get, connect, run and the like) clears it first, so it reads ""
 * after one that succeeded. The query functions (state, status, queued,
 * set_wire_log) leave it unchanged. Valid until the next call on the handle. */
CPX50COMMS_C_API const char* cpx50comms_last_error(const cpx50comms_client* client);

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* CPX50COMMS_C_H */
