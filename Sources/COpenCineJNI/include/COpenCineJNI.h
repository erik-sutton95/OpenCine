// Exposes the Android NDK's JNI interface to Swift. On Darwin there is no
// <jni.h> in the search path, so the module is deliberately empty there;
// the Swift code that uses it is `#if os(Android)`-gated as well.
#ifndef OPENCINE_COPENCINEJNI_H
#define OPENCINE_COPENCINEJNI_H

#ifdef __ANDROID__
#include <jni.h>
#endif

#endif /* OPENCINE_COPENCINEJNI_H */
