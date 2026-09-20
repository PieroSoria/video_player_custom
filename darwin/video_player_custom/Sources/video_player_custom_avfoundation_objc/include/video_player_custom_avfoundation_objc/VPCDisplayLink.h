// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

@import Foundation;

#import "VPCViewProvider.h"

NS_ASSUME_NONNULL_BEGIN

// A cross-platform display link abstraction.
@protocol VPCDisplayLink <NSObject>

/// Whether the display link is currently running (i.e., firing events).
///
/// Defaults to NO.
@property(nonatomic, assign) BOOL running;

/// The time interval between screen refresh updates.
@property(nonatomic, readonly) CFTimeInterval duration;

@end

// An implementation of VPCDisplayLink using CADisplayLink.
API_AVAILABLE(ios(4.0), macos(14.0))
@interface VPCCADisplayLink : NSObject <VPCDisplayLink>

/// Initializes a display link that calls the given callback when fired.
///
/// The display link starts paused, so must be started, by setting 'running' to YES, before the
/// callback will fire.
- (instancetype)initWithViewProvider:(NSObject<VPCViewProvider> *)viewProvider
                            callback:(void (^)(void))callback NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

#if TARGET_OS_OSX
// An implementation of VPCDisplayLink using CVDisplayLink.
@interface VPCCoreVideoDisplayLink : NSObject <VPCDisplayLink>

/// Initializes a display link that calls the given callback when fired.
///
/// The display link starts paused, so must be started, by setting 'running' to YES, before the
/// callback will fire.
- (instancetype)initWithViewProvider:(NSObject<VPCViewProvider> *)viewProvider
                            callback:(void (^)(void))callback NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end
#endif

NS_ASSUME_NONNULL_END
