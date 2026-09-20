// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

@import AVFoundation;

#import "VPCDisplayLink.h"
#import "VPCFrameUpdater.h"
#import "VPCVideoPlayer.h"
#import "VPCVideoPlayer_Internal.h"
#import "VPCViewProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// A subclass of VPCVideoPlayer that adds functionality related to texture-based view as a way of
/// displaying the video in the app. It manages the CALayer associated with the Flutter view,
/// updates frames, and handles display link callbacks.
/// If you need to display a video using platform view, use VPCVideoPlayer instead.
@interface VPCTextureBasedVideoPlayer : VPCVideoPlayer <FlutterTexture>
/// Initializes a new instance of VPCTextureBasedVideoPlayer with the given player item,
/// frame updater, display link, AV factory, and view provider.
- (instancetype)initWithPlayerItem:(NSObject<VPCAVPlayerItem> *)item
                      frameUpdater:(VPCFrameUpdater *)frameUpdater
                       displayLink:(NSObject<VPCDisplayLink> *)displayLink
                         avFactory:(id<VPCAVFactory>)avFactory
                      viewProvider:(NSObject<VPCViewProvider> *)viewProvider;

/// Sets the texture Identifier for the frame updater. This method should be called once the texture
/// identifier is obtained from the texture registry.
- (void)setTextureIdentifier:(int64_t)textureIdentifier;
@end

NS_ASSUME_NONNULL_END
