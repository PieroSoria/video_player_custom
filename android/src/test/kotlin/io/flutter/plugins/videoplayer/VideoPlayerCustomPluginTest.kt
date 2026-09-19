package io.flutter.plugins.videoplayer

import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugins.videoplayerpip.VideoPlayerPipPlugin
import org.junit.Test
import org.mockito.Mockito.mock
import org.mockito.Mockito.verify

class VideoPlayerCustomPluginTest {
    @Test
    fun forwardsActivityLifecycleToPip() {
        val playback = mock(VideoPlayerPlugin::class.java)
        val pip = mock(VideoPlayerPipPlugin::class.java)
        val binding = mock(ActivityPluginBinding::class.java)
        val plugin = VideoPlayerCustomPlugin(playback, pip)

        plugin.onAttachedToActivity(binding)
        plugin.onDetachedFromActivityForConfigChanges()
        plugin.onReattachedToActivityForConfigChanges(binding)
        plugin.onDetachedFromActivity()

        verify(pip).onAttachedToActivity(binding)
        verify(pip).onDetachedFromActivityForConfigChanges()
        verify(pip).onReattachedToActivityForConfigChanges(binding)
        verify(pip).onDetachedFromActivity()
    }
}
