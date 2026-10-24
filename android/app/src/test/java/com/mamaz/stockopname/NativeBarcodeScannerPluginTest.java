package com.mamaz.stockopname;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class NativeBarcodeScannerPluginTest {

    @Test
    public void previewAcceptsPointsInsideTheGreenFrameCameraArea() {
        assertTrue(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(200, 150, 400, 300));
        assertTrue(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(0, 150, 400, 300));
        assertTrue(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(400, 150, 400, 300));
    }

    @Test
    public void previewRejectsPointsOutsideTheGreenFrameCameraArea() {
        assertFalse(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(-1, 150, 400, 300));
        assertFalse(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(401, 150, 400, 300));
        assertFalse(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(200, -1, 400, 300));
        assertFalse(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(200, 301, 400, 300));
    }

    @Test
    public void previewRejectsPointsWhenSizeIsInvalid() {
        assertFalse(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(0, 0, 0, 300));
        assertFalse(NativeBarcodeScannerPlugin.isPointInsidePreviewBounds(0, 0, 400, 0));
    }
}
