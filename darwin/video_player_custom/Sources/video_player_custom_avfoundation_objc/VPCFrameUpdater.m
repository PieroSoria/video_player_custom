// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_custom_avfoundation_objc/VPCFrameUpdater.h"

@implementation VPCFrameUpdater
- (VPCFrameUpdater *)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry {
  NSAssert(self, @"super init cannot be nil");
  if (self == nil) return nil;
  _registry = registry;
  return self;
}

- (void)displayLinkFired {
  self.frameDuration = _displayLink.duration;
  [_registry textureFrameAvailable:_textureIdentifier];
}
@end
