package com.mamaz.stockopname;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class NativeBarcodeScannerPluginTest {

    @Test
    public void scanFrameAcceptsPointsInsideGreenFrame() {
        assertTrue(NativeBarcodeScannerPlugin.isPointInsideScanFrame(200, 150, 400, 300));
        assertTrue(NativeBarcodeScannerPlugin.isPointInsideScanFrame(25, 150, 400, 300));
    }

    @Test
    public void scanFrameRejectsPointsOutsideGreenFrame() {
        assertFalse(NativeBarcodeScannerPlugin.isPointInsideScanFrame(10, 150, 400, 300));
        assertFalse(NativeBarcodeScannerPlugin.isPointInsideScanFrame(200, 110, 400, 300));
        assertFalse(NativeBarcodeScannerPlugin.isPointInsideScanFrame(200, 190, 400, 300));
    }

    @Test
    public void scanFrameRejectsInvalidPreviewSize() {
        assertFalse(NativeBarcodeScannerPlugin.isPointInsideScanFrame(0, 0, 0, 300));
        assertFalse(NativeBarcodeScannerPlugin.isPointInsideScanFrame(0, 0, 400, 0));
    }
}
