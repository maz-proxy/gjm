package com.mamaz.stockopname;

import android.Manifest;
import android.content.Context;
import android.hardware.camera2.CaptureRequest;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.util.Size;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;
import androidx.annotation.NonNull;
import androidx.camera.core.Camera;
import androidx.camera.core.CameraSelector;
import androidx.camera.core.FocusMeteringAction;
import androidx.camera.core.ImageAnalysis;
import androidx.camera.core.ImageProxy;
import androidx.camera.core.Preview;
import androidx.camera.core.UseCaseGroup;
import androidx.camera.core.ViewPort;
import androidx.camera.camera2.interop.Camera2Interop;
import androidx.camera.lifecycle.ProcessCameraProvider;
import androidx.camera.view.PreviewView;
import androidx.camera.view.transform.CoordinateTransform;
import androidx.camera.view.transform.ImageProxyTransformFactory;
import androidx.camera.view.transform.OutputTransform;
import androidx.core.content.ContextCompat;
import androidx.lifecycle.LifecycleOwner;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import com.google.common.util.concurrent.ListenableFuture;
import com.google.mlkit.vision.barcode.BarcodeScanning;
import com.google.mlkit.vision.barcode.BarcodeScanner;
import com.google.mlkit.vision.barcode.BarcodeScannerOptions;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.common.InputImage;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

@CapacitorPlugin(
    name = "NativeBarcodeScanner",
    permissions = {
        @Permission(alias = "camera", strings = { Manifest.permission.CAMERA })
    }
)
public class NativeBarcodeScannerPlugin extends Plugin {
    private final ExecutorService analysisExecutor = Executors.newSingleThreadExecutor();
    private final ImageProxyTransformFactory imageProxyTransformFactory =
        createImageProxyTransformFactory();
    private FrameLayout scannerRoot;
    private PreviewView previewView;
    private ProcessCameraProvider cameraProvider;
    private Camera camera;
    private BarcodeScanner barcodeScanner;
    private long lastBarcodeEventAt;
    private long lastBarcodeMissEventAt;
    private String lastBarcodeValue = "";

    @PluginMethod
    public void startScanner(PluginCall call) {
        if (hasRequiredPermissions()) {
            startScannerWithPermission(call);
        } else {
            requestPermissionForAlias("camera", call, "cameraPermissionCallback");
        }
    }

    @PermissionCallback
    private void cameraPermissionCallback(PluginCall call) {
        if (!hasRequiredPermissions()) {
            call.reject("Izin kamera belum diberikan.");
            return;
        }
        startScannerWithPermission(call);
    }

