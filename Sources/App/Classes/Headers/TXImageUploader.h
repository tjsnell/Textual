#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Values are persisted in the ImageUploadService preference; do not renumber. */
typedef NS_ENUM(NSUInteger, TXImageUploadService) {
	TXImageUploadServiceLitterbox = 0, /* was catbox.moe; Litterbox is its temporary sibling */
	TXImageUploadServiceX0At = 1,
	TXImageUploadServiceKappaLol = 2,
	TXImageUploadServiceNuuls = 3,
	TXImageUploadServiceUguu = 4
};

@interface TXImageUploader : NSObject

/* Injectable for testing; defaults to +[NSURLSession sharedSession]. */
@property (nonatomic, strong) NSURLSession *session;

/* Uploads PNG data to service. completion is always called on the main queue.
 On success, url is the direct https URL and error is nil. On failure, url is nil.

 retentionHours is how long the image should be kept; 0 means forever. Only
 Litterbox applies it at upload time (it has no forever: 0 becomes its 72h
 maximum). deleteKey is non-nil when the service lets the upload be deleted
 later with +deleteRequestURLForService:deleteKey: (kappa.lol). */
- (void)uploadImageData:(NSData *)data
               filename:(NSString *)filename
                service:(TXImageUploadService)service
         retentionHours:(NSUInteger)retentionHours
             completion:(void (^)(NSString * _Nullable url,
                                  NSString * _Nullable deleteKey,
                                  NSError * _Nullable error))completion;

#pragma mark - Pure helpers (exposed for testing)

/* Returns the POST endpoint for service, or nil for an unknown service. */
+ (nullable NSURL *)requestURLForService:(TXImageUploadService)service;

/* YES when a retention period can be honored for service, either by the
 host itself (Litterbox) or by deleting the upload later (kappa.lol). */
+ (BOOL)serviceSupportsRetention:(TXImageUploadService)service;

+ (NSData *)multipartBodyForImageData:(NSData *)data
                             filename:(NSString *)filename
                             boundary:(NSString *)boundary
                              service:(TXImageUploadService)service
                       retentionHours:(NSUInteger)retentionHours;

/* Validates an upload response. Returns the direct image URL, or nil with
 error set, when the status is not 200 or the body does not carry a single
 https URL (plain text for most services, JSON for kappa.lol). */
+ (nullable NSString *)urlFromResponseData:(nullable NSData *)data
                                statusCode:(NSInteger)statusCode
                                   service:(TXImageUploadService)service
                                     error:(NSError * _Nullable * _Nullable)error;

/* Returns the key that deletes the upload described by an upload response,
 or nil when service does not offer one. */
+ (nullable NSString *)deleteKeyFromResponseData:(nullable NSData *)data
                                         service:(TXImageUploadService)service;

/* Returns the GET request URL that deletes an upload, or nil when service
 does not support deletion. */
+ (nullable NSURL *)deleteRequestURLForService:(TXImageUploadService)service
                                     deleteKey:(NSString *)deleteKey;

@end

NS_ASSUME_NONNULL_END
