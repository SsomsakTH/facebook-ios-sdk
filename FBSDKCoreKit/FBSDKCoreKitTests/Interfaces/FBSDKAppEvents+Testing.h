/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKAppEvents+Internal.h"
#import "FBSDKAppEventsFlushReason.h"

NS_ASSUME_NONNULL_BEGIN

@protocol FBSDKSwizzling;
@protocol FBSDKAtePublishing;

@interface FBSDKAppEvents (Testing)

@property (class, nonatomic) FBSDKAppEvents *shared;

@property (nonatomic) UIApplicationState applicationState;
@property (nonatomic) FBSDKAppEventsFlushBehavior flushBehavior;
@property (nullable, nonatomic) id<FBSDKAtePublishing> atePublisher;
@property (nonatomic, copy) NSString *pushNotificationsDeviceTokenString;
@property (nullable, nonatomic) Class<FBSDKSwizzling> swizzler;

- (void)logImplicitEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<NSString *, id> *)parameters
             accessToken:(FBSDKAccessToken *)accessToken;
- (void)logInternalEvent:(FBSDKAppEventName)eventName
      isImplicitlyLogged:(BOOL)isImplicitlyLogged;
- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(double)valueToSum
      isImplicitlyLogged:(BOOL)isImplicitlyLogged;

- (instancetype)initWithFlushBehavior:(FBSDKAppEventsFlushBehavior)flushBehavior
                 flushPeriodInSeconds:(int)flushPeriodInSeconds;
- (void)publishATE;
+ (void)setSettings:(id<FBSDKSettings>)settings;
+ (void)reset;

- (void)publishInstall;
- (void)fetchServerConfiguration:(nullable FBSDKCodeBlock)callback;
- (void)instanceLogEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<NSString *, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
             accessToken:(nullable FBSDKAccessToken *)accessToken;
- (void)applicationDidBecomeActive;
- (void)applicationMovingFromActiveStateOrTerminating;

@end

NS_ASSUME_NONNULL_END
