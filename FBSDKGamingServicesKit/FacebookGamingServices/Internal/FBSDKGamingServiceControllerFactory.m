/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKGamingServiceControllerFactory.h"

#import <FacebookGamingServices/FacebookGamingServices-Swift.h>

#import "FBSDKGamingServiceController.h"

NS_ASSUME_NONNULL_BEGIN

@interface FBSDKGamingServiceController () <FBSDKGamingServiceController, FBSDKGamingServiceControllerCreating>
@end

@implementation FBSDKGamingServiceControllerFactory

- (nonnull id<FBSDKGamingServiceController>)createWithServiceType:(FBSDKGamingServiceType)serviceType
                                                       completion:(nonnull FBSDKGamingServiceResultCompletion)completion
                                                    pendingResult:(nullable id)pendingResult
{
  return [[FBSDKGamingServiceController alloc]
          initWithServiceType:serviceType
          completionHandler:completion
          pendingResult:pendingResult];
}

@end

NS_ASSUME_NONNULL_END
