/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import "FBRouteRequest-Private.h"
#import "FBResponsePayload.h"
#import "FBSession.h"
#import "FBSessionCommands.h"
#import "RouteResponse.h"

@interface FBSessionCommands (FBWDATestable)
+ (id<FBResponsePayload>)handleOpenURL:(FBRouteRequest *)request;
+ (id<FBResponsePayload>)handleCreateSession:(FBRouteRequest *)request;
+ (id<FBResponsePayload>)handleSessionAppLaunch:(FBRouteRequest *)request;
+ (id<FBResponsePayload>)handleSessionAppActivate:(FBRouteRequest *)request;
+ (id<FBResponsePayload>)handleSessionAppTerminate:(FBRouteRequest *)request;
+ (id<FBResponsePayload>)handleSessionAppState:(FBRouteRequest *)request;
@end

// Stands in for the session of the /wda/apps handlers and records the bundle ids it gets
// (NSNull for nil), so nothing reaches XCTest.
@interface FBAppsSessionDouble : NSObject
@property (nonatomic, readonly) NSMutableArray *receivedBundleIds;
@end

@implementation FBAppsSessionDouble

- (instancetype)init
{
  if ((self = [super init])) {
    _receivedBundleIds = [NSMutableArray array];
  }
  return self;
}

- (XCUIApplication *)launchApplicationWithBundleId:(NSString *)bundleIdentifier
                           shouldWaitForQuiescence:(NSNumber *)shouldWaitForQuiescence
                                         arguments:(NSArray<NSString *> *)arguments
                                       environment:(NSDictionary <NSString *, NSString *> *)environment
                            asApplicationUnderTest:(BOOL)asApplicationUnderTest
{
  [self.receivedBundleIds addObject:bundleIdentifier ?: NSNull.null];
  return nil;
}

- (XCUIApplication *)activateApplicationWithBundleId:(NSString *)bundleIdentifier
{
  [self.receivedBundleIds addObject:bundleIdentifier ?: NSNull.null];
  return nil;
}

- (BOOL)terminateApplicationWithBundleId:(NSString *)bundleIdentifier
{
  [self.receivedBundleIds addObject:bundleIdentifier ?: NSNull.null];
  return NO;
}

- (NSUInteger)applicationStateWithBundleId:(NSString *)bundleIdentifier
{
  [self.receivedBundleIds addObject:bundleIdentifier ?: NSNull.null];
  return 0;
}

@end

@interface FBSessionCommandsTests : XCTestCase
@end

@implementation FBSessionCommandsTests

- (RouteResponse *)responseOf:(SEL)handler
                    arguments:(NSDictionary *)arguments
                      session:(nullable FBAppsSessionDouble *)session
{
  FBRouteRequest *request = [FBRouteRequest routeRequestWithURL:[NSURL URLWithString:@"http://localhost:8100/"]
                                                  parameters:@{}
                                                   arguments:arguments];
  request.session = (FBSession *)session;
  id<FBResponsePayload> (*invoke)(id, SEL, FBRouteRequest *) = (void *)[FBSessionCommands methodForSelector:handler];
  RouteResponse *response = [RouteResponse new];
  [invoke(FBSessionCommands.class, handler, request) dispatchWithResponse:response];
  return response;
}

- (nullable NSString *)errorOf:(RouteResponse *)response
{
  id value = [NSJSONSerialization JSONObjectWithData:response.responseData options:0 error:nil][@"value"];
  return [value isKindOfClass:NSDictionary.class] ? value[@"error"] : nil;
}

- (void)assertInvalidBundleIdResponse:(RouteResponse *)response message:(NSString *)message
{
  XCTAssertEqual(response.statusCode, 400, @"%@", message);
  XCTAssertEqualObjects([self errorOf:response], @"invalid argument", @"%@", message);
}

- (NSArray<NSValue *> *)appHandlers
{
  return @[
    [NSValue valueWithPointer:@selector(handleSessionAppLaunch:)],
    [NSValue valueWithPointer:@selector(handleSessionAppActivate:)],
    [NSValue valueWithPointer:@selector(handleSessionAppTerminate:)],
    [NSValue valueWithPointer:@selector(handleSessionAppState:)],
  ];
}

- (NSArray *)nonStringBundleIds
{
  return @[NSNull.null, @42, @[@"com.apple.Preferences"]];
}

- (void)testAppCommandsRejectMissingOrNonStringBundleId
{
  NSMutableArray<NSDictionary *> *argumentsList = [NSMutableArray arrayWithObject:@{}];
  for (id bundleId in self.nonStringBundleIds) {
    [argumentsList addObject:@{@"bundleId": bundleId}];
  }
  for (NSValue *handler in self.appHandlers) {
    for (NSDictionary *arguments in argumentsList) {
      FBAppsSessionDouble *session = [FBAppsSessionDouble new];
      RouteResponse *response = [self responseOf:(SEL)handler.pointerValue arguments:arguments session:session];
      NSString *message = [NSString stringWithFormat:@"%@ with %@",
                           NSStringFromSelector((SEL)handler.pointerValue), arguments];
      [self assertInvalidBundleIdResponse:response message:message];
      XCTAssertEqual(session.receivedBundleIds.count, 0, @"%@", message);
    }
  }
}

- (void)testAppCommandsPassStringBundleIdToSession
{
  for (NSValue *handler in self.appHandlers) {
    // An empty string is still a string: it is passed on as before.
    for (NSString *bundleId in @[@"com.apple.Preferences", @""]) {
      FBAppsSessionDouble *session = [FBAppsSessionDouble new];
      RouteResponse *response = [self responseOf:(SEL)handler.pointerValue
                                       arguments:@{@"bundleId": bundleId}
                                         session:session];
      NSString *message = [NSString stringWithFormat:@"%@ with '%@'",
                           NSStringFromSelector((SEL)handler.pointerValue), bundleId];
      XCTAssertNil([self errorOf:response], @"%@", message);
      XCTAssertEqualObjects(session.receivedBundleIds, @[bundleId], @"%@", message);
    }
  }
}

- (void)testOpenURLRejectsNonStringBundleId
{
  for (id bundleId in self.nonStringBundleIds) {
    RouteResponse *response = [self responseOf:@selector(handleOpenURL:)
                                     arguments:@{@"url": @"https://appium.io", @"bundleId": bundleId}
                                       session:nil];
    [self assertInvalidBundleIdResponse:response message:[NSString stringWithFormat:@"/url with %@", bundleId]];
  }
}

- (void)testCreateSessionRejectsNonStringBundleIdCapability
{
  for (id bundleId in self.nonStringBundleIds) {
    RouteResponse *response = [self responseOf:@selector(handleCreateSession:)
                                     arguments:@{@"capabilities": @{@"alwaysMatch": @{@"bundleId": bundleId}}}
                                       session:nil];
    NSString *message = [NSString stringWithFormat:@"/session with %@", bundleId];
    // Like the other capability errors of this handler
    XCTAssertEqual(response.statusCode, 500, @"%@", message);
    XCTAssertEqualObjects([self errorOf:response], @"session not created", @"%@", message);
  }
}

@end
