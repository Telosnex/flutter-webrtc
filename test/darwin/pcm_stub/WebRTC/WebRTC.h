#import <Foundation/Foundation.h>
#define RTC_PCM_PLAYOUT_V1 1
@interface RTCPeerConnectionFactory : NSObject
@property BOOL failStop;
@property int64_t generation;
@property NSInteger starts;
- (int64_t)startPcmPlayout;
- (int)writePcmPlayout:(NSData *)pcm generation:(int64_t)generation epoch:(int64_t)epoch;
- (int)clearPcmPlayout:(int64_t)generation epoch:(int64_t)epoch;
- (int)stopPcmPlayout:(int64_t)generation;
- (NSDictionary *)pcmPlayoutState;
@end
