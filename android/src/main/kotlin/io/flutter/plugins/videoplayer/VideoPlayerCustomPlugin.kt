package io.flutter.plugins.videoplayer

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugins.videoplayerpip.VideoPlayerPipPlugin

/** Registers playback and PiP together and forwards the activity lifecycle. */
class VideoPlayerCustomPlugin internal constructor(
    private val playback: VideoPlayerPlugin,
    private val pip: VideoPlayerPipPlugin,
) : FlutterPlugin, ActivityAware {
    constructor() : this(VideoPlayerPlugin(), VideoPlayerPipPlugin())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        playback.onAttachedToEngine(binding)
        pip.onAttachedToEngine(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pip.onDetachedFromEngine(binding)
        playback.onDetachedFromEngine(binding)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) = pip.onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = pip.onDetachedFromActivityForConfigChanges()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = pip.onReattachedToActivityForConfigChanges(binding)
    override fun onDetachedFromActivity() = pip.onDetachedFromActivity()
}
