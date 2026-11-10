package com.pyrunner.pyrunner

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Bridge between Flutter and the embedded Chaquopy CPython runtime.
 *
 * - MethodChannel "com.pyrunner.app/python": commands from Dart.
 * - EventChannel "com.pyrunner.app/python_output": streamed console lines
 *   and status events, produced by the Python bridge module
 *   (pyrunner_bridge.py) through a shared output queue.
 *
 * All Python work runs on a single background executor thread so the UI
 * never blocks while a script (or pip) runs.  Stop is handled on a
 * separate thread because the executor is busy while a script runs.
 */
class MainActivity : FlutterActivity() {

    private val methodChannelName = "com.pyrunner.app/python"
    private val eventChannelName = "com.pyrunner.app/python_output"
    private val storageChannelName = "com.pyrunner.app/storage"

    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private val inputQueue = LinkedBlockingQueue<String>()
    private val outputQueue = LinkedBlockingQueue<String>()

    private val pythonStarted = AtomicBoolean(false)
    private val drainRunning = AtomicBoolean(false)

    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isReady" -> result.success(pythonStarted.get())

                "ensurePython" -> {
                    executor.execute {
                        val ok = ensurePythonBlocking()
                        mainHandler.post { result.success(ok) }
                    }
                }

                "pythonVersion" -> {
                    executor.execute {
                        ensurePythonBlocking()
                        val version = try {
                            Python.getInstance().getModule("pyrunner_bridge")
                                .callAttr("python_version").toString()
                        } catch (e: Exception) {
                            "unknown"
                        }
                        mainHandler.post { result.success(version) }
                    }
                }

                "runScript" -> {
                    val path = call.argument<String>("path")
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    val projectDir = call.argument<String>("projectDir") ?: ""
                    val cwd = call.argument<String>("cwd") ?: ""
                    if (path.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "path is required", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        ensurePythonBlocking()
                        val code = try {
                            Python.getInstance().getModule("pyrunner_bridge")
                                .callAttr("run_script", path, args.toTypedArray(), projectDir, cwd)
                                .toJava(Int::class.java)
                        } catch (e: Exception) {
                            postError("Python error: ${e.message}")
                            1
                        }
                        mainHandler.post { result.success(code) }
                    }
                }

                "runModule" -> {
                    val module = call.argument<String>("module")
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    val projectDir = call.argument<String>("projectDir") ?: ""
                    val cwd = call.argument<String>("cwd") ?: ""
                    if (module.isNullOrEmpty()) {
                        result.error("BAD_ARGS", "module is required", null)
                        return@setMethodCallHandler
                    }
                    executor.execute {
                        ensurePythonBlocking()
                        val code = try {
                            Python.getInstance().getModule("pyrunner_bridge")
                                .callAttr("run_module", module, args.toTypedArray(), projectDir, cwd)
                                .toJava(Int::class.java)
                        } catch (e: Exception) {
                            postError("Python error: ${e.message}")
                            1
                        }
                        mainHandler.post { result.success(code) }
                    }
                }

                "replEval" -> {
                    val code = call.argument<String>("code") ?: ""
                    executor.execute {
                        ensurePythonBlocking()
                        try {
                            Python.getInstance().getModule("pyrunner_bridge")
                                .callAttr("repl_eval", code)
                        } catch (e: Exception) {
                            postError("Python error: ${e.message}")
                        }
                        mainHandler.post { result.success(null) }
                    }
                }

                "pipInstall" -> {
                    val args = call.argument<List<String>>("args") ?: emptyList()
                    executor.execute {
                        ensurePythonBlocking()
                        val code = try {
                            Python.getInstance().getModule("pyrunner_bridge")
                                .callAttr("pip_install", args.toTypedArray())
                                .toJava(Int::class.java)
                        } catch (e: Exception) {
                            postError("Python error: ${e.message}")
                            1
                        }
                        mainHandler.post { result.success(code) }
                    }
                }

