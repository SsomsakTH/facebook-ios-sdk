/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSDKAppEvents+Internal.h"

#import <StoreKit/StoreKit.h>
#import <UIKit/UIApplication.h>

#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>
#import <objc/runtime.h>

#import "FBSDKAccessToken.h"
#import "FBSDKAdvertiserIDProviding.h"
#import "FBSDKAppEventName.h"
#import "FBSDKAppEventName+Internal.h"
#import "FBSDKAppEventParameterName+Internal.h"
#import "FBSDKAppEventParameterProduct.h"
#import "FBSDKAppEventParameterProduct+Internal.h"
#import "FBSDKAppEventUserDataType.h"
#import "FBSDKAppEventsConfiguration.h"
#import "FBSDKAppEventsConfigurationProviding.h"
#import "FBSDKAppEventsDeviceInfo.h"
#import "FBSDKAppEventsParameterProcessing.h"
#import "FBSDKAppEventsReporter.h"
#import "FBSDKAppEventsState.h"
#import "FBSDKAppEventsStatePersisting.h"
#import "FBSDKAppEventsStateProviding.h"
#import "FBSDKAppEventsUtility.h"
#import "FBSDKAtePublisherCreating.h"
#import "FBSDKAtePublishing.h"
#import "FBSDKCodelessIndexing.h"
#import "FBSDKConstants.h"
#import "FBSDKDataPersisting.h"
#import "FBSDKDynamicFrameworkLoader.h"
#import "FBSDKEventsProcessing.h"
#import "FBSDKFeatureChecking.h"
#import "FBSDKGateKeeperManaging.h"
#import "FBSDKGraphRequestFactoryProtocol.h"
#import "FBSDKInternalUtility+Internal.h"
#import "FBSDKLogger.h"
#import "FBSDKLogging.h"
#import "FBSDKMetadataIndexing.h"
#import "FBSDKPaymentObserving.h"
#import "FBSDKServerConfiguration.h"
#import "FBSDKServerConfigurationProviding.h"
#import "FBSDKSettingsProtocol.h"
#import "FBSDKSwizzling.h"
#import "FBSDKTimeSpentRecordingCreating.h"
#import "FBSDKUserDataPersisting.h"
#import "FBSDKUtility.h"

#if !TARGET_OS_TV

 #import <FBAEMKit/FBAEMKit.h>

 #import "FBSDKEventBindingManager.h"
 #import "FBSDKEventProcessing.h"
 #import "FBSDKHybridAppEventsScriptMessageHandler.h"
 #import "FBSDKIntegrityParametersProcessorProvider.h"

#endif

// Event parameter values internal to this file

NSString *const FBSDKGateKeeperAppEventsKillSwitch = @"app_events_killswitch";

NSString *const FBSDKAppEventsOverrideAppIDBundleKey = @"FacebookLoggingOverrideAppID";

//
// Push Notifications
//
// Activities Endpoint Parameter
static NSString *const FBSDKActivitesParameterPushDeviceToken = @"device_token";
// Event Parameter
// Payload Keys
static NSString *const FBSDKAppEventsPushPayloadKey = @"fb_push_payload";
static NSString *const FBSDKAppEventsPushPayloadCampaignKey = @"campaign";

//
// Augmentation of web browser constants
//
NSString *const FBSDKAppEventsWKWebViewMessagesPixelIDKey = @"pixelID";
NSString *const FBSDKAppEventsWKWebViewMessagesHandlerKey = @"fbmqHandler";
NSString *const FBSDKAppEventsWKWebViewMessagesEventKey = @"event";
NSString *const FBSDKAppEventsWKWebViewMessagesParamsKey = @"params";
NSString *const FBSDKAPPEventsWKWebViewMessagesProtocolKey = @"fbmq-0.1";

#define NUM_LOG_EVENTS_TO_TRY_TO_FLUSH_AFTER 100
#define FLUSH_PERIOD_IN_SECONDS 15
#define USER_ID_USER_DEFAULTS_KEY @"com.facebook.sdk.appevents.userid"

#define FBUnityUtilityClassName "FBUnityUtility"
#define FBUnityUtilityUpdateBindingsSelector @"triggerUpdateBindings:"

static FBSDKAppEvents *_shared = nil;
static NSString *g_overrideAppID = nil;
static BOOL g_explicitEventsLoggedYet;
static Class<FBSDKGateKeeperManaging> g_gateKeeperManager;
static id<FBSDKAppEventsConfigurationProviding> g_appEventsConfigurationProvider;
static id<FBSDKServerConfigurationProviding> g_serverConfigurationProvider;
static id<FBSDKGraphRequestFactory> g_graphRequestFactory;
static id<FBSDKFeatureChecking> g_featureChecker;
static Class<FBSDKLogging> g_logger;
static id<FBSDKSettings> g_settings;
static id<FBSDKPaymentObserving> g_paymentObserver;
static id<FBSDKAppEventsStatePersisting> g_appEventsStateStore;
static id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing> g_eventDeactivationParameterProcessor;
static id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing> g_restrictiveDataFilterParameterProcessor;

@interface FBSDKAppEvents ()

@property (nullable, nonatomic) id<FBSDKDataPersisting> store;
@property (nonatomic) UIApplicationState applicationState;
@property (nullable, nonatomic, copy) NSString *pushNotificationsDeviceTokenString;
@property (nonatomic) dispatch_source_t flushTimer;
@property (nonatomic) id<FBSDKAtePublishing> atePublisher;
@property (nullable, nonatomic) Class<FBSDKSwizzling> swizzler;
@property (nullable, nonatomic) id<FBSDKSourceApplicationTracking, FBSDKTimeSpentRecording> timeSpentRecorder;
@property (nonatomic) id<FBSDKAppEventsStateProviding> appEventsStateProvider;
@property (nonatomic) id<FBSDKAdvertiserIDProviding> advertiserIDProvider;
@property (nonatomic) id<FBSDKAtePublisherCreating> atePublisherFactory;
@property (nonatomic) id<FBSDKUserDataPersisting> userDataStore;
@property (nonatomic) BOOL isConfigured;

#if !TARGET_OS_TV
@property (nonatomic) id<FBSDKEventProcessing, FBSDKIntegrityParametersProcessorProvider> onDeviceMLModelManager;
@property (nonatomic) id<FBSDKMetadataIndexing> metadataIndexer;
@property (nonatomic) id<FBSDKAppEventsReporter> skAdNetworkReporter;
@property (nonatomic) FBSDKEventBindingManager *eventBindingManager;
@property (nonatomic) Class<FBSDKCodelessIndexing> codelessIndexer;
#endif

@property (nonatomic) FBSDKServerConfiguration *serverConfiguration;
@property (nonatomic) FBSDKAppEventsState *appEventsState;
@property (nonatomic) BOOL _isUnityInitialized; // not publicly readable

@end

@implementation FBSDKAppEvents
{
  NSString *_userID;
}

#pragma mark - Object Lifecycle

+ (void)initialize
{
  if (self == FBSDKAppEvents.class) {
    g_overrideAppID = [[NSBundle.mainBundle objectForInfoDictionaryKey:FBSDKAppEventsOverrideAppIDBundleKey] copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^(void) {
      // Forces reading or creating of `anonymousID` used by this type
      [FBSDKBasicUtility anonymousID];
    });
  }
}

- (instancetype)init
{
  return [self initWithFlushBehavior:FBSDKAppEventsFlushBehaviorAuto
                flushPeriodInSeconds:FLUSH_PERIOD_IN_SECONDS];
}

- (instancetype)initWithFlushBehavior:(FBSDKAppEventsFlushBehavior)flushBehavior
                 flushPeriodInSeconds:(int)flushPeriodInSeconds
{
  self = [super init];
  if (self) {
    _flushBehavior = flushBehavior;

    __weak FBSDKAppEvents *weakSelf = self;
    self.flushTimer = [FBSDKUtility startGCDTimerWithInterval:flushPeriodInSeconds
                                                        block:^{
                                                          [weakSelf flushTimerFired:nil];
                                                        }];

    self.applicationState = UIApplicationStateInactive;
  }

  return self;
}

