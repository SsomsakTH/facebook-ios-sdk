/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if !TARGET_OS_TV

#import <FBSDKCoreKit/FBSDKAccessTokenProtocols.h>
#import <FBSDKCoreKit/FBSDKProfile.h>

#import "FBSDKDataPersisting.h"

#if FBSDK_SWIFT_PACKAGE
 #import "FBSDKGraphRequest.h"
#else
 #import <FBSDKCoreKit/FBSDKGraphRequest.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@protocol FBSDKNotificationPosting;
@protocol FBSDKNotificationObserving;
@protocol FBSDKSettings;
@protocol FBSDKURLHosting;

typedef void (^FBSDKParseProfileBlock)(id result, FBSDKProfile *_Nonnull *_Nullable profileRef);

@interface FBSDKProfile (Internal)

+ (void)cacheProfile:(nullable FBSDKProfile *)profile;
+ (nullable FBSDKProfile *)fetchCachedProfile NS_SWIFT_NAME(fetchCachedProfile());

+ (NSURL *)imageURLForProfileID:(NSString *)profileId
                    PictureMode:(FBSDKProfilePictureMode)mode
                           size:(CGSize)size;

+ (void)loadProfileWithToken:(FBSDKAccessToken *)token
                graphRequest:(id<FBSDKGraphRequest>)request
                  completion:(FBSDKProfileBlock)completion
                  parseBlock:(FBSDKParseProfileBlock)parseBlock;

+ (void)loadProfileWithToken:(FBSDKAccessToken *)token completion:(_Nullable FBSDKProfileBlock)completion;

+ (void)observeChangeAccessTokenChange:(NSNotification *)notification;

// UNCRUSTIFY_FORMAT_OFF
+ (void)configureWithStore:(id<FBSDKDataPersisting>)store
       accessTokenProvider:(Class<FBSDKAccessTokenProviding>)accessTokenProvider
        notificationCenter:(id<FBSDKNotificationPosting, FBSDKNotificationObserving>)notificationCenter
                  settings:(id<FBSDKSettings>)settings
                 urlHoster:(id<FBSDKURLHosting>)urlHoster
NS_SWIFT_NAME(configure(store:accessTokenProvider:notificationCenter:settings:urlHoster:));
// UNCRUSTIFY_FORMAT_ON

@end

NS_ASSUME_NONNULL_END

#endif
