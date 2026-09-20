// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "../video_player_custom_avfoundation_objc/include/video_player_custom_avfoundation_objc/VPCNativeVideoView.h"

#import <AVFoundation/AVFoundation.h>

@interface VPCPlayerView : UIView
@end

@implementation VPCPlayerView
+ (Class)layerClass {
  return [AVPlayerLayer class];
}

- (void)setPlayer:(AVPlayer *)player {
  [(AVPlayerLayer *)[self layer] setPlayer:player];
}
@end

@interface VPCNativeVideoView ()
@property(nonatomic) VPCPlayerView *playerView;
@end

@implementation VPCNativeVideoView
- (instancetype)initWithPlayer:(AVPlayer *)player {
  if (self = [super init]) {
    _playerView = [[VPCPlayerView alloc] init];
    [_playerView setPlayer:player];
  }
  return self;
}

- (VPCPlayerView *)view {
  return self.playerView;
}
@end