    private void startScannerWithPermission(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            if (scannerRoot != null) {
                call.resolve();
                return;
            }
            try {
                Context context = getContext();
                FrameLayout content = getActivity().findViewById(android.R.id.content);
                scannerRoot = new FrameLayout(context);
                previewView = new PreviewView(context);
                previewView.setImplementationMode(PreviewView.ImplementationMode.COMPATIBLE);
                previewView.setScaleType(PreviewView.ScaleType.FILL_CENTER);
                scannerRoot.addView(
                    previewView,
                    new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                );

                ScannerOverlay overlay = new ScannerOverlay(context);
                scannerRoot.addView(
                    overlay,
                    new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.MATCH_PARENT
                    )
                );
                addScannerControls(context, scannerRoot);
                previewView.setOnTouchListener((view, event) -> {
                    if (event.getAction() == MotionEvent.ACTION_UP) {
                        focusAt(event.getX(), event.getY());
                    }
                    return true;
                });
                content.addView(
                    scannerRoot,
                    new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        dp(context, 320),
                        Gravity.TOP
                    )
                );
                content.post(() -> {
                    if (scannerRoot == null) return;
                    ViewGroup.LayoutParams params = scannerRoot.getLayoutParams();
                    params.height = Math.max(
                        dp(context, 240),
                        Math.min(dp(context, 380), (int) (content.getHeight() * 0.44f))
                    );
                    scannerRoot.setLayoutParams(params);
                });
                bindCamera(call);
            } catch (Exception error) {
                stopScannerInternal();
                call.reject("Kamera native tidak dapat dibuka.", error);
            }
        });
    }

    private void addScannerControls(Context context, FrameLayout root) {
        TextView instruction = new TextView(context);
        instruction.setText("Arahkan barcode ke bingkai · ketuk untuk fokus");
        instruction.setTextColor(Color.WHITE);
        instruction.setTextSize(15);
        instruction.setGravity(Gravity.CENTER);
        instruction.setBackgroundColor(0x99000000);
        FrameLayout.LayoutParams instructionParams = new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            dp(context, 54),
            Gravity.TOP
        );
        root.addView(instruction, instructionParams);

        TextView closeButton = new TextView(context);
        closeButton.setText("×");
        closeButton.setTextColor(Color.WHITE);
        closeButton.setTextSize(34);
        closeButton.setGravity(Gravity.CENTER);
        closeButton.setBackgroundColor(0x99000000);
        closeButton.setContentDescription("Tutup pemindai kamera");
        FrameLayout.LayoutParams closeParams = new FrameLayout.LayoutParams(
            dp(context, 56),
            dp(context, 56),
            Gravity.TOP | Gravity.END
        );
        root.addView(closeButton, closeParams);
        closeButton.setOnClickListener(view -> {
            notifyListeners("scannerClosed", new JSObject());
            stopScannerInternal();
        });
    }

    private void bindCamera(PluginCall call) {
        ListenableFuture<ProcessCameraProvider> providerFuture =
            ProcessCameraProvider.getInstance(getContext());
        providerFuture.addListener(() -> {
            if (scannerRoot == null || previewView == null) {
                call.reject("Pemindai kamera ditutup sebelum kamera siap.");
                return;
            }
            try {
                cameraProvider = providerFuture.get();
                bindCameraUseCases(call);
            } catch (Exception error) {
                stopScannerInternal();
                call.reject("Kamera native tidak dapat dimulai.", error);
            }
        }, ContextCompat.getMainExecutor(getContext()));
    }

    private void bindCameraUseCases(PluginCall call) {
        if (scannerRoot == null || previewView == null || cameraProvider == null) {
            call.reject("Pemindai kamera ditutup sebelum kamera siap.");
            return;
        }
        ViewPort viewPort = previewView.getViewPort();
        if (viewPort == null) {
            previewView.post(() -> bindCameraUseCases(call));
            return;
        }
        try {
            Preview.Builder previewBuilder = new Preview.Builder();
            new Camera2Interop.Extender<>(previewBuilder).setCaptureRequestOption(
                CaptureRequest.CONTROL_AF_MODE,
                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
            );
            Preview preview = previewBuilder.build();
            preview.setSurfaceProvider(previewView.getSurfaceProvider());
            ImageAnalysis analysis = new ImageAnalysis.Builder()
                .setTargetResolution(new Size(1920, 1080))
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build();
            BarcodeScannerOptions options = new BarcodeScannerOptions.Builder()
                .setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS)
                .build();
            barcodeScanner = BarcodeScanning.getClient(options);
            analysis.setAnalyzer(analysisExecutor, this::analyzeFrame);
            UseCaseGroup useCaseGroup = new UseCaseGroup.Builder()
                .setViewPort(viewPort)
                .addUseCase(preview)
                .addUseCase(analysis)
                .build();
            cameraProvider.unbindAll();
            camera = cameraProvider.bindToLifecycle(
                (LifecycleOwner) getActivity(),
                CameraSelector.DEFAULT_BACK_CAMERA,
                useCaseGroup
            );
            call.resolve();
        } catch (Exception error) {
            stopScannerInternal();
            call.reject("Kamera native tidak dapat dimulai.", error);
        }
    }

    private void analyzeFrame(ImageProxy imageProxy) {
        android.media.Image mediaImage = imageProxy.getImage();
        if (mediaImage == null || barcodeScanner == null) {
            imageProxy.close();
            return;
        }
        BarcodeScanner activeScanner = barcodeScanner;
        InputImage inputImage = InputImage.fromMediaImage(
            mediaImage,
            imageProxy.getImageInfo().getRotationDegrees()
        );
        activeScanner.process(inputImage)
            .addOnSuccessListener(analysisExecutor, barcodes -> {
                long now = System.currentTimeMillis();
                boolean barcodeFound = false;
                for (Barcode barcode : barcodes) {
                    String value = barcode.getRawValue();
                    if (
                        value == null ||
                        value.trim().isEmpty() ||
                        !isBarcodeInsideScanFrame(barcode, imageProxy)
                    ) continue;
                    barcodeFound = true;
                    if (!value.equals(lastBarcodeValue) || now - lastBarcodeEventAt >= 350) {
                        lastBarcodeValue = value;
                        lastBarcodeEventAt = now;
                        JSObject result = new JSObject();
                        result.put("value", value.trim());
                        notifyListeners("barcodeDetected", result);
                    }
                    break;
                }
                if (!barcodeFound && now - lastBarcodeMissEventAt >= 300) {
                    lastBarcodeValue = "";
                    lastBarcodeMissEventAt = now;
                    notifyListeners("barcodeMissed", new JSObject());
                }
            })
            .addOnFailureListener(analysisExecutor, error ->
                android.util.Log.w("NativeBarcodeScanner", "Barcode analysis failed.", error)
            )
            .addOnCompleteListener(analysisExecutor, task -> imageProxy.close());
    }

    private boolean isBarcodeInsideScanFrame(Barcode barcode, ImageProxy imageProxy) {
        if (previewView == null || previewView.getWidth() <= 0 || previewView.getHeight() <= 0) {
            return false;
        }
        android.graphics.Rect boundingBox = barcode.getBoundingBox();
        OutputTransform previewTransform = previewView.getOutputTransform();
        if (boundingBox == null || previewTransform == null) return false;

        RectF previewBounds = new RectF(boundingBox);
        CoordinateTransform coordinateTransform = new CoordinateTransform(
            imageProxyTransformFactory.getOutputTransform(imageProxy),
            previewTransform
        );
        coordinateTransform.mapRect(previewBounds);
        return isPointInsideScanFrame(
            previewBounds.centerX(),
            previewBounds.centerY(),
            previewView.getWidth(),
            previewView.getHeight()
        );
    }

    static boolean isPointInsideScanFrame(float x, float y, int width, int height) {
        if (width <= 0 || height <= 0) return false;
        float frameWidth = width * 0.9f;
        float frameHeight = Math.min(height * 0.25f, frameWidth * 0.55f);
        float left = (width - frameWidth) / 2;
        float top = (height - frameHeight) / 2;
        return x >= left && x <= left + frameWidth && y >= top && y <= top + frameHeight;
    }

    private static ImageProxyTransformFactory createImageProxyTransformFactory() {
        ImageProxyTransformFactory factory = new ImageProxyTransformFactory();
        factory.setUsingRotationDegrees(true);
        return factory;
    }

    private void focusAt(float x, float y) {
        if (previewView == null || camera == null) return;
        FocusMeteringAction action = new FocusMeteringAction.Builder(
            previewView.getMeteringPointFactory().createPoint(x, y),
            FocusMeteringAction.FLAG_AF | FocusMeteringAction.FLAG_AE
        ).setAutoCancelDuration(3, TimeUnit.SECONDS).build();
        camera.getCameraControl().startFocusAndMetering(action);
    }

    @PluginMethod
    public void stopScanner(PluginCall call) {
        getActivity().runOnUiThread(() -> {
            stopScannerInternal();
            call.resolve();
        });
    }

    private void stopScannerInternal() {
        if (cameraProvider != null) {
            cameraProvider.unbindAll();
            cameraProvider = null;
        }
        camera = null;
        if (barcodeScanner != null) {
            barcodeScanner.close();
            barcodeScanner = null;
        }
        if (scannerRoot != null && scannerRoot.getParent() instanceof ViewGroup) {
            ((ViewGroup) scannerRoot.getParent()).removeView(scannerRoot);
        }
        scannerRoot = null;
        previewView = null;
        lastBarcodeValue = "";
        lastBarcodeEventAt = 0;
        lastBarcodeMissEventAt = 0;
    }

    @Override
    protected void handleOnPause() {
        if (scannerRoot != null) {
            notifyListeners("scannerClosed", new JSObject());
            stopScannerInternal();
        }
    }

    @Override
    protected void handleOnDestroy() {
        stopScannerInternal();
        analysisExecutor.shutdown();
    }

    private static int dp(@NonNull Context context, int value) {
        return Math.round(value * context.getResources().getDisplayMetrics().density);
    }

    private static class ScannerOverlay extends View {
        private final Paint framePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint linePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint shadePaint = new Paint(Paint.ANTI_ALIAS_FLAG);

        ScannerOverlay(Context context) {
            super(context);
            framePaint.setColor(Color.rgb(73, 226, 124));
            framePaint.setStyle(Paint.Style.STROKE);
            framePaint.setStrokeWidth(dp(context, 3));
            linePaint.setColor(Color.rgb(73, 226, 124));
            linePaint.setStrokeWidth(dp(context, 2));
            shadePaint.setColor(0x26000000);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            float frameWidth = getWidth() * 0.9f;
            float frameHeight = Math.min(getHeight() * 0.25f, frameWidth * 0.55f);
            float left = (getWidth() - frameWidth) / 2;
            float top = (getHeight() - frameHeight) / 2;
            RectF frame = new RectF(left, top, left + frameWidth, top + frameHeight);
            canvas.drawRect(0, 0, getWidth(), frame.top, shadePaint);
            canvas.drawRect(0, frame.bottom, getWidth(), getHeight(), shadePaint);
            canvas.drawRect(0, frame.top, frame.left, frame.bottom, shadePaint);
            canvas.drawRect(frame.right, frame.top, getWidth(), frame.bottom, shadePaint);
            canvas.drawRect(frame, framePaint);
            canvas.drawLine(frame.left, frame.centerY(), frame.right, frame.centerY(), linePaint);
        }
    }
}
