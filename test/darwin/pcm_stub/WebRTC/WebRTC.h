#import <Foundation/Foundation.h>
#define RTC_PCM_PLAYOUT_V1 1
@interface RTCPeerConnectionFactory : NSObject
@property BOOL failStop;
@property int64_t generation;
@property NSInteger starts;
@property NSMutableDictionary<NSNumber *, NSDictionary *> *owners;
@property int64_t nextGeneration;
#ifdef RTC_PCM_PLAYOUT_SHARED
- (int64_t)startPcmPlayoutWithSampleRate:(int)rate channels:(int)channels shared:(BOOL)shared;
- (NSDictionary *)pcmPlayoutStateForGeneration:(int64_t)generation;
#endif
- (int64_t)startPcmPlayout;
- (int)writePcmPlayout:(NSData *)pcm generation:(int64_t)generation epoch:(int64_t)epoch;
- (int)clearPcmPlayout:(int64_t)generation epoch:(int64_t)epoch;
- (int)stopPcmPlayout:(int64_t)generation;
- (NSDictionary *)pcmPlayoutState;
@end
