#ifndef CFONTPROVIDER_H
#define CFONTPROVIDER_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <sys/types.h>

/// Invoked when some process asks CoreText for a font it cannot resolve.
///
/// This runs on the provider's runloop and blocks the requesting application's
/// text layout for its entire duration. It must return in microseconds: look
/// things up in memory, never touch the network or a slow disk.
///
/// Write an absolute path to a font file into `outPath` and return 1 to satisfy
/// the request. Return 0 to decline, which leaves the requesting app to do
/// whatever it would normally do (substitute a fallback, show a dialog).
typedef int (*FFRequestHandler)(const char *psName,
                                pid_t requestingPID,
                                void *context,
                                char *outPath,
                                size_t outPathCapacity);

/// Registers the CoreText font-request hook.
///
/// Returns false if the hook is unavailable — which is the expected outcome once
/// Apple follows through on the deprecation notice attached to
/// CTFontManagerCreateFontRequestRunLoopSource (deprecated since macOS 11,
/// annotated "will be removed in a future release"). Callers must treat false as
/// a normal, survivable condition rather than an error.
bool ff_provider_start(FFRequestHandler handler, void *context);

/// Adds the source to the current runloop, in the common modes, and returns.
///
/// Separate from ff_provider_run so a caller that drives the main runloop itself
/// — an AppKit process running NSApplication — can still receive font requests.
void ff_provider_attach(void);

/// Adds the source to the current runloop and runs it. Does not return.
void ff_provider_run(void);

/// Invalidates and releases the runloop source.
void ff_provider_stop(void);

/// Absolute executable path of a process, written into `out`.
///
/// Backed by proc_pidpath, which is a syscall rather than a fork, so it is
/// cheap enough to call from the request handler. Spawning `ps` there would
/// stall the requesting application's text layout for milliseconds.
///
/// Returns true on success. Fails for processes that have exited or that this
/// user may not inspect.
bool ff_process_path(pid_t pid, char *out, size_t capacity);

#endif /* CFONTPROVIDER_H */
