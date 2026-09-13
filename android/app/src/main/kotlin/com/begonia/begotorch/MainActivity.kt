package com.begonia.begotorch

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

    private lateinit var torchController: TorchController

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        torchController = TorchController(this)
        torchController.findWorkingPath()
    }

    override fun onDestroy() {
        super.onDestroy()
        torchController.release()
    }
}
