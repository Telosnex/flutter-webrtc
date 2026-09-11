#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One app owner. Run acquire and release on one serial lifecycle queue.
/// close is nonblocking and can run on the platform thread during detach.
@interface LocalAudioCaptureController : NSObject
- (instancetype)initWithAcquire:(NSInteger (^)(id _Nullable options))acquire
                        release:(NSInteger (^)(void))release;
- (NSInteger)acquireWithOptions:(nullable id)options;
- (NSInteger)releaseRecording;
- (void)close;
@property(nonatomic, readonly, getter=isClosed) BOOL closed;
/// Read on the lifecycle queue. Failed release keeps ownership for retry.
@property(nonatomic, readonly, getter=isAcquired) BOOL acquired;
@end

NS_ASSUME_NONNULL_END
