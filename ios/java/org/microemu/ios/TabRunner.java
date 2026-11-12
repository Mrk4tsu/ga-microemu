package org.microemu.ios;

/** Entry point contract implemented by per-tab IOSRuntime instances across ClassLoaders. */
public interface TabRunner {
    int runTab(int tabId, String jarPath, String rmsPath, int width, int height);
}
