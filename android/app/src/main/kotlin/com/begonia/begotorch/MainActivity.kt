package com.begonia.begotorch

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private lateinit var torchController: TorchController
    private val channelName = "com.begonia.begotorch/torch"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        torchController = TorchController(this)
        torchController.probeCameras()
    }

    override fun onDestroy() {
        super.onDestroy()
        torchController.release()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "setLevel" -> {
                    val level = call.argument<Int>("level") ?: 0
                    val ok = torchController.setLevel(level)
                    result.success(ok)
                }
                "currentLevel" -> {
                    result.success(torchController.currentLevel())
                }
                "isFrameworkAvailable" -> {
                    result.success(torchController.isFrameworkAvailable())
                }
                "toggleFrom" -> {
                    val current = call.argument<Int>("current") ?: 0
                    val newLevel = torchController.toggleFrom(current)
                    result.success(newLevel)
                }
                else -> result.notImplemented()
            }
        }
    }
}

