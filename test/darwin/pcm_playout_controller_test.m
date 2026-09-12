#import "LocalPcmPlayoutController.h"
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { if (!(x)) {fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);exit(1);} } while(0)
@implementation RTCPeerConnectionFactory
- (int64_t)startPcmPlayout { CHECK(![NSThread isMainThread]); self.starts++;return self.generation=7; }
- (int)writePcmPlayout:(NSData *)pcm generation:(int64_t)generation epoch:(int64_t)epoch { return 0; }
- (int)clearPcmPlayout:(int64_t)generation epoch:(int64_t)epoch { return 0; }
- (int)stopPcmPlayout:(int64_t)generation { CHECK(![NSThread isMainThread]);if(self.failStop)return -1;self.generation=0;return 0; }
- (NSDictionary *)pcmPlayoutState { return @{ @"generation": @(self.generation) }; }
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
  }
  puts("PASS: Darwin PCM controller, worker queue, stale owner, stop retry, detach");return 0;
}
