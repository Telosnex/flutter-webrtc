package com.cloudwebrtc.webrtc.audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class LocalAudioCaptureControllerTest {
  private static final class FakeOwner
      implements LocalAudioCaptureController.NativeRecordingOwner {
    int acquireResult;
    int releaseResult;
    int acquireCalls;
    int releaseCalls;
    LocalAudioCaptureController.State state =
        new LocalAudioCaptureController.State(true, false, false, false);

    @Override
    public int acquire() {
      acquireCalls++;
      return acquireResult;
    }

    @Override
    public int release() {
      releaseCalls++;
      return releaseResult;
    }

    @Override
    public LocalAudioCaptureController.State getState() {
      return state;
    }
  }

  @Test
  public void successfulAcquireAndReleaseAreBalanced() {
    FakeOwner owner = new FakeOwner();
    LocalAudioCaptureController controller = new LocalAudioCaptureController(owner);

    assertEquals(0, controller.acquire());
    assertTrue(controller.isAcquired());
    assertEquals(-1, controller.acquire());
    assertEquals(1, owner.acquireCalls);

    assertEquals(0, controller.release());
    assertFalse(controller.isAcquired());
    assertEquals(1, owner.releaseCalls);
    assertEquals(0, controller.release());
    assertEquals(1, owner.releaseCalls);
  }

  @Test
  public void failedAcquireDoesNotCreateOwnership() {
    FakeOwner owner = new FakeOwner();
    owner.acquireResult = -7;
    LocalAudioCaptureController controller = new LocalAudioCaptureController(owner);

    assertEquals(-7, controller.acquire());
    assertFalse(controller.isAcquired());
    assertEquals(0, controller.release());
    assertEquals(0, owner.releaseCalls);
  }

  @Test
  public void failedReleaseRetainsOwnershipForRetry() {
    FakeOwner owner = new FakeOwner();
    LocalAudioCaptureController controller = new LocalAudioCaptureController(owner);
    assertEquals(0, controller.acquire());

    owner.releaseResult = -9;
    assertEquals(-9, controller.release());
    assertTrue(controller.isAcquired());
    owner.releaseResult = 0;
    assertEquals(0, controller.release());
    assertFalse(controller.isAcquired());
    assertEquals(2, owner.releaseCalls);
  }

  @Test
  public void shutdownBeforeQueuedAcquirePreventsNativeStart() {
    FakeOwner owner = new FakeOwner();
    LocalAudioCaptureController controller = new LocalAudioCaptureController(owner);

    assertEquals(0, controller.shutdown());
    assertTrue(controller.isClosed());
    assertEquals(-1, controller.acquire());
    assertEquals(0, owner.acquireCalls);
  }

  @Test
  public void shutdownReleasesCurrentDemand() {
    FakeOwner owner = new FakeOwner();
    LocalAudioCaptureController controller = new LocalAudioCaptureController(owner);
    assertEquals(0, controller.acquire());

    assertEquals(0, controller.shutdown());
    assertTrue(controller.isClosed());
    assertFalse(controller.isAcquired());
    assertEquals(1, owner.releaseCalls);
  }

  @Test
  public void stateIsNativeSnapshot() {
    FakeOwner owner = new FakeOwner();
    LocalAudioCaptureController controller = new LocalAudioCaptureController(owner);
    assertSame(owner.state, controller.getState());
  }
}