- (void)startObservingApplicationLifecycleNotifications
{
  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationMovingFromActiveStateOrTerminating)
   name:UIApplicationWillResignActiveNotification
   object:NULL];

  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationMovingFromActiveStateOrTerminating)
   name:UIApplicationWillTerminateNotification
   object:NULL];

  [NSNotificationCenter.defaultCenter
   addObserver:self
   selector:@selector(applicationDidBecomeActive)
   name:UIApplicationDidBecomeActiveNotification
   object:NULL];
}

- (void)dealloc
{
  [FBSDKUtility stopGCDTimer:self.flushTimer];
}

#pragma mark - Public Methods

+ (void)logEvent:(FBSDKAppEventName)eventName
{
  [self.shared logEvent:eventName];
}

- (void)logEvent:(FBSDKAppEventName)eventName
{
  [self logEvent:eventName parameters:@{}];
}

+ (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(double)valueToSum
{
  [self.shared logEvent:eventName valueToSum:valueToSum];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(double)valueToSum
{
  [self logEvent:eventName
      valueToSum:valueToSum
      parameters:@{}];
}

+ (void)logEvent:(FBSDKAppEventName)eventName
      parameters:(nullable NSDictionary<NSString *, id> *)parameters
{
  [self.shared logEvent:eventName parameters:parameters];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      parameters:(nullable NSDictionary<NSString *, id> *)parameters
{
  [self logEvent:eventName
      valueToSum:nil
      parameters:parameters
     accessToken:nil];
}

+ (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(double)valueToSum
      parameters:(nullable NSDictionary<NSString *, id> *)parameters
{
  [self.shared logEvent:eventName
             valueToSum:valueToSum
             parameters:parameters];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(double)valueToSum
      parameters:(nullable NSDictionary<NSString *, id> *)parameters
{
  [self logEvent:eventName
      valueToSum:@(valueToSum)
      parameters:parameters
     accessToken:nil];
}

+ (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(NSNumber *)valueToSum
      parameters:(nullable NSDictionary<NSString *, id> *)parameters
     accessToken:(FBSDKAccessToken *)accessToken
{
  [self.shared logEvent:eventName
             valueToSum:valueToSum
             parameters:parameters
            accessToken:accessToken];
}

- (void)logEvent:(FBSDKAppEventName)eventName
      valueToSum:(NSNumber *)valueToSum
      parameters:(nullable NSDictionary<NSString *, id> *)parameters
     accessToken:(FBSDKAccessToken *)accessToken
{
  [self instanceLogEvent:eventName
              valueToSum:valueToSum
              parameters:parameters
      isImplicitlyLogged:[parameters[FBSDKAppEventParameterNameImplicitlyLogged] boolValue]
             accessToken:accessToken];
}

+ (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
{
  [self.shared logPurchase:purchaseAmount
                  currency:currency
                parameters:@{}];
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
{
  [self logPurchase:purchaseAmount
           currency:currency
         parameters:@{}];
}

+ (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
         parameters:(nullable NSDictionary<NSString *, id> *)parameters
{
  [self.shared logPurchase:purchaseAmount
                  currency:currency
                parameters:parameters];
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
         parameters:(nullable NSDictionary<NSString *, id> *)parameters
{
  [self logPurchase:purchaseAmount
           currency:currency
         parameters:parameters
        accessToken:nil];
}

+ (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
         parameters:(nullable NSDictionary<NSString *, id> *)parameters
        accessToken:(nullable FBSDKAccessToken *)accessToken
{
  [self.shared logPurchase:purchaseAmount
                  currency:currency
                parameters:parameters
               accessToken:accessToken];
}

- (void)logPurchase:(double)purchaseAmount
           currency:(NSString *)currency
         parameters:(nullable NSDictionary<NSString *, id> *)parameters
        accessToken:(nullable FBSDKAccessToken *)accessToken
{
  [self validateConfiguration];

  // A purchase event is just a regular logged event with a given event name
  // and treating the currency value as going into the parameters dictionary.
  NSDictionary<NSString *, id> *newParameters;
  if (!parameters) {
    newParameters = @{ FBSDKAppEventParameterNameCurrency : currency };
  } else {
    newParameters = [NSMutableDictionary dictionaryWithDictionary:parameters];
    [newParameters setValue:currency forKey:FBSDKAppEventParameterNameCurrency];
  }

  [self logEvent:FBSDKAppEventNamePurchased
      valueToSum:@(purchaseAmount)
      parameters:newParameters
     accessToken:accessToken];

  // Unless the behavior is set to only allow explicit flushing, we go ahead and flush, since purchase events
  // are relatively rare and relatively high value and worth getting across on wire right away.
  if (FBSDKAppEvents.shared.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
    [FBSDKAppEvents.shared flushForReason:FBSDKAppEventsFlushReasonEagerlyFlushingEvent];
  }
}

/*
 * Push Notifications Logging
 */

+ (void)logPushNotificationOpen:(NSDictionary<NSString *, id> *)payload
{
  [self.shared logPushNotificationOpen:payload action:@""];
}

- (void)logPushNotificationOpen:(NSDictionary<NSString *, id> *)payload
{
  [self logPushNotificationOpen:payload action:@""];
}

+ (void)logPushNotificationOpen:(NSDictionary<NSString *, id> *)payload action:(NSString *)action
{
  [self.shared logPushNotificationOpen:payload action:action];
}

- (void)logPushNotificationOpen:(NSDictionary<NSString *, id> *)payload action:(NSString *)action
{
  [self validateConfiguration];

  NSDictionary<NSString *, id> *facebookPayload = payload[FBSDKAppEventsPushPayloadKey];
  if (!facebookPayload) {
    return;
  }
  NSString *campaign = facebookPayload[FBSDKAppEventsPushPayloadCampaignKey];
  if (campaign.length == 0) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                        logEntry:@"Malformed payload specified for logging a push notification open."];
    return;
  }

  NSMutableDictionary<NSString *, id> *parameters = [@{FBSDKAppEventParameterNamePushCampaign : campaign} mutableCopy];
  if (action && action.length > 0) {
    [FBSDKTypeUtility dictionary:parameters setObject:action forKey:FBSDKAppEventParameterNamePushAction];
  }

  [self logEvent:FBSDKAppEventNamePushOpened parameters:parameters];
}

+ (void)logProductItem:(NSString *)itemID
          availability:(FBSDKProductAvailability)availability
             condition:(FBSDKProductCondition)condition
           description:(NSString *)description
             imageLink:(NSString *)imageLink
                  link:(NSString *)link
                 title:(NSString *)title
           priceAmount:(double)priceAmount
              currency:(NSString *)currency
                  gtin:(nullable NSString *)gtin
                   mpn:(nullable NSString *)mpn
                 brand:(nullable NSString *)brand
            parameters:(nullable NSDictionary<NSString *, id> *)parameters
{
  [self.shared logProductItem:itemID
                 availability:availability
                    condition:condition
                  description:description
                    imageLink:imageLink
                         link:link
                        title:title
                  priceAmount:priceAmount
                     currency:currency
                         gtin:gtin
                          mpn:mpn
                        brand:brand
                   parameters:parameters];
}

- (void)logProductItem:(NSString *)itemID
          availability:(FBSDKProductAvailability)availability
             condition:(FBSDKProductCondition)condition
           description:(NSString *)description
             imageLink:(NSString *)imageLink
                  link:(NSString *)link
                 title:(NSString *)title
           priceAmount:(double)priceAmount
              currency:(NSString *)currency
                  gtin:(nullable NSString *)gtin
                   mpn:(nullable NSString *)mpn
                 brand:(nullable NSString *)brand
            parameters:(nullable NSDictionary<NSString *, id> *)parameters
{
  [self validateConfiguration];

  if (itemID == nil) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                        logEntry:@"itemID cannot be null"];
    return;
  } else if (description == nil) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                        logEntry:@"description cannot be null"];
    return;
  } else if (imageLink == nil) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                        logEntry:@"imageLink cannot be null"];
    return;
  } else if (link == nil) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                        logEntry:@"link cannot be null"];
    return;
  } else if (title == nil) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                        logEntry:@"title cannot be null"];
    return;
  } else if (currency == nil) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                        logEntry:@"currency cannot be null"];
    return;
  } else if (gtin == nil && mpn == nil && brand == nil) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                        logEntry:@"Either gtin, mpn or brand is required"];
    return;
  }

  NSMutableDictionary<NSString *, id> *dict = [NSMutableDictionary dictionary];
  if (nil != parameters) {
    dict.valuesForKeysWithDictionary = parameters;
  }

  [FBSDKTypeUtility dictionary:dict setObject:itemID forKey:FBSDKAppEventParameterProductItemID];

  NSString *avail = nil;
  switch (availability) {
    case FBSDKProductAvailabilityInStock:
      avail = @"IN_STOCK"; break;
    case FBSDKProductAvailabilityOutOfStock:
      avail = @"OUT_OF_STOCK"; break;
    case FBSDKProductAvailabilityPreOrder:
      avail = @"PREORDER"; break;
    case FBSDKProductAvailabilityAvailableForOrder:
      avail = @"AVALIABLE_FOR_ORDER"; break;
    case FBSDKProductAvailabilityDiscontinued:
      avail = @"DISCONTINUED"; break;
  }
  if (avail) {
    [FBSDKTypeUtility dictionary:dict setObject:avail forKey:FBSDKAppEventParameterProductAvailability];
  }

  NSString *cond = nil;
  switch (condition) {
    case FBSDKProductConditionNew:
      cond = @"NEW"; break;
    case FBSDKProductConditionRefurbished:
      cond = @"REFURBISHED"; break;
    case FBSDKProductConditionUsed:
      cond = @"USED"; break;
  }
  if (cond) {
    [FBSDKTypeUtility dictionary:dict setObject:cond forKey:FBSDKAppEventParameterProductCondition];
  }

  [FBSDKTypeUtility dictionary:dict setObject:description forKey:FBSDKAppEventParameterProductDescription];
  [FBSDKTypeUtility dictionary:dict setObject:imageLink forKey:FBSDKAppEventParameterProductImageLink];
  [FBSDKTypeUtility dictionary:dict setObject:link forKey:FBSDKAppEventParameterProductLink];
  [FBSDKTypeUtility dictionary:dict setObject:title forKey:FBSDKAppEventParameterProductTitle];
  [FBSDKTypeUtility dictionary:dict setObject:[NSString stringWithFormat:@"%.3lf", priceAmount] forKey:FBSDKAppEventParameterProductPriceAmount];
  [FBSDKTypeUtility dictionary:dict setObject:currency forKey:FBSDKAppEventParameterProductPriceCurrency];
  if (gtin) {
    [FBSDKTypeUtility dictionary:dict setObject:gtin forKey:FBSDKAppEventParameterProductGTIN];
  }
  if (mpn) {
    [FBSDKTypeUtility dictionary:dict setObject:mpn forKey:FBSDKAppEventParameterProductMPN];
  }
  if (brand) {
    [FBSDKTypeUtility dictionary:dict setObject:brand forKey:FBSDKAppEventParameterProductBrand];
  }

  [self logEvent:FBSDKAppEventNameProductCatalogUpdate
      parameters:dict];
}

