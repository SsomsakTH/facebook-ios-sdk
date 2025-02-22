# Copyright (c) Facebook, Inc. and its affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

XCODEBUILD_WARNINGS_ALLOWLIST = [
    "warning: Input PNG is already optimized for iPhone OS.  Copying source file to destination...",
    # Pika Warnings:
    # "warning: failed to load toolchain: could not find Info.plist in /Users/facebook/Library/Developer/Toolchains/pika-11-macos-noasserts.xctoolchain",
    # "warning: failed to load toolchain: could not find Info.plist in /Users/facebook/Library/Developer/Toolchains/pika-13-macos-noasserts.xctoolchain",
    "warning: failed to load toolchain: could not find Info.plist in /Users/facebook/Library/Developer/Toolchains/pika-",
    # Deprecation Warnings:
    "warning: 'AppLinkResolverRequestBuilder' is deprecated: `FBSDKAppLinkResolverRequestBuilder` is deprecated and will be removed in the next major release",
    "warning: Building targets in manual order is deprecated",
]
