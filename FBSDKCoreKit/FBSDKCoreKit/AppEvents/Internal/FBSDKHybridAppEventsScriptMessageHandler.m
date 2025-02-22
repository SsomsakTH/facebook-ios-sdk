/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#if !TARGET_OS_TV

#import "FBSDKHybridAppEventsScriptMessageHandler.h"

#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>

#import "FBSDKAppEvents+Internal.h"
#import "FBSDKEventLogging.h"

NSString *const FBSDKAppEventsWKWebViewMessagesPixelReferralParamKey = @"_fb_pixel_referral_id";

@protocol FBSDKEventLogging;
@class WKUserContentController;

@interface FBSDKHybridAppEventsScriptMessageHandler ()

@property (nonatomic) id<FBSDKEventLogging> eventLogger;

@end

@implementation FBSDKHybridAppEventsScriptMessageHandler

- (instancetype)init
{
  return [self initWithEventLogger:FBSDKAppEvents.shared];
}

- (instancetype)initWithEventLogger:(id<FBSDKEventLogging>)eventLogger
{
  if ((self = [super init])) {
    _eventLogger = eventLogger;
  }
  return self;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message
{
  if ([message.name isEqualToString:FBSDKAppEventsWKWebViewMessagesHandlerKey]) {
    NSDictionary<NSString *, id> *body = [FBSDKTypeUtility dictionaryValue:message.body];
    if (!body) {
      return;
    }
    NSString *event = body[FBSDKAppEventsWKWebViewMessagesEventKey];
    if ([event isKindOfClass:NSString.class] && (event.length > 0)) {
      NSString *stringedParams = [FBSDKTypeUtility stringValueOrNil:body[FBSDKAppEventsWKWebViewMessagesParamsKey]];
      NSMutableDictionary<NSString *, id> *params = nil;
      NSError *jsonParseError = nil;
      if (stringedParams) {
        params = [FBSDKTypeUtility JSONObjectWithData:[stringedParams dataUsingEncoding:NSUTF8StringEncoding]
                                              options:NSJSONReadingMutableContainers
                                                error:&jsonParseError
        ];
      }
      NSString *pixelID = body[FBSDKAppEventsWKWebViewMessagesPixelIDKey];
      if (pixelID == nil) {
        [FBSDKAppEventsUtility logAndNotify:@"Can't bridge an event without a referral Pixel ID. Check your webview Pixel configuration."];
        return;
      }
      if (jsonParseError != nil || ![params isKindOfClass:[NSDictionary<NSString *, id> class]] || params == nil) {
        [FBSDKAppEventsUtility logAndNotify:@"Could not find parameters for your Pixel request. Check your webview Pixel configuration."];
        params = [@{FBSDKAppEventsWKWebViewMessagesPixelReferralParamKey : pixelID} mutableCopy];
      } else {
        [FBSDKTypeUtility dictionary:params setObject:pixelID forKey:FBSDKAppEventsWKWebViewMessagesPixelReferralParamKey];
      }
      [self.eventLogger logInternalEvent:event
                              parameters:params
                      isImplicitlyLogged:NO];
    }
  }
}

@end

#endif
