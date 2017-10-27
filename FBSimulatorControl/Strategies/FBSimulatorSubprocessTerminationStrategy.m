/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "FBSimulatorSubprocessTerminationStrategy.h"

#import <FBControlCore/FBControlCore.h>

#import "FBSimulator.h"
#import "FBSimulator+Private.h"
#import "FBSimulatorLaunchCtlCommands.h"
#import "FBSimulatorError.h"
#import "FBSimulatorEventSink.h"
#import "FBSimulatorProcessFetcher.h"

@interface FBSimulatorSubprocessTerminationStrategy ()

@property (nonatomic, weak, readonly) FBSimulator *simulator;

@end

@implementation FBSimulatorSubprocessTerminationStrategy

#pragma mark Initializers

+ (instancetype)strategyWithSimulator:(FBSimulator *)simulator
{
  return [[self alloc] initWithSimulator:simulator];
}

- (instancetype)initWithSimulator:(FBSimulator *)simulator
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _simulator = simulator;

  return self;
}

#pragma mark Public Methods

- (FBFuture<NSNull *> *)terminate:(FBProcessInfo *)process;
{
  // Confirm that the process has the launchd_sim as a parent process.
  // The interaction should restrict itself to simulator processes so this is a guard
  // to ensure that this interaction can't go around killing random processes.
  pid_t parentProcessIdentifier = [self.simulator.processFetcher.processFetcher parentOf:process.processIdentifier];
  if (parentProcessIdentifier != self.simulator.launchdProcess.processIdentifier) {
    return [[FBSimulatorError
      describeFormat:@"Parent of %@ is not the launchd_sim (%@) it has a pid %d", process.shortDescription, self.simulator.launchdProcess.shortDescription, parentProcessIdentifier]
      failFuture];
  }

  // Get the Service Name and then stop using the Service Name.
  return [[[self.simulator
    serviceNameForProcess:process]
    rephraseFailure:@"Could not Obtain the Service Name for %@", process.shortDescription]
    onQueue:self.simulator.workQueue fmap:^FBFuture *(NSString *serviceName) {
      return [[self.simulator
        stopServiceWithName:serviceName]
        rephraseFailure:@"Failed to stop service '%@'", serviceName];
    }];
}

@end
