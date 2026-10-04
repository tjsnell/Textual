#import <Foundation/Foundation.h>

#import "TXImageUploader.h"

NS_ASSUME_NONNULL_BEGIN

/* Deletes uploaded images once their retention period has passed, for
 services that cannot expire an upload themselves but hand back a delete
 key (kappa.lol). Pending deletions are persisted in user defaults so they
 survive a relaunch; a deletion that falls due while the app is not running
 is performed at the next launch. Main thread only. */
@interface TXImageUploadCleaner : NSObject

/* Set once at launch by the app; nil until then. */
@property (class, nonatomic, strong, nullable) TXImageUploadCleaner *sharedCleaner;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithUserDefaults:(NSUserDefaults *)userDefaults NS_DESIGNATED_INITIALIZER;

/* Injectable for testing; defaults to +[NSURLSession sharedSession]. */
@property (nonatomic, strong) NSURLSession *session;

/* Well-formed pending deletions, oldest first. Each entry has the keys
 "service" (TXImageUploadService), "key" and "deleteAfter" (seconds since 1970). */
@property (readonly, copy) NSArray<NSDictionary<NSString *, id> *> *pendingDeletions;

/* Remembers that the upload identified by deleteKey should be deleted once
 date has passed. Ignored when service does not support deletion. */
- (void)deleteUploadWithKey:(NSString *)deleteKey
                    service:(TXImageUploadService)service
                      after:(NSDate *)date;

/* Deletes whatever is already due, then checks again every few minutes. */
- (void)startMonitoring;

/* Requests deletion of every pending upload due at now. An entry is forgotten
 when the service confirms the deletion or reports the upload is already gone;
 it is kept for the next check on a transport or server error. completion is
 called on the main queue once every request has finished. */
- (void)deleteUploadsDueAt:(NSDate *)now completion:(nullable void (^)(void))completion;

#pragma mark - Pure helpers (exposed for testing)

+ (BOOL)shouldForgetDeletionForStatusCode:(NSInteger)statusCode;

@end

NS_ASSUME_NONNULL_END