                "pipList" -> {
                    executor.execute {
                        ensurePythonBlocking()
                        val out = try {
                            Python.getInstance().getModule("pyrunner_bridge")
                                .callAttr("pip_list").toString()
                        } catch (e: Exception) {
                            "pip list failed: ${e.message}"
                        }
                        mainHandler.post { result.success(out) }
                    }
                }

                "installedPackages" -> {
                    executor.execute {
                        ensurePythonBlocking()
                        val out = try {
                            Python.getInstance().getModule("pyrunner_bridge")
                                .callAttr("installed_packages").toString()
                        } catch (e: Exception) {
                            ""
                        }
                        mainHandler.post { result.success(out) }
                    }
                }

                "feedInput" -> {
                    inputQueue.offer(call.argument<String>("line") ?: "")
                    result.success(null)
                }

                "stopRun" -> {
                    // Must NOT go through the executor: it is busy running
                    // the script.  A dedicated thread asks the bridge to
                    // raise KeyboardInterrupt (and unblocks input()).
                    Thread {
                        try {
                            if (Python.isStarted()) {
                                Python.getInstance().getModule("pyrunner_bridge")
                                    .callAttr("request_stop")
                            }
                        } catch (_: Exception) {
                        }
                    }.start()
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        // All-files access (MANAGE_EXTERNAL_STORAGE, v1.0.4): needed to
        // open a project folder in place instead of copying it in.
        // Below Android 11 there is no such permission, so the check
        // reports granted and the settings call is a no-op.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            storageChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Environment.isExternalStorageManager()
                    } else {
                        true
                    }
                    result.success(granted)
                }

                "openAllFilesAccessSettings" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                        } catch (_: Exception) {
                            // Some devices hide the per-app page: fall
                            // back to the general all-files list.
                            try {
                                startActivity(
                                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                                )
                            } catch (_: Exception) {
                            }
                        }
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            eventChannelName
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                eventSink = events
                startDrain()
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    /** Starts Python once and wires the bridge queues. Runs on the executor. */
    private fun ensurePythonBlocking(): Boolean {
        if (pythonStarted.get()) return true
        return try {
            if (!Python.isStarted()) {
                Python.start(AndroidPlatform(applicationContext))
            }
            val py = Python.getInstance()
            py.getModule("pyrunner_bridge").callAttr("init", inputQueue, outputQueue)
            pythonStarted.set(true)
            true
        } catch (e: Exception) {
            postError("Failed to start Python: ${e.message}")
            false
        }
    }

    private fun postError(text: String) {
        outputQueue.offer("ERR|$text")
    }

    /** Drains the output queue and forwards tagged lines to Dart. */
    private fun startDrain() {
        if (!drainRunning.compareAndSet(false, true)) return
        Thread {
            while (true) {
                val raw = try {
                    outputQueue.take()
                } catch (_: InterruptedException) {
                    break
                }
                val sep = raw.indexOf('|')
                if (sep < 0) continue
                val tag = raw.substring(0, sep)
                val text = raw.substring(sep + 1)
                val event: Map<String, Any> = when (tag) {
                    "OUT" -> mapOf("type" to "out", "text" to text)
                    "ERR" -> mapOf("type" to "err", "text" to text)
                    // Partial line (a \r progress line or an input()
                    // prompt flushed without a newline): the console
                    // replaces its current partial line with this text
                    // instead of adding a new line (v1.0.4).
                    "OUTR" -> mapOf(
                        "type" to "out",
                        "text" to text,
                        "replace" to true
                    )
                    "ERRR" -> mapOf(
                        "type" to "err",
                        "text" to text,
                        "replace" to true
                    )
                    "EVT" -> {
                        val parts = text.split("|", limit = 2)
                        mapOf(
                            "type" to "event",
                            "name" to parts[0],
                            "text" to if (parts.size > 1) parts[1] else ""
                        )
                    }
                    else -> continue
                }
                val sink = eventSink
                if (sink != null) {
                    mainHandler.post {
                        try {
                            eventSink?.success(event)
                        } catch (_: Exception) {
                        }
                    }
                }
            }
        }.apply { isDaemon = true; start() }
    }
}
