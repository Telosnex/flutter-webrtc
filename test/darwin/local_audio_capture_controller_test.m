#include <stdio.h>
#include <stdlib.h>
#import "LocalAudioCaptureController.h"

#define CHECK(condition)                                           \
  do {                                                             \
    if (!(condition)) {                                            \
      fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); \
      exit(1);                                                     \
    }                                                              \
  } while (0)

int main(void) {
  @autoreleasepool {
    __block NSInteger starts = 0;
    __block NSInteger stops = 0;
    __block NSInteger startResult = 0;
    __block NSInteger stopResult = 0;
    id options = @{@"echoCancellation" : @YES};
    LocalAudioCaptureController* controller = [[LocalAudioCaptureController alloc]
        initWithAcquire:^NSInteger(id received) {
          CHECK(received == options);
          starts++;
          return startResult;
        }
        release:^NSInteger {
          stops++;
          return stopResult;
        }];
    CHECK([controller acquireWithOptions:options] == 0);
    CHECK(controller.isAcquired);
    CHECK([controller acquireWithOptions:options] == -1);
    CHECK(starts == 1);
    stopResult = -9;
    CHECK([controller releaseRecording] == -9);
    CHECK(controller.isAcquired);
    stopResult = 0;
    CHECK([controller releaseRecording] == 0);
    CHECK(!controller.isAcquired);
    CHECK(stops == 2);
    CHECK([controller releaseRecording] == 0);
    CHECK(stops == 2);
    startResult = -7;
    CHECK([controller acquireWithOptions:options] == -7);
    CHECK(!controller.isAcquired);
    CHECK([controller releaseRecording] == 0);
    CHECK(stops == 2);
    [controller close];
    CHECK(controller.isClosed);
    CHECK([controller acquireWithOptions:options] == -1);
    CHECK(starts == 2);
  }
  @autoreleasepool {
    __block NSInteger starts = 0;
    LocalAudioCaptureController* controller = [[LocalAudioCaptureController alloc]
        initWithAcquire:^NSInteger(id options) {
          starts++;
          return 0;
        }
        release:^NSInteger {
          return 0;
        }];
    [controller close];
    CHECK([controller acquireWithOptions:nil] == -1);
    CHECK(starts == 0);
  }
  @autoreleasepool {
    __block __weak LocalAudioCaptureController* hook;
    __block NSInteger stops = 0;
    __block NSInteger stopResult = -9;
    LocalAudioCaptureController* controller = [[LocalAudioCaptureController alloc]
        initWithAcquire:^NSInteger(id options) {
          dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            [hook close];
          });
          return 0;
        }
        release:^NSInteger {
          stops++;
          return stopResult;
        }];
    hook = controller;
    CHECK([controller acquireWithOptions:nil] == -1);
    CHECK(controller.isClosed);
    CHECK(controller.isAcquired);
    CHECK(stops == 1);
    stopResult = 0;
    CHECK([controller releaseRecording] == 0);
    CHECK(!controller.isAcquired);
    CHECK(stops == 2);
  }
  @autoreleasepool {
    __block NSInteger stops = 0;
    LocalAudioCaptureController* controller = [[LocalAudioCaptureController alloc]
        initWithAcquire:^NSInteger(id options) {
          return 0;
        }
        release:^NSInteger {
          stops++;
          return 0;
        }];
    CHECK([controller acquireWithOptions:nil] == 0);
    [controller close];
    CHECK([controller releaseRecording] == 0);
    CHECK(stops == 1);
    CHECK(!controller.isAcquired);
  }
  puts("PASS: Apple controller ownership, failure retry, and close-race checks");
  return 0;
}