+ (void)activateApp
{
  [self.shared activateApp];
}

- (void)activateApp
{
  [self validateConfiguration];

  [FBSDKAppEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  // Fetch app settings and register for transaction notifications only if app supports implicit purchase
  // events
  [self publishInstall];
  [self fetchServerConfiguration:NULL];

  // Restore time spent data, indicating that we're being called from "activateApp", which will,
  // when appropriate, result in logging an "activated app" and "deactivated app" (for the
  // previous session) App Event.
  [self.timeSpentRecorder restore:YES];
}

+ (void)setPushNotificationsDeviceToken:(nullable NSData *)deviceToken
{
  [self.shared setPushNotificationsDeviceToken:deviceToken];
}

- (void)setPushNotificationsDeviceToken:(nullable NSData *)deviceToken
{
  [self validateConfiguration];

  NSString *deviceTokenString = [FBSDKInternalUtility.sharedUtility hexadecimalStringFromData:deviceToken];
  if (deviceTokenString) {
    self.pushNotificationsDeviceTokenString = deviceTokenString;
  }
}

+ (void)setPushNotificationsDeviceTokenString:(nullable NSString *)deviceTokenString
{
  [self.shared setPushNotificationsDeviceTokenString:deviceTokenString];
}

- (void)setPushNotificationsDeviceTokenString:(nullable NSString *)deviceTokenString
{
  [self validateConfiguration];

  if (deviceTokenString == nil) {
    _pushNotificationsDeviceTokenString = nil;
    return;
  }

  NSString *currentToken = self.pushNotificationsDeviceTokenString ?: @"";

  if (![deviceTokenString isEqualToString:currentToken]) {
    _pushNotificationsDeviceTokenString = deviceTokenString;

    [self logEvent:FBSDKAppEventNamePushTokenObtained];

    // Unless the behavior is set to only allow explicit flushing, we go ahead and flush the event
    if (self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
      [self flushForReason:FBSDKAppEventsFlushReasonEagerlyFlushingEvent];
    }
  }
}

+ (FBSDKAppEventsFlushBehavior)flushBehavior
{
  return self.shared.flushBehavior;
}

+ (void)setFlushBehavior:(FBSDKAppEventsFlushBehavior)flushBehavior
{
  self.shared.flushBehavior = flushBehavior;
}

+ (nullable NSString *)loggingOverrideAppID
{
  return self.shared.loggingOverrideAppID;
}

+ (void)setLoggingOverrideAppID:(nullable NSString *)appID
{
  self.shared.loggingOverrideAppID = appID;
}

- (nullable NSString *)loggingOverrideAppID
{
  return g_overrideAppID;
}

- (void)setLoggingOverrideAppID:(nullable NSString *)appID
{
  [self validateConfiguration];

  if (![g_overrideAppID isEqualToString:appID]) {
    if (g_explicitEventsLoggedYet) {
      [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors
                          logEntry:@"AppEvents.shared.loggingOverrideAppID should only be set prior to any events being logged."];
    }
    g_overrideAppID = appID;
  }
}

+ (void)flush
{
  [self.shared flush];
}

- (void)flush
{
  [self validateConfiguration];
  [self flushForReason:FBSDKAppEventsFlushReasonExplicit];
}

+ (nullable NSString *)userID
{
  return self.shared.userID;
}

- (nullable NSString *)userID
{
  [self validateConfiguration];
  return [_userID copy];
}

+ (void)setUserID:(nullable NSString *)userID
{
  self.shared.userID = userID;
}

- (void)setUserID:(nullable NSString *)userID
{
  [self validateConfiguration];
  _userID = [userID copy];
  [self.store setObject:userID forKey:USER_ID_USER_DEFAULTS_KEY];
}

+ (void)clearUserID
{
  self.shared.userID = nil;
}

+ (void)setUserEmail:(nullable NSString *)email
           firstName:(nullable NSString *)firstName
            lastName:(nullable NSString *)lastName
               phone:(nullable NSString *)phone
         dateOfBirth:(nullable NSString *)dateOfBirth
              gender:(nullable NSString *)gender
                city:(nullable NSString *)city
               state:(nullable NSString *)state
                 zip:(nullable NSString *)zip
             country:(nullable NSString *)country
{
  [self.shared setUserEmail:email
                  firstName:firstName
                   lastName:lastName
                      phone:phone
                dateOfBirth:dateOfBirth
                     gender:gender
                       city:city
                      state:state
                        zip:zip
                    country:country];
}

- (void)setUserEmail:(nullable NSString *)email
           firstName:(nullable NSString *)firstName
            lastName:(nullable NSString *)lastName
               phone:(nullable NSString *)phone
         dateOfBirth:(nullable NSString *)dateOfBirth
              gender:(nullable NSString *)gender
                city:(nullable NSString *)city
               state:(nullable NSString *)state
                 zip:(nullable NSString *)zip
             country:(nullable NSString *)country
{
  [self.userDataStore setUserEmail:email
                         firstName:firstName
                          lastName:lastName
                             phone:phone
                       dateOfBirth:dateOfBirth
                            gender:gender
                              city:city
                             state:state
                               zip:zip
                           country:country
                        externalId:nil];
}

+ (NSString *)getUserData
{
  return [self.shared getUserData];
}

- (nullable NSString *)getUserData
{
  return [self.userDataStore getUserData];
}

+ (void)clearUserData
{
  [self.shared clearUserData];
}

- (void)clearUserData
{
  [self.userDataStore clearUserData];
}

+ (void)setUserData:(nullable NSString *)data
            forType:(FBSDKAppEventUserDataType)type
{
  [self.shared setUserData:data forType:type];
}

- (void)setUserData:(nullable NSString *)data
            forType:(FBSDKAppEventUserDataType)type
{
  [self.userDataStore setUserData:data forType:type];
}

+ (void)clearUserDataForType:(FBSDKAppEventUserDataType)type
{
  [self.shared clearUserDataForType:type];
}

- (void)clearUserDataForType:(FBSDKAppEventUserDataType)type
{
  [self.userDataStore clearUserDataForType:type];
}

+ (NSString *)anonymousID
{
  return self.shared.anonymousID;
}

- (NSString *)anonymousID
{
  return [FBSDKBasicUtility anonymousID];
}

#if !TARGET_OS_TV

+ (void)augmentHybridWKWebView:(WKWebView *)webView
{
  [self.shared augmentHybridWebView:webView];
}

- (void)augmentHybridWebView:(WKWebView *)webView
{
  [self validateConfiguration];

  if ([webView isKindOfClass:WKWebView.class]) {
    if (WKUserScript.class != nil) {
      WKUserContentController *controller = webView.configuration.userContentController;
      FBSDKHybridAppEventsScriptMessageHandler *scriptHandler = [FBSDKHybridAppEventsScriptMessageHandler new];
      [controller addScriptMessageHandler:scriptHandler name:FBSDKAppEventsWKWebViewMessagesHandlerKey];

      NSString *js = [NSString stringWithFormat:@"window.fbmq_%@={'sendEvent': function(pixel_id,event_name,custom_data){var msg={\"%@\":pixel_id, \"%@\":event_name,\"%@\":custom_data};window.webkit.messageHandlers[\"%@\"].postMessage(msg);}, 'getProtocol':function(){return \"%@\";}}",
                      self.appID,
                      FBSDKAppEventsWKWebViewMessagesPixelIDKey,
                      FBSDKAppEventsWKWebViewMessagesEventKey,
                      FBSDKAppEventsWKWebViewMessagesParamsKey,
                      FBSDKAppEventsWKWebViewMessagesHandlerKey,
                      FBSDKAPPEventsWKWebViewMessagesProtocolKey
      ];

      [controller addUserScript:[[WKUserScript.class alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
  } else {
    [FBSDKAppEventsUtility logAndNotify:@"You must call augmentHybridWebView with WebKit linked to your project and a WKWebView instance"];
  }
}

#endif

+ (void)setIsUnityInit:(BOOL)isUnityInitialized
{
  [FBSDKAppEvents.shared setIsUnityInitialized:isUnityInitialized];
}

- (void)setIsUnityInitialized:(BOOL)isUnityInitialized
{
  self._isUnityInitialized = isUnityInitialized;
}

+ (void)sendEventBindingsToUnity
{
  [self.shared sendEventBindingsToUnity];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
- (void)sendEventBindingsToUnity
{
  [self validateConfiguration];

  // Send event bindings to Unity only Unity is initialized
  if (self._isUnityInitialized
      && self.serverConfiguration
      && [FBSDKTypeUtility isValidJSONObject:self.serverConfiguration.eventBindings]
  ) {
    NSData *jsonData = [FBSDKTypeUtility dataWithJSONObject:self.serverConfiguration.eventBindings ?: @""
                                                    options:0
                                                      error:nil];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    Class classFBUnityUtility = objc_lookUpClass(FBUnityUtilityClassName);
    SEL updateBindingsSelector = NSSelectorFromString(FBUnityUtilityUpdateBindingsSelector);
    if ([classFBUnityUtility respondsToSelector:updateBindingsSelector]) {
      [classFBUnityUtility performSelector:updateBindingsSelector withObject:jsonString];
    }
  }
}

#pragma clang diagnostic pop

#pragma mark - Internal Methods

- (void)   configureWithGateKeeperManager:(Class<FBSDKGateKeeperManaging>)gateKeeperManager
           appEventsConfigurationProvider:(id<FBSDKAppEventsConfigurationProviding>)appEventsConfigurationProvider
              serverConfigurationProvider:(id<FBSDKServerConfigurationProviding>)serverConfigurationProvider
                      graphRequestFactory:(id<FBSDKGraphRequestFactory>)provider
                           featureChecker:(id<FBSDKFeatureChecking>)featureChecker
                                    store:(id<FBSDKDataPersisting>)store
                                   logger:(Class<FBSDKLogging>)logger
                                 settings:(id<FBSDKSettings>)settings
                          paymentObserver:(id<FBSDKPaymentObserving>)paymentObserver
                 timeSpentRecorderFactory:(id<FBSDKTimeSpentRecordingCreating>)timeSpentRecorderFactory
                      appEventsStateStore:(id<FBSDKAppEventsStatePersisting>)appEventsStateStore
      eventDeactivationParameterProcessor:(id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing>)eventDeactivationParameterProcessor
  restrictiveDataFilterParameterProcessor:(id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing>)restrictiveDataFilterParameterProcessor
                      atePublisherFactory:(id<FBSDKAtePublisherCreating>)atePublisherFactory
                   appEventsStateProvider:(id<FBSDKAppEventsStateProviding>)appEventsStateProvider
                                 swizzler:(Class<FBSDKSwizzling>)swizzler
                     advertiserIDProvider:(id<FBSDKAdvertiserIDProviding>)advertiserIDProvider
                            userDataStore:(id<FBSDKUserDataPersisting>)userDataStore
{
  FBSDKAppEvents.appEventsConfigurationProvider = appEventsConfigurationProvider;
  FBSDKAppEvents.serverConfigurationProvider = serverConfigurationProvider;
  g_gateKeeperManager = gateKeeperManager;
  g_logger = logger;
  FBSDKAppEvents.graphRequestFactory = provider;
  FBSDKAppEvents.featureChecker = featureChecker;
  g_settings = settings;
  g_paymentObserver = paymentObserver;
  g_appEventsStateStore = appEventsStateStore;
  g_eventDeactivationParameterProcessor = eventDeactivationParameterProcessor;
  g_restrictiveDataFilterParameterProcessor = restrictiveDataFilterParameterProcessor;
  self.swizzler = swizzler;
  self.store = store;
  self.atePublisherFactory = atePublisherFactory;
  self.atePublisher = [self.atePublisherFactory createPublisherWithAppID:self.appID];
  self.timeSpentRecorder = [timeSpentRecorderFactory createTimeSpentRecorder];
  self.appEventsStateProvider = appEventsStateProvider;
  self.advertiserIDProvider = advertiserIDProvider;
  self.userDataStore = userDataStore;

  self.isConfigured = YES;

  self.userID = [store stringForKey:USER_ID_USER_DEFAULTS_KEY];
}

+ (void)setFeatureChecker:(id<FBSDKFeatureChecking>)checker
{
  if (g_featureChecker != checker) {
    g_featureChecker = checker;
  }
}

+ (void)setGraphRequestFactory:(id<FBSDKGraphRequestFactory>)provider
{
  if (g_graphRequestFactory != provider) {
    g_graphRequestFactory = provider;
  }
}

+ (void)setAppEventsConfigurationProvider:(id<FBSDKAppEventsConfigurationProviding>)provider
{
  if (g_appEventsConfigurationProvider != provider) {
    g_appEventsConfigurationProvider = provider;
  }
}

+ (void)setServerConfigurationProvider:(id<FBSDKServerConfigurationProviding>)provider
{
  if (g_serverConfigurationProvider != provider) {
    g_serverConfigurationProvider = provider;
  }
}

#if !TARGET_OS_TV

- (void)configureNonTVComponentsWithOnDeviceMLModelManager:(id<FBSDKEventProcessing, FBSDKIntegrityParametersProcessorProvider>)modelManager
                                           metadataIndexer:(id<FBSDKMetadataIndexing>)metadataIndexer
                                       skAdNetworkReporter:(nullable id<FBSDKAppEventsReporter>)skAdNetworkReporter
                                           codelessIndexer:(Class<FBSDKCodelessIndexing>)codelessIndexer;
{
  self.onDeviceMLModelManager = modelManager;
  self.metadataIndexer = metadataIndexer;
  self.skAdNetworkReporter = skAdNetworkReporter;
  self.codelessIndexer = codelessIndexer;
}

#endif

- (void)logInternalEvent:(FBSDKAppEventName)eventName
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              parameters:@{}
      isImplicitlyLogged:isImplicitlyLogged];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(double)valueToSum
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:valueToSum
              parameters:@{}
      isImplicitlyLogged:isImplicitlyLogged];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              parameters:(nullable NSDictionary<NSString *, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:nil
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:nil];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              parameters:(nullable NSDictionary<NSString *, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
             accessToken:(FBSDKAccessToken *)accessToken
{
  [self logInternalEvent:eventName
              valueToSum:nil
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:accessToken];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(double)valueToSum
              parameters:(nullable NSDictionary<NSString *, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
{
  [self logInternalEvent:eventName
              valueToSum:@(valueToSum)
              parameters:parameters
      isImplicitlyLogged:isImplicitlyLogged
             accessToken:nil];
}

- (void)logInternalEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<NSString *, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
             accessToken:(FBSDKAccessToken *)accessToken
{
  if ([g_settings isAutoLogAppEventsEnabled]) {
    [self instanceLogEvent:eventName
                valueToSum:valueToSum
                parameters:parameters
        isImplicitlyLogged:isImplicitlyLogged
               accessToken:accessToken];
  }
}

- (void)logImplicitEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<NSString *, id> *)parameters
             accessToken:(FBSDKAccessToken *)accessToken
{
  [self instanceLogEvent:eventName
              valueToSum:valueToSum
              parameters:parameters
      isImplicitlyLogged:YES
             accessToken:accessToken];
}

+ (FBSDKAppEvents *)shared
{
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _shared = [self new];
  });
  return _shared;
}

- (void)flushForReason:(FBSDKAppEventsFlushReason)flushReason
{
  // Always flush asynchronously, even on main thread, for two reasons:
  // - most consistent code path for all threads.
  // - allow locks being held by caller to be released prior to actual flushing work being done.
  @synchronized(self) {
    if (!_appEventsState) {
      return;
    }
    FBSDKAppEventsState *copy = [_appEventsState copy];
    _appEventsState = [self.appEventsStateProvider createStateWithToken:copy.tokenString
                                                                  appID:copy.appID];

    dispatch_block_t block = ^{
      [self flushOnMainQueue:copy forReason:flushReason];
    };

  #if DEBUG && FBTEST
    block();
  #else
    dispatch_async(dispatch_get_main_queue(), block);
  #endif
  }
}

#pragma mark - Source Application Tracking

- (void)setSourceApplication:(NSString *)sourceApplication openURL:(NSURL *)url
{
  [self.timeSpentRecorder setSourceApplication:sourceApplication openURL:url];
}

- (void)setSourceApplication:(NSString *)sourceApplication isFromAppLink:(BOOL)isFromAppLink
{
  [self.timeSpentRecorder setSourceApplication:sourceApplication isFromAppLink:isFromAppLink];
}

- (void)registerAutoResetSourceApplication
{
  [self.timeSpentRecorder registerAutoResetSourceApplication];
}

#pragma mark - Private Methods
- (NSString *)appID
{
  return FBSDKAppEvents.shared.loggingOverrideAppID ?: [g_settings appID];
}

- (void)publishInstall
{
  NSString *appID = [self appID];
  if (appID.length == 0) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors logEntry:@"Missing [FBSDKAppEvents appID] for [FBSDKAppEvents publishInstall:]"];
    return;
  }
  NSString *lastAttributionPingString = [NSString stringWithFormat:@"com.facebook.sdk:lastAttributionPing%@", appID];
  if ([self.store objectForKey:lastAttributionPingString]) {
    return;
  }
  [self fetchServerConfiguration:^{
    if ([FBSDKAppEventsUtility shouldDropAppEvent]) {
      return;
    }
    NSMutableDictionary<NSString *, id> *params = [FBSDKAppEventsUtility activityParametersDictionaryForEvent:@"MOBILE_APP_INSTALL"
                                                                                    shouldAccessAdvertisingID:self->_serverConfiguration.isAdvertisingIDEnabled
                                                                                                       userID:self.userID
                                                                                                     userData:[self getUserData]];
    [self appendInstallTimestamp:params];
    NSString *path = [NSString stringWithFormat:@"%@/activities", appID];
    id<FBSDKGraphRequest> request = [g_graphRequestFactory createGraphRequestWithGraphPath:path
                                                                                parameters:params
                                                                               tokenString:nil
                                                                                HTTPMethod:FBSDKHTTPMethodPOST
                                                                                     flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError | FBSDKGraphRequestFlagDisableErrorRecovery];
    __block id<FBSDKDataPersisting> weakStore = self.store;
    [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
      if (!error) {
        [weakStore setObject:[NSDate date] forKey:lastAttributionPingString];
        NSString *lastInstallResponseKey = [NSString stringWithFormat:@"com.facebook.sdk:lastInstallResponse%@", appID];
        [weakStore setObject:result forKey:lastInstallResponseKey];
      }
    }];
  }];
}

- (void)publishATE
{
  if (self.appID.length == 0) {
    return;
  }

  self.atePublisher = self.atePublisher ?: [self.atePublisherFactory createPublisherWithAppID:self.appID];

#if FBTEST
  [self.atePublisher publishATE];
#else
  __weak FBSDKAppEvents *weakSelf = self;
  fb_dispatch_on_default_thread(^(void) {
    [weakSelf.atePublisher publishATE];
  });
#endif
}

- (void)appendInstallTimestamp:(NSMutableDictionary<NSString *, id> *)parameters
{
  if (@available(iOS 14.0, *)) {
    if ([g_settings isSetATETimeExceedsInstallTime]) {
      NSDate *setAteTimestamp = g_settings.advertiserTrackingEnabledTimestamp;
      [FBSDKTypeUtility dictionary:parameters setObject:@([FBSDKAppEventsUtility convertToUnixTime:setAteTimestamp]) forKey:@"install_timestamp"];
    } else {
      NSDate *installTimestamp = g_settings.installTimestamp;
      [FBSDKTypeUtility dictionary:parameters setObject:@([FBSDKAppEventsUtility convertToUnixTime:installTimestamp]) forKey:@"install_timestamp"];
    }
  }
}

#if !TARGET_OS_TV
- (void)enableCodelessEvents
{
  if (!self.swizzler) {
    return;
  }

  if (_serverConfiguration.isCodelessEventsEnabled) {
    [self.codelessIndexer enable];

    if (!_eventBindingManager) {
      _eventBindingManager = [[FBSDKEventBindingManager alloc] initWithSwizzler:self.swizzler
                                                                    eventLogger:self];
    }

    if ([FBSDKInternalUtility.sharedUtility isUnity]) {
      [self sendEventBindingsToUnity];
    } else {
      FBSDKEventBindingManager *manager = [[FBSDKEventBindingManager alloc] initWithSwizzler:self.swizzler
                                                                                 eventLogger:self];
      [_eventBindingManager updateBindings:[manager parseArray:_serverConfiguration.eventBindings]];
    }
  }
}

#endif

// app events can use a server configuration up to 24 hours old to minimize network traffic.
- (void)fetchServerConfiguration:(FBSDKCodeBlock)callback
{
  [g_appEventsConfigurationProvider loadAppEventsConfigurationWithBlock:^{
    [g_serverConfigurationProvider loadServerConfigurationWithCompletionBlock:^(FBSDKServerConfiguration *serverConfiguration, NSError *error) {
      self->_serverConfiguration = serverConfiguration;

      if ([g_settings isAutoLogAppEventsEnabled] && self->_serverConfiguration.implicitPurchaseLoggingEnabled) {
        [g_paymentObserver startObservingTransactions];
      } else {
        [g_paymentObserver stopObservingTransactions];
      }
      [g_featureChecker checkFeature:FBSDKFeatureRestrictiveDataFiltering completionBlock:^(BOOL enabled) {
        if (enabled) {
          [g_restrictiveDataFilterParameterProcessor enable];
        }
      }];
      [g_featureChecker checkFeature:FBSDKFeatureEventDeactivation completionBlock:^(BOOL enabled) {
        if (enabled) {
          [g_eventDeactivationParameterProcessor enable];
        }
      }];
      if (@available(iOS 14.0, *)) {
        __weak FBSDKAppEvents *weakSelf = self;
        [g_featureChecker checkFeature:FBSDKFeatureATELogging completionBlock:^(BOOL enabled) {
          if (enabled) {
            [weakSelf publishATE];
          }
        }];
      }
    #if !TARGET_OS_TV
      [g_featureChecker checkFeature:FBSDKFeatureCodelessEvents completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self enableCodelessEvents];
        }
      }];
      [g_featureChecker checkFeature:FBSDKFeatureAAM completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.metadataIndexer enable];
        }
      }];
      [g_featureChecker checkFeature:FBSDKFeaturePrivacyProtection completionBlock:^(BOOL enabled) {
        if (enabled) {
          [self.onDeviceMLModelManager enable];
        }
      }];
      if (@available(iOS 11.3, *)) {
        if ([g_settings isSKAdNetworkReportEnabled]) {
          [g_featureChecker checkFeature:FBSDKFeatureSKAdNetwork completionBlock:^(BOOL SKAdNetworkEnabled) {
            if (SKAdNetworkEnabled) {
              [SKAdNetwork registerAppForAdNetworkAttribution];
              [g_featureChecker checkFeature:FBSDKFeatureSKAdNetworkConversionValue completionBlock:^(BOOL SKAdNetworkConversionValueEnabled) {
                if (SKAdNetworkConversionValueEnabled) {
                  [self.skAdNetworkReporter enable];
                }
              }];
            }
          }];
        }
      }
      if (@available(iOS 14.0, *)) {
        [g_featureChecker checkFeature:FBSDKFeatureAEM completionBlock:^(BOOL AEMEnabled) {
          if (AEMEnabled) {
            [FBAEMReporter enable];
            [FBAEMReporter setCatalogReportEnabled:[g_featureChecker isEnabled:FBSDKFeatureAEMCatalogReport]];
          }
        }];
      }
    #endif
      if (callback) {
        callback();
      }
    }];
  }];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)instanceLogEvent:(FBSDKAppEventName)eventName
              valueToSum:(NSNumber *)valueToSum
              parameters:(nullable NSDictionary<NSString *, id> *)parameters
      isImplicitlyLogged:(BOOL)isImplicitlyLogged
             accessToken:(FBSDKAccessToken *)accessToken
{
  [self validateConfiguration];

  // Kill events if kill-switch is enabled
  if (!g_gateKeeperManager) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                        logEntry:@"FBSDKAppEvents: Cannot log app events before the SDK is initialized."];
    return;
  } else if ([g_gateKeeperManager boolForKey:FBSDKGateKeeperAppEventsKillSwitch
                                defaultValue:NO]) {
    NSString *message = [NSString stringWithFormat:@"FBSDKAppEvents: KillSwitch is enabled and fail to log app event: %@", eventName];
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                        logEntry:message];
    return;
  }
