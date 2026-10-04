#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Values are persisted in the ImageUploadService preference; do not renumber. */
typedef NS_ENUM(NSUInteger, TXImageUploadService) {
	TXImageUploadServiceCatbox = 0,
	TXImageUploadServiceX0At = 1,
	TXImageUploadServiceKappaLol = 2,
	TXImageUploadServiceNuuls = 3,
	TXImageUploadServiceUguu = 4
};

@interface TXImageUploader : NSObject

/* Injectable for testing; defaults to +[NSURLSession sharedSession]. */
@property (nonatomic, strong) NSURLSession *session;

/* Uploads PNG data to service. completion is always called on the main queue.
 On success, url is the direct https URL and error is nil. On failure, url is nil. */
- (void)uploadImageData:(NSData *)data
               filename:(NSString *)filename
                service:(TXImageUploadService)service
             completion:(void (^)(NSString * _Nullable url, NSError * _Nullable error))completion;

#pragma mark - Pure helpers (exposed for testing)

/* Returns the POST endpoint for service, or nil for an unknown service. */
+ (nullable NSURL *)requestURLForService:(TXImageUploadService)service;

+ (NSData *)multipartBodyForImageData:(NSData *)data
                             filename:(NSString *)filename
                             boundary:(NSString *)boundary
                              service:(TXImageUploadService)service;

/* Validates an upload response. Returns the direct image URL, or nil with
 error set, when the status is not 200 or the body does not carry a single
 https URL (plain text for most services, JSON for kappa.lol). */
+ (nullable NSString *)urlFromResponseData:(nullable NSData *)data
                                statusCode:(NSInteger)statusCode
                                   service:(TXImageUploadService)service
                                     error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
