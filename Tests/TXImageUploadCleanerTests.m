#import <Foundation/Foundation.h>
#import "../Sources/App/Classes/Headers/TXImageUploadCleaner.h"

static int gFailures = 0;
static void check(BOOL cond, const char *msg) {
	if (cond) { printf("PASS: %s\n", msg); }
	else { printf("FAIL: %s\n", msg); gFailures++; }
}

/* Answers every request with the status code registered for its URL
 (0 = transport failure) and records which URLs were requested. */
@interface StubProtocol : NSURLProtocol
@end

static NSMutableDictionary<NSString *, NSNumber *> *gStatusByURL;
static NSMutableArray<NSString *> *gRequestedURLs;

@implementation StubProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
	NSString *url = self.request.URL.absoluteString;
	NSInteger status;
	@synchronized (gRequestedURLs) {
		[gRequestedURLs addObject:url];
		status = gStatusByURL[url].integerValue;
	}
	if (status == 0) {
		[self.client URLProtocol:self didFailWithError:
			[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
		return;
	}
	NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
	                                                          statusCode:status
	                                                         HTTPVersion:@"HTTP/1.1"
	                                                        headerFields:nil];
	[self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
	[self.client URLProtocol:self didLoadData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
	[self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading { }
@end

static NSString * const kSuite = @"TXImageUploadCleanerTests";

static NSUserDefaults *freshDefaults(void) {
	NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuite];
	[defaults removePersistentDomainForName:kSuite];
	return defaults;
}

static TXImageUploadCleaner *cleanerWithDefaults(NSUserDefaults *defaults) {
	NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
	config.protocolClasses = @[[StubProtocol class]];

	TXImageUploadCleaner *cleaner = [[TXImageUploadCleaner alloc] initWithUserDefaults:defaults];
	cleaner.session = [NSURLSession sessionWithConfiguration:config];
	return cleaner;
}

/* Runs a sweep and spins the main run loop until its completion fires. */
static BOOL sweep(TXImageUploadCleaner *cleaner, NSDate *now) {
	__block BOOL done = NO;
	[cleaner deleteUploadsDueAt:now completion:^{ done = YES; }];
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
	while (done == NO && [deadline timeIntervalSinceNow] > 0) {
		[[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
		                      beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
	}
	return done;
}

static NSString *deleteURL(NSString *key) {
	return [@"https://kappa.lol/api/delete?key=" stringByAppendingString:key];
}

static NSArray<NSString *> *pendingKeys(TXImageUploadCleaner *cleaner) {
	return [cleaner.pendingDeletions valueForKey:@"key"];
}

static void testForgetRules(void) {
	check([TXImageUploadCleaner shouldForgetDeletionForStatusCode:200], "200 -> deleted, forget");
	check([TXImageUploadCleaner shouldForgetDeletionForStatusCode:400], "400 -> already gone or bad key, forget");
	check([TXImageUploadCleaner shouldForgetDeletionForStatusCode:404], "404 -> already gone, forget");
	check([TXImageUploadCleaner shouldForgetDeletionForStatusCode:500] == NO, "500 -> keep and retry");
	check([TXImageUploadCleaner shouldForgetDeletionForStatusCode:429] == NO, "429 -> keep and retry");
	check([TXImageUploadCleaner shouldForgetDeletionForStatusCode:0] == NO, "no response -> keep and retry");
}

static void testRecording(void) {
	NSUserDefaults *defaults = freshDefaults();
	TXImageUploadCleaner *cleaner = cleanerWithDefaults(defaults);
	NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000000];

	check(cleaner.pendingDeletions.count == 0, "starts with nothing pending");

	[cleaner deleteUploadWithKey:@"AAA" service:TXImageUploadServiceKappaLol after:[now dateByAddingTimeInterval:3600]];
	[cleaner deleteUploadWithKey:@"BBB" service:TXImageUploadServiceKappaLol after:[now dateByAddingTimeInterval:7200]];
	check(cleaner.pendingDeletions.count == 2, "two deletions recorded");

	[cleaner deleteUploadWithKey:@"CCC" service:TXImageUploadServiceX0At after:now];
	check(cleaner.pendingDeletions.count == 2, "a service that cannot delete is not recorded");

	[cleaner deleteUploadWithKey:@"" service:TXImageUploadServiceKappaLol after:now];
	check(cleaner.pendingDeletions.count == 2, "an empty key is not recorded");

	TXImageUploadCleaner *reloaded = cleanerWithDefaults([[NSUserDefaults alloc] initWithSuiteName:kSuite]);
	check([pendingKeys(reloaded) isEqualToArray:@[@"AAA", @"BBB"]], "pending deletions survive a new instance");
}

static void testSweep(void) {
	NSUserDefaults *defaults = freshDefaults();
	TXImageUploadCleaner *cleaner = cleanerWithDefaults(defaults);
	NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000000];

	[cleaner deleteUploadWithKey:@"DUE" service:TXImageUploadServiceKappaLol after:[now dateByAddingTimeInterval:-60]];
	[cleaner deleteUploadWithKey:@"GONE" service:TXImageUploadServiceKappaLol after:[now dateByAddingTimeInterval:-60]];
	[cleaner deleteUploadWithKey:@"FAIL" service:TXImageUploadServiceKappaLol after:[now dateByAddingTimeInterval:-60]];
	[cleaner deleteUploadWithKey:@"OFFLINE" service:TXImageUploadServiceKappaLol after:[now dateByAddingTimeInterval:-60]];
	[cleaner deleteUploadWithKey:@"LATER" service:TXImageUploadServiceKappaLol after:[now dateByAddingTimeInterval:3600]];

	gStatusByURL[deleteURL(@"DUE")] = @200;
	gStatusByURL[deleteURL(@"GONE")] = @400;
	gStatusByURL[deleteURL(@"FAIL")] = @500;
	gStatusByURL[deleteURL(@"OFFLINE")] = @0;
	[gRequestedURLs removeAllObjects];

	check(sweep(cleaner, now), "sweep completes");
	check(gRequestedURLs.count == 4, "only due uploads are requested");
	check([gRequestedURLs containsObject:deleteURL(@"LATER")] == NO, "an upload that is not due yet is left alone");
	check([pendingKeys(cleaner) isEqualToArray:@[@"FAIL", @"OFFLINE", @"LATER"]],
		"deleted and already-gone uploads are forgotten; failures stay for a retry");

	gStatusByURL[deleteURL(@"FAIL")] = @200;
	gStatusByURL[deleteURL(@"OFFLINE")] = @200;
	[gRequestedURLs removeAllObjects];

	check(sweep(cleaner, now), "second sweep completes");
	check(gRequestedURLs.count == 2, "the retry only requests what is still pending and due");
	check([pendingKeys(cleaner) isEqualToArray:@[@"LATER"]], "retried deletions are forgotten once they succeed");

	[gRequestedURLs removeAllObjects];
	check(sweep(cleaner, now), "sweep with nothing due completes");
	check(gRequestedURLs.count == 0, "nothing is requested when nothing is due");

	check(sweep(cleaner, [now dateByAddingTimeInterval:3601]) == YES, "sweep after the due time completes");
	check([gRequestedURLs isEqualToArray:@[deleteURL(@"LATER")]], "the upload is deleted once its time has passed");
}

static void testMalformedStoredEntries(void) {
	NSUserDefaults *defaults = freshDefaults();
	[defaults setObject:@[@"junk", @{@"key": @"NOSERVICE"}, @{@"service": @2, @"key": @"OK", @"deleteAfter": @10}]
	             forKey:@"ImageUploadPendingDeletions"];

	TXImageUploadCleaner *cleaner = cleanerWithDefaults(defaults);
	gStatusByURL[deleteURL(@"OK")] = @200;
	[gRequestedURLs removeAllObjects];

	check(sweep(cleaner, [NSDate dateWithTimeIntervalSince1970:1000]), "sweep over malformed entries completes");
	check([gRequestedURLs isEqualToArray:@[deleteURL(@"OK")]], "well-formed entry is still processed");
	check(cleaner.pendingDeletions.count == 0, "malformed entries are dropped");
}

int main(void) { @autoreleasepool {
	gStatusByURL = [NSMutableDictionary dictionary];
	gRequestedURLs = [NSMutableArray array];

	testForgetRules();
	testRecording();
	testSweep();
	testMalformedStoredEntries();

	[[[NSUserDefaults alloc] initWithSuiteName:kSuite] removePersistentDomainForName:kSuite];

	printf(gFailures ? "\n%d FAILURE(S)\n" : "\nALL PASSED\n", gFailures);
	return gFailures ? 1 : 0;
} }
