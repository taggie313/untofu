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

/// Adds the source to the current runloop and runs it. Does not return.
void ff_provider_run(void);

/// Invalidates and releases the runloop source.
void ff_provider_stop(void);

#endif /* CFONTPROVIDER_H */
