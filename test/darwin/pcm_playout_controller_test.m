#import "LocalPcmPlayoutController.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) {fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);exit(1);} } while(0)
@implementation RTCPeerConnectionFactory
- (int64_t)startPcmPlayout { CHECK(![NSThread isMainThread]); self.starts++;return self.generation=7; }
- (int)writePcmPlayout:(NSData *)pcm generation:(int64_t)generation epoch:(int64_t)epoch { return 0; }
- (int)clearPcmPlayout:(int64_t)generation epoch:(int64_t)epoch { return 0; }
- (int)stopPcmPlayout:(int64_t)generation { CHECK(![NSThread isMainThread]);if(self.failStop)return -1;[self.owners removeObjectForKey:@(generation)];self.generation=0;return 0; }
- (NSDictionary *)pcmPlayoutState { return @{ @"generation": @(self.generation) }; }
#ifdef RTC_PCM_PLAYOUT_SHARED
- (int64_t)startPcmPlayoutWithSampleRate:(int)rate channels:(int)channels shared:(BOOL)shared {
  CHECK(![NSThread isMainThread]);
  if (!self.owners) self.owners = [NSMutableDictionary new];
  if (self.owners.count >= 2) return -4;
  for (NSDictionary *state in self.owners.allValues) {
    if (!shared || [state[@"ownershipMode"] isEqual:@"exclusive"]) return -5;
  }
  self.starts++;
  if (!self.nextGeneration) self.nextGeneration = 6;
  self.generation = ++self.nextGeneration;
  self.owners[@(self.generation)] = @{ @"generation": @(self.generation),
    @"sampleRate": @(rate), @"channels": @(channels), @"ownershipMode": shared ? @"shared" : @"exclusive" };
  return self.generation;
}
- (NSDictionary *)pcmPlayoutStateForGeneration:(int64_t)generation {
  return self.owners[@(generation)] ?: @{ @"generation": @0 };
}
#endif
@end
static NSString *Run(LocalPcmPlayoutController *c,NSString *method,id args) {
  __block BOOL done=NO;__block NSString *failure;
  [c perform:method arguments:args completion:^(NSDictionary *state,NSString *error){ CHECK([NSThread isMainThread]);failure=error;done=YES; }];
  NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
  while(!done && [deadline timeIntervalSinceNow]>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
  CHECK(done);return failure;
}
int main() {
  @autoreleasepool {
    RTCPeerConnectionFactory *factory=[RTCPeerConnectionFactory new];
    LocalPcmPlayoutController *c=[[LocalPcmPlayoutController alloc] initWithFactory:factory];
    CHECK([LocalPcmPlayoutController isSupported]);
    CHECK(!Run(c,@"pcmPlayoutStart",nil));
    CHECK(Run(c,@"pcmPlayoutStart",nil));
    NSDictionary *args=@{ @"generation":@7,@"epoch":@0,@"pcm":[NSMutableData dataWithLength:480] };
    CHECK(!Run(c,@"pcmPlayoutWrite",args));
    CHECK(Run(c,@"pcmPlayoutWrite",@{ @"generation":@YES,@"pcm":@[] }));
    factory.failStop=YES;CHECK(Run(c,@"pcmPlayoutStop",args));CHECK(factory.generation==7);
    factory.failStop=NO;CHECK(!Run(c,@"pcmPlayoutStop",args));CHECK(factory.generation==0);
    [c shutdown];CHECK(Run(c,@"pcmPlayoutStart",nil));CHECK(factory.starts==1);
#ifdef RTC_PCM_PLAYOUT_SHARED
    RTCPeerConnectionFactory *sharedFactory = [RTCPeerConnectionFactory new];
    LocalPcmPlayoutController *shared = [[LocalPcmPlayoutController alloc] initWithFactory:sharedFactory];
    CHECK(!Run(shared,@"pcmPlayoutStart",@{ @"sampleRate":@24000,@"channels":@1,@"ownershipMode":@"shared" }));
    CHECK(!Run(shared,@"pcmPlayoutStart",@{ @"sampleRate":@48000,@"channels":@2,@"ownershipMode":@"shared" }));
    CHECK(Run(shared,@"pcmPlayoutStart",nil));
    CHECK(shared.active);
    CHECK(!Run(shared,@"pcmPlayoutStop",@{ @"generation":@7 }));
    CHECK(shared.active); CHECK(sharedFactory.owners.count == 1);
    CHECK(!Run(shared,@"pcmPlayoutState",@{ @"generation":@8 }));
    CHECK(Run(shared,@"pcmPlayoutState",@{ @"generation":@7 }));
    sharedFactory.failStop = YES;
    CHECK(Run(shared,@"pcmPlayoutStop",@{ @"generation":@8 })); CHECK(shared.active);
    sharedFactory.failStop = NO;
    CHECK(!Run(shared,@"pcmPlayoutStop",@{ @"generation":@8 })); CHECK(!shared.active);
    CHECK([[LocalPcmPlayoutController capabilities][@"maxSharedSources"] intValue] == 2);
#endif
  }
  puts("PASS: Darwin PCM controller, worker queue, stale owner, stop retry, detach");return 0;
}
