// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_custom_avfoundation_objc/VPCAVFactory.h"

@import AVFoundation;

@interface VPCDefaultAVAsset : NSObject <VPCAVAsset>
@property(nonatomic, readwrite) AVAsset *asset;
@end

@implementation VPCDefaultAVAsset
- (instancetype)initWithAsset:(AVAsset *)asset {
  self = [super init];
  if (self) {
    _asset = asset;
  }
  return self;
}

- (CMTime)duration {
  return self.asset.duration;
}

- (AVKeyValueStatus)statusOfValueForKey:(NSString *)key
                                  error:(NSError *_Nullable *_Nullable)outError {
  return [self.asset statusOfValueForKey:key error:outError];
}

- (void)loadValuesAsynchronouslyForKeys:(NSArray<NSString *> *)keys
                      completionHandler:(nullable void (^NS_SWIFT_SENDABLE)(void))handler {
  [self.asset loadValuesAsynchronouslyForKeys:keys completionHandler:handler];
}

- (NSArray<AVAssetTrack *> *)tracksWithMediaType:(NSString *)mediaType {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  return [self.asset tracksWithMediaType:mediaType];
#pragma clang diagnostic pop
}

- (void)loadTracksWithMediaType:(AVMediaType)mediaType
              completionHandler:(void (^NS_SWIFT_SENDABLE)(NSArray<AVAssetTrack *> *_Nullable,
                                                           NSError *_Nullable))completionHandler
    API_AVAILABLE(macos(12.0), ios(15.0)) {
  [self.asset loadTracksWithMediaType:mediaType completionHandler:completionHandler];
}

@end

#pragma mark -

@interface VPCDefaultAVPlayerItem : NSObject <VPCAVPlayerItem>
@property(nonatomic, readwrite) AVPlayerItem *playerItem;
@end

@implementation VPCDefaultAVPlayerItem
- (instancetype)initWithPlayerItem:(AVPlayerItem *)playerItem {
  self = [super init];
  if (self) {
    _playerItem = playerItem;
  }
  return self;
}

- (NSObject<VPCAVAsset> *)asset {
  return [[VPCDefaultAVAsset alloc] initWithAsset:self.playerItem.asset];
}

- (AVVideoComposition *)videoComposition {
  return self.playerItem.videoComposition;
}

- (void)setVideoComposition:(AVVideoComposition *)videoComposition {
  self.playerItem.videoComposition = videoComposition;
}
@end

#pragma mark -

@interface VPCDefaultAVPlayerItemVideoOutput : NSObject <VPCPixelBufferSource>
@property(nonatomic, readwrite) AVPlayerItemVideoOutput *videoOutput;
@end

@implementation VPCDefaultAVPlayerItemVideoOutput
- (instancetype)initWithOutputSettings:(NSDictionary<NSString *, id> *)outputSettings {
  self = [super init];
  if (self) {
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithOutputSettings:outputSettings];
  }
  return self;
}

- (CMTime)itemTimeForHostTime:(CFTimeInterval)hostTimeInSeconds {
  return [self.videoOutput itemTimeForHostTime:hostTimeInSeconds];
}

- (BOOL)hasNewPixelBufferForItemTime:(CMTime)itemTime {
  return [self.videoOutput hasNewPixelBufferForItemTime:itemTime];
}

- (nullable CVPixelBufferRef)copyPixelBufferForItemTime:(CMTime)itemTime
                                     itemTimeForDisplay:(nullable CMTime *)outItemTimeForDisplay
    CF_RETURNS_RETAINED {
  return [self.videoOutput copyPixelBufferForItemTime:itemTime
                                   itemTimeForDisplay:outItemTimeForDisplay];
}
@end

#pragma mark -

#if TARGET_OS_IOS
@interface VPCDefaultAVAudioSession : NSObject <VPCAVAudioSession>
@end

@implementation VPCDefaultAVAudioSession
- (AVAudioSessionCategory)category {
  return AVAudioSession.sharedInstance.category;
}

- (AVAudioSessionCategoryOptions)categoryOptions {
  return AVAudioSession.sharedInstance.categoryOptions;
}

- (BOOL)setCategory:(AVAudioSessionCategory)category
        withOptions:(AVAudioSessionCategoryOptions)options
              error:(NSError **)outError {
  return [AVAudioSession.sharedInstance setCategory:category withOptions:options error:outError];
}
@end
#endif

#pragma mark -

@implementation VPCDefaultAVFactory
- (NSObject<VPCAVAsset> *)URLAssetWithURL:(NSURL *)URL
                                  options:(nullable NSDictionary<NSString *, id> *)options {
  return [[VPCDefaultAVAsset alloc] initWithAsset:[AVURLAsset URLAssetWithURL:URL options:options]];
}

- (NSObject<VPCAVPlayerItem> *)playerItemWithAsset:(NSObject<VPCAVAsset> *)asset {
  // The default factory always vends VPCDefault* implementations, so it is safe to cast back.
  return [[VPCDefaultAVPlayerItem alloc]
      initWithPlayerItem:[AVPlayerItem playerItemWithAsset:((VPCDefaultAVAsset *)asset).asset]];
}

- (AVPlayer *)playerWithPlayerItem:(NSObject<VPCAVPlayerItem> *)playerItem {
  // The default factory always vends VPCDefault* implementations, so it is safe to cast back.
  return [AVPlayer playerWithPlayerItem:((VPCDefaultAVPlayerItem *)playerItem).playerItem];
}

- (NSObject<VPCPixelBufferSource> *)videoOutputWithOutputSettings:
    (NSDictionary<NSString *, id> *)outputSettings {
  return [[VPCDefaultAVPlayerItemVideoOutput alloc] initWithOutputSettings:outputSettings];
}

#if TARGET_OS_IOS
- (NSObject<VPCAVAudioSession> *)sharedAudioSession {
  return [[VPCDefaultAVAudioSession alloc] init];
}
#endif
@end
