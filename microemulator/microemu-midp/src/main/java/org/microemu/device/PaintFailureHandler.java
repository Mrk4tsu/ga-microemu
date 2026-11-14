package org.microemu.device;

/** Optional platform hook: a failed paint must not be published as a good frame. */
public interface PaintFailureHandler {
    void paintFailed(Throwable error);
}
