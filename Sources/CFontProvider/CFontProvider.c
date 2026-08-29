#include "include/CFontProvider.h"

#include <CoreText/CoreText.h>
#include <libproc.h>
#include <string.h>

// CTFontManagerCreateFontRequestRunLoopSource is deprecated (macOS 10.6-11.0).
// It is, as of macOS 26, still the only sanctioned way to answer a font request
// from another process. See README.md for the verification record.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static CFRunLoopSourceRef gSource = NULL;

bool ff_provider_start(FFRequestHandler handler, void *context) {
    if (handler == NULL) return false;
    if (gSource != NULL) return true;

    gSource = CTFontManagerCreateFontRequestRunLoopSource(
        0, ^CFArrayRef(CFDictionaryRef attributes, pid_t pid) {
            if (attributes == NULL) return NULL;

            CFTypeRef nameValue =
                CFDictionaryGetValue(attributes, CFSTR("NSFontNameAttribute"));
            if (nameValue == NULL || CFGetTypeID(nameValue) != CFStringGetTypeID())
                return NULL;

            char psName[512];
            if (!CFStringGetCString((CFStringRef)nameValue, psName, sizeof psName,
                                    kCFStringEncodingUTF8))
                return NULL;

            char path[4096];
            path[0] = '\0';
            if (handler(psName, pid, context, path, sizeof path) != 1) return NULL;
            if (path[0] == '\0') return NULL;

            CFURLRef url = CFURLCreateFromFileSystemRepresentation(
                NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
            if (url == NULL) return NULL;

            // The array must contain CFURLs, NOT CTFontDescriptors. CoreText walks
            // it in XTIssueSandboxExtensionsForURLs to grant the requesting process
            // read access to each file, which is what lets sandboxed apps such as
            // Keynote use a font they were never granted access to. Handing it
            // descriptors crashes inside libFontRegistry with
            // "-[__NSCFType baseURL]: unrecognized selector".
            const void *values[1] = {url};
            CFArrayRef result =
                CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
            CFRelease(url);
            return result;
        });

    return gSource != NULL;
}

void ff_provider_attach(void) {
    if (gSource == NULL) return;
    // Common modes, not default mode. Once this process owns a window, the main
    // runloop spends time in modal and event-tracking modes, and a source
    // registered only in the default mode does not fire there. That would mean
    // every font request arriving while our own dialog is on screen stalls the
    // asking application until the user clicks something.
    CFRunLoopAddSource(CFRunLoopGetCurrent(), gSource, kCFRunLoopCommonModes);
}

void ff_provider_run(void) {
    ff_provider_attach();
    CFRunLoopRun();
}

void ff_provider_stop(void) {
    if (gSource == NULL) return;
    CFRunLoopSourceInvalidate(gSource);
    CFRelease(gSource);
    gSource = NULL;
}

bool ff_process_path(pid_t pid, char *out, size_t capacity) {
    if (out == NULL || capacity == 0) return false;
    out[0] = '\0';
    if (capacity < PROC_PIDPATHINFO_MAXSIZE) {
        char buffer[PROC_PIDPATHINFO_MAXSIZE];
        if (proc_pidpath(pid, buffer, sizeof buffer) <= 0) return false;
        strlcpy(out, buffer, capacity);
        return out[0] != '\0';
    }
    return proc_pidpath(pid, out, (uint32_t)capacity) > 0;
}

#pragma clang diagnostic pop
