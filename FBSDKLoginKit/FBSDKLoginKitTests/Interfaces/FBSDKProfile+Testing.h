/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

NS_ASSUME_NONNULL_BEGIN

@interface FBSDKProfile (Testing)

+ (void)setCurrentProfile:(nullable FBSDKProfile *)profile
   shouldPostNotification:(BOOL)shouldPostNotification;

@end

NS_ASSUME_NONNULL_END
