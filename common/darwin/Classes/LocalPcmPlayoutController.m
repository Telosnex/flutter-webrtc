#import "LocalPcmPlayoutController.h"
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>

@interface LocalPcmPlayoutController ()
@property(atomic, readwrite) BOOL active;
@end

@implementation LocalPcmPlayoutController {
  RTCPeerConnectionFactory *_factory;
  dispatch_queue_t _queue;
  NSMutableSet<NSNumber *> *_generations;
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
    _generations = [NSMutableSet new];
    _queue = dispatch_queue_create("flutter.webrtc.pcm.playout", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}
+ (NSDictionary *)capabilities {
  NSMutableDictionary *caps = [@{ @"version": @([self isSupported] ? 1 : 0),
    @"sampleRate": @24000, @"channels": @1, @"requiresAnchor": @NO } mutableCopy];
#ifdef RTC_PCM_PLAYOUT_SHARED
  caps[@"maxSharedSources"] = @2;
  caps[@"supportedFormats"] = @[@{ @"sampleRate": @24000, @"channels": @1 },
                                 @{ @"sampleRate": @48000, @"channels": @2 }];
#endif
  return caps;
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
      int64_t owner = 0;
      if ([method isEqualToString:@"pcmPlayoutStart"]) {
        NSDictionary *args = [arguments isKindOfClass:[NSDictionary class]] ? arguments : @{};
        BOOL format = args[@"sampleRate"] || args[@"channels"];
        int64_t rate = format ? PcmInteger(args[@"sampleRate"]) : 24000;
        int64_t channels = format ? PcmInteger(args[@"channels"]) : 1;
        id mode = args[@"ownershipMode"] ?: @"exclusive";
        if (!((rate == 24000 && channels == 1) || (rate == 48000 && channels == 2)) ||
            !([mode isEqual:@"exclusive"] || [mode isEqual:@"shared"])) error = @"Unsupported PCM format or mode";
        if (!error) {
#ifdef RTC_PCM_PLAYOUT_SHARED
          owner = [self->_factory startPcmPlayoutWithSampleRate:(int)rate channels:(int)channels shared:[mode isEqual:@"shared"]];
#else
          if (rate != 24000 || channels != 1 || ![mode isEqual:@"exclusive"]) error = @"Matching PCM SDK required";
          else if (self->_generations.count) error = @"PCM output already owned";
          else owner = [self->_factory startPcmPlayout];
#endif
          if (!error && owner <= 0) { code = (int)owner; error = @"Could not acquire PCM output"; }
          if (!error) { [self->_generations addObject:@(owner)]; self.active = YES; }
        }
      } else if (![arguments isKindOfClass:[NSDictionary class]]) error = @"Expected arguments map";
      else {
        int64_t generation = PcmInteger(arguments[@"generation"]);
        owner = generation;
        int64_t epoch = PcmInteger(arguments[@"epoch"]);
        if (generation <= 0 || ![self->_generations containsObject:@(generation)]) error = @"Stale PCM generation";
        else if ([method isEqualToString:@"pcmPlayoutWrite"]) {
          id pcm = arguments[@"pcm"];
          if (![pcm isKindOfClass:[NSData class]]) error = @"Expected PCM16LE bytes";
          else code = [self->_factory writePcmPlayout:pcm generation:generation epoch:epoch];
        } else if ([method isEqualToString:@"pcmPlayoutClear"]) {
          code = [self->_factory clearPcmPlayout:generation epoch:epoch];
        } else if ([method isEqualToString:@"pcmPlayoutStop"]) {
          code = [self->_factory stopPcmPlayout:generation];
          if (code == 0) { [self->_generations removeObject:@(generation)]; self.active = self->_generations.count != 0; }
        } else if (![method isEqualToString:@"pcmPlayoutState"]) error = @"Unknown PCM operation";
      }
#ifdef RTC_PCM_PLAYOUT_SHARED
      state = [self->_factory pcmPlayoutStateForGeneration:owner];
#else
      state = [self->_factory pcmPlayoutState];
#endif
      if (code != 0) error = [NSString stringWithFormat:@"PCM operation rejected (%d)", code];
      if (code != 0) {
        NSMutableDictionary *details = [state mutableCopy] ?: [NSMutableDictionary new];
        details[@"errorCode"] = code == -5 ? @"pcmPlayoutBusy" : code == -4 ? @"pcmPlayoutCapacity" :
            code == -3 ? @"pcmPlayoutArguments" : code == -2 ? @"pcmPlayoutStale" : @"pcmPlayoutFailed";
        state = details;
      }
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
    for (NSNumber *generation in [self->_generations copy]) {
      // Native stop quiesces even on error. Factory destruction forcibly
      // detaches the silent source; it cannot outlive its mixer callbacks.
      if ([self->_factory stopPcmPlayout:generation.longLongValue] == 0) [self->_generations removeObject:generation];
    }
    self.active = self->_generations.count != 0;
#endif
  });
}
@end