#if !TARGET_OS_TV
  // Update conversion value for SKAdNetwork if needed
  [self.skAdNetworkReporter recordAndUpdateEvent:eventName
                                        currency:[FBSDKTypeUtility dictionary:parameters objectForKey:FBSDKAppEventParameterNameCurrency ofType:NSString.class]
                                           value:valueToSum
                                      parameters:parameters];
  // Update conversion value for AEM if needed
  [FBAEMReporter recordAndUpdateEvent:eventName
                             currency:[FBSDKTypeUtility dictionary:parameters objectForKey:FBSDKAppEventParameterNameCurrency ofType:NSString.class]
                                value:valueToSum
                           parameters:parameters];
#endif

  if ([FBSDKAppEventsUtility shouldDropAppEvent]) {
    return;
  }

  if (isImplicitlyLogged && _serverConfiguration && !_serverConfiguration.isImplicitLoggingSupported) {
    return;
  }

  if (!isImplicitlyLogged && !g_explicitEventsLoggedYet) {
    g_explicitEventsLoggedYet = YES;
  }
  __block BOOL failed = ![FBSDKAppEventsUtility validateIdentifier:eventName];

  // Make sure parameter dictionary is well formed.  Log and exit if not.
  [FBSDKTypeUtility dictionary:parameters enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    if (![key isKindOfClass:NSString.class]) {
      [FBSDKAppEventsUtility logAndNotify:[NSString stringWithFormat:@"The keys in the parameters must be NSStrings, '%@' is not.", key]];
      failed = YES;
    }
    if (![FBSDKAppEventsUtility validateIdentifier:key]) {
      failed = YES;
    }
    if (![obj isKindOfClass:NSString.class] && ![obj isKindOfClass:NSNumber.class]) {
      [FBSDKAppEventsUtility logAndNotify:[NSString stringWithFormat:@"The values in the parameters dictionary must be NSStrings or NSNumbers, '%@' is not.", obj]];
      failed = YES;
    }
  }];

  if (failed) {
    return;
  }
  // Filter out deactivated params
  parameters = [g_eventDeactivationParameterProcessor processParameters:parameters eventName:eventName];

