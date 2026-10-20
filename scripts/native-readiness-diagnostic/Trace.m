#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <time.h>
#import <stdatomic.h>
#import <unistd.h>
static _Atomic unsigned long serial=0;
static void event(const char *kind, unsigned long job, const char *label, long value) {
 struct timespec ts;clock_gettime(CLOCK_MONOTONIC_RAW,&ts);uint64_t tid=0;pthread_threadid_np(NULL,&tid);
 char out[600];int n=snprintf(out,sizeof(out),"PHASE ns=%llu tid=%llu event=%s job=%lu q=%s value=%ld\n",(unsigned long long)ts.tv_sec*1000000000ULL+ts.tv_nsec,(unsigned long long)tid,kind,job,label?label:"",value);
 if(n>0)write(STDERR_FILENO,out,MIN((size_t)n,sizeof(out)-1));
}
static BOOL selected(const char *q) {return q&&(strstr(q,"opencine.test.still-")||strcmp(q,"opencine.monitor-assist")==0);}
static void phase_async(dispatch_queue_t q,dispatch_block_t work) {
 const char *label=dispatch_queue_get_label(q);
 if(!selected(label)){dispatch_async(q,work);return;}
 unsigned long job=atomic_fetch_add(&serial,1)+1;NSString *name=[NSString stringWithUTF8String:label];
 event("enqueue",job,label,0);
 dispatch_async(q,^{event("queue_begin",job,name.UTF8String,0);work();event("queue_end",job,name.UTF8String,0);});
}
static id<MTLDevice> phase_device(void) {
 event("metal_device_begin",0,dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL),0);
 id<MTLDevice> device=MTLCreateSystemDefaultDevice();
 event("metal_device_end",0,dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL),device!=nil);
 return device;
}
#define INTERPOSE(replacement,original) __attribute__((used)) static struct {const void *new_fn;const void *old_fn;} bind_##original __attribute__((section("__DATA,__interpose")))={(const void *)&replacement,(const void *)&original};
INTERPOSE(phase_async,dispatch_async)
INTERPOSE(phase_device,MTLCreateSystemDefaultDevice)
static void (*render_original)(id,SEL,CIImage *,CVPixelBufferRef,CGRect,CGColorSpaceRef);
static void phase_render(id self,SEL sel,CIImage *image,CVPixelBufferRef buffer,CGRect bounds,CGColorSpaceRef cs) {
 const char *q=dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL);event("native_render_begin",0,q,(long)CVPixelBufferGetWidth(buffer));
 render_original(self,sel,image,buffer,bounds,cs);event("native_render_end",0,q,0);
}
static void (*fulfill_original)(id,SEL);
static void phase_fulfill(XCTestExpectation *self,SEL sel) {
 if([self.expectationDescription containsString:@"still samples and deferred drain finished"]) event("barrier_fulfill",0,dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL),0);
 fulfill_original(self,sel);
}
static XCTWaiterResult (*wait_original)(id,SEL,NSArray *,NSTimeInterval,BOOL);
static XCTWaiterResult phase_wait(id self,SEL sel,NSArray *expectations,NSTimeInterval timeout,BOOL order) {
 BOOL ours=NO;for(XCTestExpectation *e in expectations) if([e.expectationDescription containsString:@"still samples and deferred drain finished"])ours=YES;
 if(ours)event("wait_begin",0,dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL),(long)(timeout*1000000));
 XCTWaiterResult result=wait_original(self,sel,expectations,timeout,order);
 if(ours)event("wait_end",0,dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL),(long)result);return result;
}
__attribute__((constructor))static void begin(void) {
 event("probe_loaded",0,"",getpid());
 Method r=class_getInstanceMethod(CIContext.class,@selector(render:toCVPixelBuffer:bounds:colorSpace:));
 if(r)render_original=(void *)method_setImplementation(r,(IMP)phase_render);
 Method f=class_getInstanceMethod(XCTestExpectation.class,@selector(fulfill));
 if(f)fulfill_original=(void *)method_setImplementation(f,(IMP)phase_fulfill);
 Method w=class_getInstanceMethod(XCTWaiter.class,@selector(waitForExpectations:timeout:enforceOrder:));
 if(w)wait_original=(void *)method_setImplementation(w,(IMP)phase_wait);
 event("hooks_ready",0,"",(r?1:0)+(f?2:0)+(w?4:0));
}
