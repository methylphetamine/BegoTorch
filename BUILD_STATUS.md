# Build Status: FAILED

**Run ID**: 34761961872  
**Workflow**: Build BegoTorch APK  
**Commit**: 5af4f01d (feat: replace direct sysfs write with Android Camera2 framework torch control)  
**Status**: ❌ Failed  
**Duration**: ~5.6 minutes

## What Was Changed

### Android (Kotlin)
- **New**: `TorchController.kt` - Uses Camera2 `setTorchMode()` API (API 28+) with sysfs fallback
- **Modified**: `MainActivity.kt` - Added MethodChannel for Flutter communication
- **Modified**: `TorchTileService.kt` - Uses TorchController instead of direct sysfs
- **Modified**: `AndroidManifest.xml` - Added CAMERA permission

### Flutter (Dart)
- **Modified**: `lib/main.dart` - Calls Android via MethodChannel instead of direct sysfs write

## Why This Matters

The original direct sysfs write fails under SELinux enforcing because the app domain is denied write access to sysfs nodes. The Camera2 framework path works because the camera service runs in a privileged SELinux domain that CAN write the torch sysfs node.

**This is the non-root path through the SELinux barrier.**

## Build Failure

The build failed during "Build release APK" step. The preparatory steps (checkout, Java 17, Flutter setup, dependencies, analysis, tests) all passed.

### Possible Causes
1. Flutter/Android SDK configuration in CI
2. Kotlin compilation errors in TorchController.kt
3. Gradle build issues
4. Missing dependencies

## Next Steps

1. **Check GitHub Actions logs**: https://github.com/requiredroot/BegoTorch/actions/runs/34761961872
2. **Fix any compilation errors** shown in logs
3. **Rebuild and test** on device

## How It Should Work (When Fixed)

```
User sets slider → MethodChannel → TorchController
    ├── Camera2 available → setTorchMode() (privileged, works under SELinux enforcing)
    └── No camera / API < 28 → sysfs write (fallback, only if ROM allows)
```

## Requirements for Torch to Work

- Android 9+ (API 28) for `setTorchMode()` - OR - ROM allows app-domain sysfs writes
- CAMERA permission granted
- At least one torch-capable camera on device
- SELinux can be enforcing (framework path doesn't need permissive)
