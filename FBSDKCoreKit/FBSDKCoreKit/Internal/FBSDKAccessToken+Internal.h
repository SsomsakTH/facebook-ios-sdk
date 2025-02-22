/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <Foundation/Foundation.h>

#import "FBSDKAccessToken.h"
#import "FBSDKGraphRequestConnectionFactoryProtocol.h"
#import "FBSDKGraphRequestPiggybackManagerProviding.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBSDKAccessToken (Internal)

@property (class, nullable, nonatomic, copy) id<FBSDKGraphRequestConnectionFactory> graphRequestConnectionFactory;
@property (class, nullable, nonatomic) id<FBSDKGraphRequestPiggybackManagerProviding> graphRequestPiggybackManagerProvider;

+ (void)       configureWithTokenCache:(id<FBSDKTokenCaching>)tokenCache
         graphRequestConnectionFactory:(id<FBSDKGraphRequestConnectionFactory>)graphRequestConnectionFactory
  graphRequestPiggybackManagerProvider:(id<FBSDKGraphRequestPiggybackManagerProviding>)graphRequestPiggybackManagerProvider;

+ (void)resetTokenCache;

+ (void)setCurrentAccessToken:(nullable FBSDKAccessToken *)token
          shouldDispatchNotif:(BOOL)shouldDispatchNotif;

#if DEBUG && FBTEST
+ (void)resetClassDependencies;
#endif

@end

NS_ASSUME_NONNULL_END
