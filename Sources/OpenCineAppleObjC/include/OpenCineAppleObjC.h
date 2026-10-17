// Objective-C calls that Swift cannot make safely. Swift cannot catch an NSException, so a
// framework method documented to raise one is called here, inside @try, with no Swift frame
// between the raise and the catch. Empty where the frameworks do not exist.
#ifndef OPENCINE_APPLE_OBJC_H
#define OPENCINE_APPLE_OBJC_H

#if defined(__OBJC__) && __has_include(<VideoToolbox/VTFrameProcessor.h>) && __has_include(<Metal/Metal.h>)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Calls `-[processor processWithCommandBuffer:parameters:]` and returns nil when it returns, or
/// "name: reason" of the exception it raised. `processor` is a `VTFrameProcessor` (or any object
/// with that method); `parameters` conforms to `VTFrameProcessorParameters`. VideoToolbox raises
/// NSInvalidArgumentException from inside this call when a frame it expects is missing
/// (OPENPOCKETCINE-IOS-3M, -3W); a raise is a refused frame, not a reason to end the app.
NSString *_Nullable OCFrameProcessorEncode(id processor, id<MTLCommandBuffer> commandBuffer, id parameters)
    NS_SWIFT_NAME(frameProcessorEncode(_:commandBuffer:parameters:));

NS_ASSUME_NONNULL_END
#endif

#endif
