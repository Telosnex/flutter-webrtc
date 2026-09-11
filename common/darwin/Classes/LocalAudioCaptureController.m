#import "LocalAudioCaptureController.h"

@implementation LocalAudioCaptureController {
  NSInteger (^_acquire)(id);
  NSInteger (^_release)(void);
  BOOL _acquired;
  BOOL _closed;
}

- (instancetype)initWithAcquire:(NSInteger (^)(id))acquire release:(NSInteger (^)(void))release {
  self = [super init];
  if (self) {
    _acquire = [acquire copy];
    _release = [release copy];
  }
  return self;
}

- (BOOL)isClosed {
  @synchronized(self) {
    return _closed;
  }
}

- (void)close {
  // Do not hold this lock while calling the ADM. Native audio can need the
  // platform thread while this method runs on that thread during detach.
  @synchronized(self) {
    _closed = YES;
  }
}

- (BOOL)isAcquired {
  return _acquired;
}

- (NSInteger)acquireWithOptions:(id)options {
  if (self.isClosed || _acquired)
    return -1;
  NSInteger result = _acquire(options);
  if (result != 0)
    return result;
  _acquired = YES;
  if (self.isClosed) {
    // Detach raced the native operation. Release on this lifecycle queue.
    // If release fails, the queued detach cleanup can retry it.
    [self releaseRecording];
    return -1;
  }
  return 0;
}

- (NSInteger)releaseRecording {
  if (!_acquired)
    return 0;
  NSInteger result = _release();
  if (result == 0)
    _acquired = NO;
  return result;
}
@end