#if !TARGET_OS_TV
  // Filter out restrictive data with on-device ML
  if (self.onDeviceMLModelManager.integrityParametersProcessor) {
    parameters = [self.onDeviceMLModelManager.integrityParametersProcessor processParameters:parameters eventName:eventName];
  }
#endif
  // Filter out restrictive keys
  parameters = [g_restrictiveDataFilterParameterProcessor processParameters:parameters
                                                                  eventName:eventName];

  NSMutableDictionary<NSString *, id> *eventDictionary = [NSMutableDictionary dictionaryWithDictionary:parameters];
  [FBSDKTypeUtility dictionary:eventDictionary setObject:eventName forKey:FBSDKAppEventParameterNameEventName];
  if (!eventDictionary[FBSDKAppEventParameterNameLogTime]) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:@([FBSDKAppEventsUtility unixTimeNow]) forKey:FBSDKAppEventParameterNameLogTime];
  }
  [FBSDKTypeUtility dictionary:eventDictionary setObject:valueToSum forKey:@"_valueToSum"];
  if (isImplicitlyLogged) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:@"1" forKey:FBSDKAppEventParameterNameImplicitlyLogged];
  }

  NSString *currentViewControllerName;
  UIApplicationState applicationState;
  if (NSThread.isMainThread) {
    // We only collect the view controller when on the main thread, as the behavior off
    // the main thread is unpredictable.  Besides, UI state for off-main-thread computations
    // isn't really relevant anyhow.
    UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
    vc = vc.presentedViewController ?: vc;
    if (vc) {
      currentViewControllerName = [vc.class description];
    } else {
      currentViewControllerName = @"no_ui";
    }
    applicationState = UIApplication.sharedApplication.applicationState;
  } else {
    currentViewControllerName = @"off_thread";
    applicationState = self.applicationState;
  }
  [FBSDKTypeUtility dictionary:eventDictionary setObject:currentViewControllerName forKey:@"_ui"];

  if (applicationState == UIApplicationStateBackground) {
    [FBSDKTypeUtility dictionary:eventDictionary setObject:@"1" forKey:FBSDKAppEventParameterNameInBackground];
  }

  NSString *tokenString = [FBSDKAppEventsUtility tokenStringToUseFor:accessToken
                                                loggingOverrideAppID:self.class.loggingOverrideAppID];
  NSString *appID = [self appID];

  @synchronized(self) {
    if (!_appEventsState) {
      _appEventsState = [self.appEventsStateProvider createStateWithToken:tokenString appID:appID];
    } else if (![_appEventsState isCompatibleWithTokenString:tokenString appID:appID]) {
      if (self.flushBehavior == FBSDKAppEventsFlushBehaviorExplicitOnly) {
        [g_appEventsStateStore persistAppEventsData:_appEventsState];
      } else {
        [self flushForReason:FBSDKAppEventsFlushReasonSessionChange];
      }
      _appEventsState = [self.appEventsStateProvider createStateWithToken:tokenString appID:appID];
    }

    [_appEventsState addEvent:eventDictionary isImplicit:isImplicitlyLogged];
    if (!isImplicitlyLogged) {
      NSString *message = [NSString stringWithFormat:@"FBSDKAppEvents: Recording event @ %f: %@",
                           [FBSDKAppEventsUtility unixTimeNow],
                           eventDictionary];
      [g_logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                          logEntry:message];
    }

    [self checkPersistedEvents];

    if (_appEventsState.events.count > NUM_LOG_EVENTS_TO_TRY_TO_FLUSH_AFTER
        && self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
      [self flushForReason:FBSDKAppEventsFlushReasonEventThreshold];
    }
  }
}

