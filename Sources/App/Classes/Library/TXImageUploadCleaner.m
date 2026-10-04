#import "TXImageUploadCleaner.h"

NS_ASSUME_NONNULL_BEGIN

static NSString * const TXImageUploadCleanerDefaultsKey = @"ImageUploadPendingDeletions";

static NSString * const TXImageUploadCleanerServiceKey = @"service";
static NSString * const TXImageUploadCleanerDeleteKeyKey = @"key";
static NSString * const TXImageUploadCleanerDeleteAfterKey = @"deleteAfter";

static const NSTimeInterval TXImageUploadCleanerCheckInterval = (5 * 60);
static const NSTimeInterval TXImageUploadCleanerRequestTimeout = 15;

static TXImageUploadCleaner * _Nullable gSharedCleaner = nil;

@interface TXImageUploadCleaner ()
@property (nonatomic, strong) NSUserDefaults *userDefaults;
@property (nonatomic, strong, nullable) NSTimer *timer;
/* Entries whose delete request has not answered yet, so that overlapping
 checks never request the same deletion twice. */
@property (nonatomic, strong) NSMutableSet<NSDictionary<NSString *, id> *> *entriesInFlight;
@end

@implementation TXImageUploadCleaner

+ (nullable TXImageUploadCleaner *)sharedCleaner
{
	return gSharedCleaner;
}

+ (void)setSharedCleaner:(nullable TXImageUploadCleaner *)sharedCleaner
{
	gSharedCleaner = sharedCleaner;
}

- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults
{
	if ((self = [super init])) {
		self.userDefaults = userDefaults;

		self.entriesInFlight = [NSMutableSet set];
	}

	return self;
}

- (void)dealloc
{
	[self.timer invalidate];
}

- (NSURLSession *)session
{
	if (self->_session == nil) {
		self->_session = [NSURLSession sharedSession];
	}
	return self->_session;
}

+ (BOOL)shouldForgetDeletionForStatusCode:(NSInteger)statusCode
{
	/* kappa.lol answers 400 for a key it no longer knows. */
	return (statusCode == 200 || statusCode == 400 || statusCode == 404);
}

#pragma mark - Storage

+ (BOOL)isWellFormedEntry:(id)entry
{
	if ([entry isKindOfClass:[NSDictionary class]] == NO) {
		return NO;
	}

	id service = entry[TXImageUploadCleanerServiceKey];
	id deleteKey = entry[TXImageUploadCleanerDeleteKeyKey];
	id deleteAfter = entry[TXImageUploadCleanerDeleteAfterKey];

	return ([service isKindOfClass:[NSNumber class]] &&
			[deleteKey isKindOfClass:[NSString class]] && [deleteKey length] > 0 &&
			[deleteAfter isKindOfClass:[NSNumber class]]);
}

- (NSArray<NSDictionary<NSString *, id> *> *)pendingDeletions
{
	NSArray *stored = [self.userDefaults arrayForKey:TXImageUploadCleanerDefaultsKey];

	NSMutableArray *entries = [NSMutableArray arrayWithCapacity:stored.count];

	for (id entry in stored) {
		if ([[self class] isWellFormedEntry:entry]) {
			[entries addObject:entry];
		}
	}

	return entries;
}

- (void)setPendingDeletions:(NSArray<NSDictionary<NSString *, id> *> *)pendingDeletions
{
	if (pendingDeletions.count == 0) {
		[self.userDefaults removeObjectForKey:TXImageUploadCleanerDefaultsKey];
	} else {
		[self.userDefaults setObject:pendingDeletions forKey:TXImageUploadCleanerDefaultsKey];
	}
}

- (void)forgetEntry:(NSDictionary<NSString *, id> *)entry
{
	NSMutableArray *entries = [self.pendingDeletions mutableCopy];

	[entries removeObject:entry];

	[self setPendingDeletions:entries];
}

#pragma mark - Public

- (void)deleteUploadWithKey:(NSString *)deleteKey
                    service:(TXImageUploadService)service
                      after:(NSDate *)date
{
	if (deleteKey.length == 0 ||
		[TXImageUploader deleteRequestURLForService:service deleteKey:deleteKey] == nil)
	{
		return;
	}

	NSArray *entries = [self.pendingDeletions arrayByAddingObject:@{
		TXImageUploadCleanerServiceKey : @(service),
		TXImageUploadCleanerDeleteKeyKey : deleteKey,
		TXImageUploadCleanerDeleteAfterKey : @(date.timeIntervalSince1970)
	}];

	[self setPendingDeletions:entries];
}

- (void)startMonitoring
{
	if (self.timer != nil) {
		return;
	}

	__weak TXImageUploadCleaner *weakSelf = self;

	self.timer = [NSTimer scheduledTimerWithTimeInterval:TXImageUploadCleanerCheckInterval
	                                             repeats:YES
	                                               block:^(NSTimer *timer) {
		[weakSelf deleteUploadsDueAt:[NSDate date] completion:nil];
	}];

	[self deleteUploadsDueAt:[NSDate date] completion:nil];
}

- (void)deleteUploadsDueAt:(NSDate *)now completion:(nullable void (^)(void))completion
{
	dispatch_group_t group = dispatch_group_create();

	NSTimeInterval nowInterval = now.timeIntervalSince1970;

	for (NSDictionary<NSString *, id> *entry in self.pendingDeletions) {
		if ([entry[TXImageUploadCleanerDeleteAfterKey] doubleValue] > nowInterval ||
			[self.entriesInFlight containsObject:entry])
		{
			continue;
		}

		NSURL *requestURL =
			[TXImageUploader deleteRequestURLForService:[entry[TXImageUploadCleanerServiceKey] unsignedIntegerValue]
			                                 deleteKey:entry[TXImageUploadCleanerDeleteKeyKey]];

		if (requestURL == nil) {
			/* Recorded for a service that can no longer delete; nothing to retry. */
			[self forgetEntry:entry];

			continue;
		}

		NSURLRequest *request = [NSURLRequest requestWithURL:requestURL
		                                         cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
		                                     timeoutInterval:TXImageUploadCleanerRequestTimeout];

		[self.entriesInFlight addObject:entry];

		dispatch_group_enter(group);

		NSURLSessionDataTask *task =
			[self.session dataTaskWithRequest:request
			                completionHandler:^(NSData * _Nullable data,
			                                    NSURLResponse * _Nullable response,
			                                    NSError * _Nullable error)
		{
			NSInteger status = 0;

			if (error == nil && [response isKindOfClass:[NSHTTPURLResponse class]]) {
				status = ((NSHTTPURLResponse *)response).statusCode;
			}

			dispatch_async(dispatch_get_main_queue(), ^{
				[self.entriesInFlight removeObject:entry];

				if ([[self class] shouldForgetDeletionForStatusCode:status]) {
					[self forgetEntry:entry];
				}

				dispatch_group_leave(group);
			});
		}];

		[task resume];
	}

	dispatch_group_notify(group, dispatch_get_main_queue(), ^{
		if (completion) {
			completion();
		}
	});
}

@end

NS_ASSUME_NONNULL_END
