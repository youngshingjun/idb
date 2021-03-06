/*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBIDBXCTestReporter.h"

@interface FBIDBXCTestReporter ()

@property (nonatomic, assign, readwrite) grpc::ServerWriter<idb::XctestRunResponse> *writer;
@property (nonatomic, strong, readonly) dispatch_queue_t queue;
@property (nonatomic, strong, readonly) id<FBControlCoreLogger> logger;
@property (nonatomic, strong, readonly) FBMutableFuture<NSNumber *> *reportingTerminatedMutable;

@property (nonatomic, nullable, copy, readwrite) NSString *currentBundleName;
@property (nonatomic, nullable, copy, readwrite) NSString *currentTestClass;
@property (nonatomic, nullable, copy, readwrite) NSString *currentTestMethod;

@property (nonatomic, strong, readonly) NSMutableArray<FBActivityRecord *> *currentActivityRecords;
@property (nonatomic, assign, readwrite) idb::XctestRunResponse_TestRunInfo_TestRunFailureInfo failureInfo;

@end

@implementation FBIDBXCTestReporter

#pragma mark Initializer

- (instancetype)initWithResponseWriter:(grpc::ServerWriter<idb::XctestRunResponse> *)writer queue:(dispatch_queue_t)queue logger:(id<FBControlCoreLogger>)logger
{
  self = [super init];
  if (!self) {
    return nil;
  }

  _writer = writer;
  _queue = queue;
  _logger = logger;
  _currentActivityRecords = NSMutableArray.array;
  _reportingTerminatedMutable = FBMutableFuture.future;

  return self;
}

#pragma mark Properties

- (FBFuture<NSNumber *> *)reportingTerminated
{
  return self.reportingTerminatedMutable;
}

#pragma mark FBXCTestReporter

- (void)testCaseDidStartForTestClass:(NSString *)testClass method:(NSString *)method
{
  self.currentTestClass = testClass;
  self.currentTestMethod = method;
}

- (void)testPlanDidFailWithMessage:(NSString *)message
{
  const idb::XctestRunResponse response = [self responseForCrashMessage:message];
  [self writeResponse:response];
}

- (void)testCaseDidFailForTestClass:(NSString *)testClass method:(NSString *)method withMessage:(NSString *)message file:(NSString *)file line:(NSUInteger)line
{
  // testCaseDidFinishForTestClass will be called immediately after this call, this makes sure we attach the failure info to it.
  if (([testClass isEqualToString:self.currentTestClass] && [method isEqualToString:self.currentTestMethod]) == NO) {
    [self.logger logFormat:@"Got failure info for %@/%@ but the current known executing test is %@/%@. Ignoring it", testClass, method, self.currentTestClass, self.currentTestMethod];
    return;
  }
  self.failureInfo = [self failureInfoWithMessage:message file:file line:line];
}

- (void)testCaseDidFinishForTestClass:(NSString *)testClass method:(NSString *)method withStatus:(FBTestReportStatus)status duration:(NSTimeInterval)duration
{
  [self testCaseDidFinishForTestClass:testClass method:method withStatus:status duration:duration logs:nil];
}

- (void)testCaseDidFinishForTestClass:(NSString *)testClass method:(NSString *)method withStatus:(FBTestReportStatus)status duration:(NSTimeInterval)duration logs:(NSArray<NSString *> *)logs
{
  const idb::XctestRunResponse_TestRunInfo info = [self runInfoForTestClass:testClass method:method withStatus:status duration:duration logs:logs];
  [self writeTestRunInfo:info];
}

- (void)testCase:(NSString *)testClass method:(NSString *)method willStartActivity:(FBActivityRecord *)activity
{
  [self.currentActivityRecords addObject:activity];
}

- (void)testSuite:(NSString *)testSuite didStartAt:(NSString *)startTime
{
  @synchronized (self) {
    self.currentBundleName = testSuite;
  }
}

- (void)didCrashDuringTest:(NSError *)error
{
  const idb::XctestRunResponse response = [self responseForCrashMessage:error.description];
  [self writeResponse:response];
}

- (void)testHadOutput:(NSString *)output
{
  const idb::XctestRunResponse response = [self responseForLogOutput:@[output]];
  [self writeResponse:response];
}

- (void)handleExternalEvent:(NSString *)event
{
  const idb::XctestRunResponse response = [self responseForLogOutput:@[event]];
  [self writeResponse:response];
}

- (void)didFinishExecutingTestPlan
{
  const idb::XctestRunResponse response = [self responseForNormalTestTermination];
  [self writeResponse:response];
}
  
#pragma mark FBXCTestReporter (Unused)

- (BOOL)printReportWithError:(NSError **)error
{
  return NO;
}

- (void)processWaitingForDebuggerWithProcessIdentifier:(pid_t)pid
{
}

- (void)debuggerAttached
{
}

- (void)didBeginExecutingTestPlan
{
}

- (void)finishedWithSummary:(FBTestManagerResultSummary *)summary
{
  // didFinishExecutingTestPlan should be used to signify completion instead
}

#pragma mark FBDataConsumer

- (void)consumeData:(NSData *)data
{
  idb::XctestRunResponse response = [self responseForLogData:data];
  [self writeResponse:response];
}

- (void)consumeEndOfFile
{

}

#pragma mark Private

- (const idb::XctestRunResponse_TestRunInfo)runInfoForTestClass:(NSString *)testClass method:(NSString *)method withStatus:(FBTestReportStatus)status duration:(NSTimeInterval)duration logs:(NSArray<NSString *> *)logs
{
  idb::XctestRunResponse_TestRunInfo info;
  info.set_bundle_name(self.currentBundleName.UTF8String ?: "");
  info.set_class_name(testClass.UTF8String ?: "");
  info.set_method_name(method.UTF8String ?: "");
  info.set_duration(duration);
  info.mutable_failure_info()->CopyFrom(self.failureInfo);
  switch (status) {
    case FBTestReportStatusPassed:
      info.set_status(idb::XctestRunResponse_TestRunInfo_Status_PASSED);
      break;
    case FBTestReportStatusFailed:
      info.set_status(idb::XctestRunResponse_TestRunInfo_Status_FAILED);
      break;
    default:
      break;
  }
  for (NSString *log in logs) {
    info.add_logs(log.UTF8String ?: "");
  }
  for (FBActivityRecord *activity in self.currentActivityRecords) {
    idb::XctestRunResponse_TestRunInfo_TestActivity *activityOut = info.add_activitylogs();
    activityOut->set_title(activity.title.UTF8String ?: "");
    activityOut->set_duration(activity.duration);
    activityOut->set_uuid(activity.uuid.UUIDString.UTF8String ?: "");
  }
  [self resetCurrentTestState];
  return info;
}

- (const idb::XctestRunResponse_TestRunInfo_TestRunFailureInfo)failureInfoWithMessage:(NSString *)message file:(NSString *)file line:(NSUInteger)line
{
  idb::XctestRunResponse_TestRunInfo_TestRunFailureInfo failureInfo;
  failureInfo.set_failure_message(message.UTF8String ?: "");
  failureInfo.set_file(file.UTF8String ?: "");
  failureInfo.set_line(line);
  return failureInfo;
}

- (const idb::XctestRunResponse)responseForLogOutput:(NSArray<NSString *> *)logOutput
{
  idb::XctestRunResponse response;
  response.set_status(idb::XctestRunResponse_Status_RUNNING);
  for (NSString *log in logOutput) {
      NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"Assertion failed: (.*), function (.*), file (.*), line (\\d+)." options:NSRegularExpressionCaseInsensitive error:nil];
      NSTextCheckingResult *result = [regex firstMatchInString:log options:0 range:NSMakeRange(0, [log length])];
      if (result) {
          self.failureInfo = [self failureInfoWithMessage:[log substringWithRange:[result rangeAtIndex:1]] file:[log substringWithRange:[result rangeAtIndex:3]] line:[[log substringWithRange:[result rangeAtIndex:4]] integerValue]];
      }
    response.add_log_output(log.UTF8String ?: "");
  }
  return response;
}

- (const idb::XctestRunResponse)responseForLogData:(NSData *)data
{
  idb::XctestRunResponse response;
  response.set_status(idb::XctestRunResponse_Status_RUNNING);
  response.add_log_output((char *) data.bytes, data.length);
  return response;
}

- (const idb::XctestRunResponse)responseForCrashMessage:(NSString *)message
{
  idb::XctestRunResponse response;
  response.set_status(idb::XctestRunResponse_Status_TERMINATED_ABNORMALLY);
  idb::XctestRunResponse_TestRunInfo *info = response.add_results();
  info->set_bundle_name(self.currentBundleName.UTF8String ?: "");
  info->set_class_name(self.currentTestClass.UTF8String ?: "");
  info->set_method_name(self.currentTestMethod.UTF8String ?: "");
  info->mutable_failure_info()->CopyFrom(self.failureInfo);
  info->set_status(idb::XctestRunResponse_TestRunInfo_Status_CRASHED);
  [self resetCurrentTestState];
  return response;
}

- (const idb::XctestRunResponse)responseForNormalTestTermination
{
  idb::XctestRunResponse response;
  response.set_status(idb::XctestRunResponse_Status_TERMINATED_NORMALLY);
  return response;
}

- (void)resetCurrentTestState
{
  [self.currentActivityRecords removeAllObjects];
  self.failureInfo = idb::XctestRunResponse_TestRunInfo_TestRunFailureInfo();
  self.currentTestMethod = nil;
  self.currentTestClass = nil;
}

- (void)writeTestRunInfo:(const idb::XctestRunResponse_TestRunInfo &)info
{
  idb::XctestRunResponse response;
  response.set_status(idb::XctestRunResponse_Status_RUNNING);
  response.add_results()->CopyFrom(info);
  [self writeResponse:response];
}

- (void)writeResponse:(const idb::XctestRunResponse &)response
{
  // If there's a result bundle and this is the last message, then append the result bundle.
  switch (response.status()) {
    case idb::XctestRunResponse_Status_TERMINATED_NORMALLY:
    case idb::XctestRunResponse_Status_TERMINATED_ABNORMALLY:
      [self insertResultBundleThenWriteResponse:response];
      return;
    default:
      break;
  }

  [self writeResponseFinal:response];
}

- (void)insertResultBundleThenWriteResponse:(const idb::XctestRunResponse &)response
{
  NSString *resultBundlePath = self.resultBundlePath;
  // No result bundle, just write it straight away.
  if (!resultBundlePath) {
    [self writeResponseFinal:response];
  }

  // Passing a reference to the response on the stack will lead to garbage memory unless we make a copy for the block.
  // https://github.com/facebook/infer/blob/master/infer/lib/linter_rules/linters.al#L212
  const idb::XctestRunResponse responseCaptured = response;
  [[FBArchiveOperations
    createGzippedTarDataForPath:resultBundlePath queue:self.queue logger:self.logger]
    onQueue:self.queue chain:^(FBFuture<NSData *> *future) {
      NSData *data = future.result;
      if (data) {
        // Make a local non-const copy so that we can mutate it.
        idb::XctestRunResponse responseWithPayload = responseCaptured;
        idb::Payload *payload = responseWithPayload.mutable_result_bundle();
        payload->set_data(data.bytes, data.length);
        [self writeResponseFinal:responseWithPayload];
      } else {
        [self.logger.info logFormat:@"Failed to create result bundle %@", future];
        [self writeResponseFinal:responseCaptured];
      }
      return future;
    }];

}

- (void)writeResponseFinal:(const idb::XctestRunResponse &)response
{
  @synchronized (self)
  {
    // Break out if the terminating condition happens twice.
    if (self.reportingTerminated.hasCompleted || self.writer == nil) {
      [self.logger.error log:@"writeResponse called, but the last response has already be written!!"];
      return;
    }

    self.writer->Write(response);

    // Update the terminal future to signify that reporting is done.
    switch (response.status()) {
      case idb::XctestRunResponse_Status_TERMINATED_NORMALLY:
      case idb::XctestRunResponse_Status_TERMINATED_ABNORMALLY:
        [self.logger logFormat:@"Test Reporting has finished with status %d", response.status()];
        [self.reportingTerminatedMutable resolveWithResult:@(response.status())];
        self.writer = nil;
        break;
      default:
        break;
    }
  }
}

@end
