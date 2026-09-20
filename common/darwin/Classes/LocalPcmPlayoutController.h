#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

/// Owns only app PCM demand. All ADM work stays off Flutter's platform thread.
@interface LocalPcmPlayoutController : NSObject
+ (BOOL)isSupported;
+ (NSDictionary *)capabilities;
@property(atomic, readonly) BOOL active;
- (instancetype)initWithFactory:(RTCPeerConnectionFactory *)factory;
- (void)perform:(NSString *)method arguments:(id)arguments
     completion:(void (^)(NSDictionary *state, NSString *error))completion;
- (void)shutdown;
@end
