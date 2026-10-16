#include "OpenCineAppleObjC.h"

#if defined(__OBJC__) && __has_include(<VideoToolbox/VTFrameProcessor.h>) && __has_include(<Metal/Metal.h>)
#import <VideoToolbox/VideoToolbox.h>

NSString *_Nullable OCFrameProcessorEncode(id processor, id<MTLCommandBuffer> commandBuffer, id parameters) {
    @try {
        [processor processWithCommandBuffer:commandBuffer parameters:parameters];
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"no reason"];
    }
}
#endif