#pragma clang diagnostic pop

// this fetches persisted event states.
// for those matching the currently tracked events, add it.
// otherwise, either flush (if not explicitonly behavior) or persist them back.
- (void)checkPersistedEvents
{
  NSArray *existingEventsStates = [g_appEventsStateStore retrievePersistedAppEventsStates];
  if (existingEventsStates.count == 0) {
    return;
  }
  FBSDKAppEventsState *matchingEventsPreviouslySaved = nil;
  // reduce lock time by creating a new FBSDKAppEventsState to collect matching persisted events.
  @synchronized(self) {
    if (_appEventsState) {
      matchingEventsPreviouslySaved = [self.appEventsStateProvider createStateWithToken:_appEventsState.tokenString
                                                                                  appID:_appEventsState.appID];
    }
  }
  for (FBSDKAppEventsState *saved in existingEventsStates) {
    if ([saved isCompatibleWithAppEventsState:matchingEventsPreviouslySaved]) {
      [matchingEventsPreviouslySaved addEventsFromAppEventState:saved];
    } else {
      if (self.flushBehavior == FBSDKAppEventsFlushBehaviorExplicitOnly) {
        [g_appEventsStateStore persistAppEventsData:saved];
      } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self flushOnMainQueue:saved forReason:FBSDKAppEventsFlushReasonPersistedEvents];
        });
      }
    }
  }
  if (matchingEventsPreviouslySaved.events.count > 0) {
    @synchronized(self) {
      if ([_appEventsState isCompatibleWithAppEventsState:matchingEventsPreviouslySaved]) {
        [_appEventsState addEventsFromAppEventState:matchingEventsPreviouslySaved];
      }
    }
  }
}

