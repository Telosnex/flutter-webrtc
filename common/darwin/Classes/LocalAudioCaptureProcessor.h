#import <Foundation/Foundation.h>
#import "AudioProcessingAdapter.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^LocalAudioCaptureEventHandler)(NSDictionary<NSString*, id>* event);

/// Read-only post-APM tap.
///
/// The realtime callback only copies one mono float channel into a bounded,
/// preallocated SPSC ring and signals a dispatch source. Conversion, batching,
/// dictionary allocation, and Flutter delivery happen on `_drainQueue`.
@interface LocalAudioCaptureProcessor : NSObject <ExternalAudioProcessingDelegate>

- (instancetype)initWithEventHandler:(LocalAudioCaptureEventHandler)eventHandler;

@property(nonatomic, readonly) NSUInteger activeGeneration;
@property(nonatomic, readonly, getter=isActive) BOOL active;
@property(nonatomic, readonly) NSUInteger processedCallbacks;
@property(nonatomic, readonly) NSUInteger processedFrames;

/// Starts a new logical generation before the ADM starts recording.
- (NSUInteger)activate;

/// Stops delivery for [generation]. Returns NO for a stale generation.
- (BOOL)deactivateGeneration:(NSUInteger)generation;

@end

NS_ASSUME_NONNULL_END
