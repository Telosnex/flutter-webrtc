#import "LocalPcmPlayoutController.h"
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>

@interface LocalPcmPlayoutController ()
@property(atomic, readwrite) BOOL active;
@end

@implementation LocalPcmPlayoutController {
  RTCPeerConnectionFactory *_factory;
  dispatch_queue_t _queue;
  int64_t _generation;
  BOOL _closed;
}
+ (BOOL)isSupported {
#ifdef RTC_PCM_PLAYOUT_V1
  return YES;
#else
  return NO;
#endif
}
- (instancetype)initWithFactory:(RTCPeerConnectionFactory *)factory {
  if ((self = [super init])) {
    _factory = factory;
    _queue = dispatch_queue_create("flutter.webrtc.pcm.playout", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}
static int64_t PcmInteger(id value) {
  if (![value isKindOfClass:[NSNumber class]] ||
      CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
      strchr("cCsSiIlLqQ", [value objCType][0]) == NULL) return -1;
  return [value longLongValue];
}
- (void)perform:(NSString *)method arguments:(id)arguments
     completion:(void (^)(NSDictionary *, NSString *))completion {
  dispatch_async(_queue, ^{
    NSDictionary *state = nil;
    NSString *error = nil;
#ifdef RTC_PCM_PLAYOUT_V1
    @synchronized (self) { if (self->_closed) error = @"PCM controller disposed"; }
    if (!error) {
      int code = 0;
      if ([method isEqualToString:@"pcmPlayoutStart"]) {
        if (self->_generation) error = @"PCM output already owned";
        else {
          self->_generation = [self->_factory startPcmPlayout];
          if (self->_generation <= 0) { self->_generation = 0; error = @"Could not start shared output"; }
          else self.active = YES;
        }
      } else if (![arguments isKindOfClass:[NSDictionary class]]) error = @"Expected arguments map";
      else {
        int64_t generation = PcmInteger(arguments[@"generation"]);
        int64_t epoch = PcmInteger(arguments[@"epoch"]);
        if (generation <= 0 || generation != self->_generation) error = @"Stale PCM generation";
        else if ([method isEqualToString:@"pcmPlayoutWrite"]) {
          id pcm = arguments[@"pcm"];
          if (![pcm isKindOfClass:[NSData class]]) error = @"Expected PCM16LE bytes";
          else code = [self->_factory writePcmPlayout:pcm generation:generation epoch:epoch];
        } else if ([method isEqualToString:@"pcmPlayoutClear"]) {
          code = [self->_factory clearPcmPlayout:generation epoch:epoch];
        } else if ([method isEqualToString:@"pcmPlayoutStop"]) {
          code = [self->_factory stopPcmPlayout:generation];
          if (code == 0) { self->_generation = 0; self.active = NO; }
        } else if (![method isEqualToString:@"pcmPlayoutState"]) error = @"Unknown PCM operation";
      }
      state = [self->_factory pcmPlayoutState];
      if (code != 0) error = [NSString stringWithFormat:@"PCM operation rejected (%d)", code];
    }
#else
    error = @"PCM output requires matching WebRTC SDK";
#endif
    dispatch_async(dispatch_get_main_queue(), ^{ completion(state, error); });
  });
}
- (void)shutdown {
  @synchronized (self) { _closed = YES; }
  dispatch_async(_queue, ^{
#ifdef RTC_PCM_PLAYOUT_V1
    if (self->_generation) {
      // Native stop quiesces even on error. Factory destruction forcibly
      // detaches the silent source; it cannot outlive its mixer callbacks.
      if ([self->_factory stopPcmPlayout:self->_generation] == 0) { self->_generation = 0; self.active = NO; }
    }
#endif
  });
}
@end