- (void)flushOnMainQueue:(FBSDKAppEventsState *)appEventsState
               forReason:(FBSDKAppEventsFlushReason)reason
{
  if (appEventsState.events.count == 0) {
    return;
  }

  if (appEventsState.appID.length == 0) {
    [g_logger singleShotLogEntry:FBSDKLoggingBehaviorDeveloperErrors logEntry:@"Missing [FBSDKAppEvents appEventsState.appID] for [FBSDKAppEvents flushOnMainQueue:]"];
    return;
  }

  [FBSDKAppEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  [self fetchServerConfiguration:^(void) {
    if ([FBSDKAppEventsUtility shouldDropAppEvent]) {
      return;
    }
    NSString *receipt_data = appEventsState.extractReceiptData;
    const BOOL shouldIncludeImplicitEvents = (self->_serverConfiguration.implicitLoggingEnabled && g_settings.isAutoLogAppEventsEnabled);
    NSString *encodedEvents = [appEventsState JSONStringForEventsIncludingImplicitEvents:shouldIncludeImplicitEvents];
    if (!encodedEvents || appEventsState.events.count == 0) {
      [g_logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                          logEntry:@"FBSDKAppEvents: Flushing skipped - no events after removing implicitly logged ones.\n"];
      return;
    }
    NSMutableDictionary<NSString *, id> *postParameters = [FBSDKAppEventsUtility
                                                           activityParametersDictionaryForEvent:@"CUSTOM_APP_EVENTS"
                                                           shouldAccessAdvertisingID:self->_serverConfiguration.advertisingIDEnabled
                                                           userID:self.userID
                                                           userData:[self getUserData]];
    NSInteger length = receipt_data.length;
    if (length > 0) {
      [FBSDKTypeUtility dictionary:postParameters setObject:receipt_data forKey:@"receipt_data"];
    }

    [FBSDKTypeUtility dictionary:postParameters setObject:encodedEvents forKey:@"custom_events"];
    if (appEventsState.numSkipped > 0) {
      [FBSDKTypeUtility dictionary:postParameters setObject:[NSString stringWithFormat:@"%lu", (unsigned long)appEventsState.numSkipped] forKey:@"num_skipped_events"];
    }
    if (self.pushNotificationsDeviceTokenString) {
      [FBSDKTypeUtility dictionary:postParameters setObject:self.pushNotificationsDeviceTokenString forKey:FBSDKActivitesParameterPushDeviceToken];
    }

    NSString *loggingEntry = nil;
    if ([g_settings.loggingBehaviors containsObject:FBSDKLoggingBehaviorAppEvents]) {
      NSData *prettyJSONData = [FBSDKTypeUtility dataWithJSONObject:appEventsState.events
                                                            options:NSJSONWritingPrettyPrinted
                                                              error:NULL];
      NSString *prettyPrintedJsonEvents = [[NSString alloc] initWithData:prettyJSONData
                                                                encoding:NSUTF8StringEncoding];
      // Remove this param -- just an encoding of the events which we pretty print later.
      NSMutableDictionary<NSString *, id> *paramsForPrinting = [postParameters mutableCopy];
      [paramsForPrinting removeObjectForKey:@"custom_events_file"];

      loggingEntry = [NSString stringWithFormat:@"FBSDKAppEvents: Flushed @ %f, %lu events due to '%@' - %@\nEvents: %@",
                      [FBSDKAppEventsUtility unixTimeNow],
                      (unsigned long)appEventsState.events.count,
                      [FBSDKAppEventsUtility flushReasonToString:reason],
                      paramsForPrinting,
                      prettyPrintedJsonEvents];
    }
    id<FBSDKGraphRequest> request = [g_graphRequestFactory createGraphRequestWithGraphPath:[NSString stringWithFormat:@"%@/activities", appEventsState.appID]
                                                                                parameters:postParameters
                                                                               tokenString:appEventsState.tokenString
                                                                                HTTPMethod:FBSDKHTTPMethodPOST
                                                                                     flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError | FBSDKGraphRequestFlagDisableErrorRecovery];
    [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
      [self handleActivitiesPostCompletion:error
                              loggingEntry:loggingEntry
                            appEventsState:(FBSDKAppEventsState *)appEventsState];
    }];
  }];
}

- (void)handleActivitiesPostCompletion:(NSError *)error
                          loggingEntry:(NSString *)loggingEntry
                        appEventsState:(FBSDKAppEventsState *)appEventsState
{
  typedef NS_ENUM(NSUInteger, FBSDKAppEventsFlushResult) {
    FlushResultSuccess,
    FlushResultServerError,
    FlushResultNoConnectivity,
  };

  [FBSDKAppEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  FBSDKAppEventsFlushResult flushResult = FlushResultSuccess;
  if (error) {
    NSInteger errorCode = [error.userInfo[FBSDKGraphRequestErrorHTTPStatusCodeKey] integerValue];

    // We interpret a 400 coming back from FBRequestConnection as a server error due to improper data being
    // sent down.  Otherwise we assume no connectivity, or another condition where we could treat it as no connectivity.
    // Adding 404 as having wrong/missing appID results in 404 and that is not a connectivity issue
    flushResult = (errorCode == 400 || errorCode == 404) ? FlushResultServerError : FlushResultNoConnectivity;
  }

  if (flushResult == FlushResultServerError) {
    // Only log events that developer can do something with (i.e., if parameters are incorrect).
    // as opposed to cases where the token is bad.
    if ([error.userInfo[FBSDKGraphRequestErrorKey] unsignedIntegerValue] == FBSDKGraphRequestErrorOther) {
      NSString *message = [NSString stringWithFormat:@"Failed to send AppEvents: %@", error];
      [FBSDKAppEventsUtility logAndNotify:message allowLogAsDeveloperError:!appEventsState.areAllEventsImplicit];
    }
  } else if (flushResult == FlushResultNoConnectivity) {
    @synchronized(self) {
      if ([appEventsState isCompatibleWithAppEventsState:_appEventsState]) {
        [_appEventsState addEventsFromAppEventState:appEventsState];
      } else {
        // flush failed due to connectivity. Persist to be tried again later.
        [g_appEventsStateStore persistAppEventsData:appEventsState];
      }
    }
  }

  NSString *resultString = @"<unknown>";
  switch (flushResult) {
    case FlushResultSuccess:
      resultString = @"Success";
      break;

    case FlushResultNoConnectivity:
      resultString = @"No Connectivity";
      break;

    case FlushResultServerError:
      resultString = [NSString stringWithFormat:@"Server Error - %@", error.description];
      break;
  }

  NSString *message = [NSString stringWithFormat:@"%@\nFlush Result : %@", loggingEntry, resultString];
  [g_logger singleShotLogEntry:FBSDKLoggingBehaviorAppEvents
                      logEntry:message];
}

- (void)flushTimerFired:(id)arg
{
  [FBSDKAppEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];
  if (self.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
    [self flushForReason:FBSDKAppEventsFlushReasonTimer];
  }
}

- (void)applicationDidBecomeActive
{
  [FBSDKAppEventsUtility ensureOnMainThread:NSStringFromSelector(_cmd) className:NSStringFromClass(self.class)];

  // This must happen here to avoid a race condition with the shared `Settings` object.
  [self fetchServerConfiguration:nil];

  [self checkPersistedEvents];

  // Restore time spent data, indicating that we're not being called from "activateApp".
  [self.timeSpentRecorder restore:NO];
}

- (void)applicationMovingFromActiveStateOrTerminating
{
  // When moving from active state, we don't have time to wait for the result of a flush, so
  // just persist events to storage, and we'll process them at the next activation.
  FBSDKAppEventsState *copy = nil;
  @synchronized(self) {
    copy = [_appEventsState copy];
    _appEventsState = nil;
  }
  if (copy) {
    [g_appEventsStateStore persistAppEventsData:copy];
  }
  [self.timeSpentRecorder suspend];
}

#pragma mark - Configuration Validation

- (void)validateConfiguration
{
#if DEBUG
  if (!self.isConfigured) {
    static NSString *const reason = @"As of v9.0, you must initialize the SDK prior to calling any methods or setting any properties. "
    "You can do this by calling `FBSDKApplicationDelegate`'s `application:didFinishLaunchingWithOptions:` method. "
    "Learn more: https://developers.facebook.com/docs/ios/getting-started"
    "If no `UIApplication` is available you can use `FBSDKApplicationDelegate`'s `initializeSDK` method.";
    @throw [NSException exceptionWithName:@"InvalidOperationException" reason:reason userInfo:nil];
  }
#endif
}

#pragma mark - Custom Audience

+ (nullable id<FBSDKGraphRequest>)requestForCustomAudienceThirdPartyIDWithAccessToken:(nullable FBSDKAccessToken *)accessToken
{
  return [self.shared requestForCustomAudienceThirdPartyIDWithAccessToken:accessToken];
}

- (nullable id<FBSDKGraphRequest>)requestForCustomAudienceThirdPartyIDWithAccessToken:(nullable FBSDKAccessToken *)accessToken
{
  [self validateConfiguration];

  accessToken = accessToken ?: FBSDKAccessToken.currentAccessToken;

  // Rules for how we use the attribution ID / advertiser ID for an 'custom_audience_third_party_id' Graph API request
  // 1) if the OS tells us that the user has Limited Ad Tracking, then just don't send, and return a nil in the token.
  // 2) if the app has set 'limitEventAndDataUsage', this effectively implies that app-initiated ad targeting shouldn't happen,
  // so use that data here to return nil as well.
  // 3) if we have a user session token, then no need to send attribution ID / advertiser ID back as the udid parameter
  // 4) otherwise, send back the udid parameter.
  if (g_settings.advertisingTrackingStatus == FBSDKAdvertisingTrackingDisallowed || g_settings.isEventDataUsageLimited) {
    return nil;
  }

  NSString *tokenString = [FBSDKAppEventsUtility tokenStringToUseFor:accessToken
                                                loggingOverrideAppID:self.loggingOverrideAppID];
  NSString *udid = nil;
  if (!accessToken) {
    // We don't have a logged in user, so we need some form of udid representation. Prefer advertiser ID if
    // available. Note that this function only makes sense to be called in the context of advertising.
    udid = self.advertiserIDProvider.advertiserID;
    if (!udid) {
      // No udid, and no user token.  No point in making the request.
      return nil;
    }
  }

  NSDictionary<NSString *, id> *parameters = @{};
  if (udid) {
    parameters = @{ @"udid" : udid };
  }

  NSString *graphPath = [NSString stringWithFormat:@"%@/custom_audience_third_party_id", self.appID];

  id<FBSDKGraphRequest> request = [g_graphRequestFactory createGraphRequestWithGraphPath:graphPath
                                                                              parameters:parameters
                                                                             tokenString:tokenString
                                                                              HTTPMethod:FBSDKHTTPMethodGET
                                                                                   flags:FBSDKGraphRequestFlagDoNotInvalidateTokenOnError | FBSDKGraphRequestFlagDisableErrorRecovery];
  return request;
}

#pragma mark - Testability

#if DEBUG && FBTEST

+ (void)reset
{
  self.shared.isConfigured = NO;
  [self resetApplicationState];
  g_gateKeeperManager = nil;
  g_graphRequestFactory = nil;
}

+ (void)setShared:(FBSDKAppEvents *)appEvents
{
  _shared = appEvents;
}

+ (void)resetApplicationState
{
  self.shared.applicationState = UIApplicationStateInactive;
}

+ (id<FBSDKFeatureChecking>)featureChecker
{
  return g_featureChecker;
}

+ (id<FBSDKGraphRequestFactory>)graphRequestFactory
{
  return g_graphRequestFactory;
}

+ (id<FBSDKServerConfigurationProviding>)serverConfigurationProvider
{
  return g_serverConfigurationProvider;
}

+ (id<FBSDKAppEventsConfigurationProviding>)appEventsConfigurationProvider
{
  return g_appEventsConfigurationProvider;
}

+ (Class<FBSDKGateKeeperManaging>)gateKeeperManager
{
  return g_gateKeeperManager;
}

+ (Class<FBSDKLogging>)logger
{
  return g_logger;
}

+ (id<FBSDKSettings>)settings
{
  return g_settings;
}

+ (void)setSettings:(id<FBSDKSettings>)settings
{
  g_settings = settings;
}

+ (id<FBSDKPaymentObserving>)paymentObserver
{
  return g_paymentObserver;
}

+ (void)setPaymentObserver:(id<FBSDKPaymentObserving>)paymentObserver
{
  g_paymentObserver = paymentObserver;
}

+ (id<FBSDKAppEventsStatePersisting>)appEventsStateStore
{
  return g_appEventsStateStore;
}

- (void)setFlushBehavior:(FBSDKAppEventsFlushBehavior)flushBehavior
{
  [self validateConfiguration];
  _flushBehavior = flushBehavior;
}

 #if !TARGET_OS_TV

+ (id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing>)eventDeactivationParameterProcessor
{
  return g_eventDeactivationParameterProcessor;
}

+ (id<FBSDKAppEventsParameterProcessing, FBSDKEventsProcessing>)restrictiveDataFilterParameterProcessor
{
  return g_restrictiveDataFilterParameterProcessor;
}

 #endif

#endif

@end
