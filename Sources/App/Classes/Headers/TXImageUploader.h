#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TXImageUploader : NSObject

/* Injectable for testing; defaults to +[NSURLSession sharedSession]. */
@property (nonatomic, strong) NSURLSession *session;

/* Uploads PNG data to catbox.moe. completion is always called on the main queue.
 On success, url is the direct https URL and error is nil. On failure, url is nil. */
- (void)uploadImageData:(NSData *)data
               filename:(NSString *)filename
             completion:(void (^)(NSString * _Nullable url, NSError * _Nullable error))completion;

#pragma mark - Pure helpers (exposed for testing)

+ (NSData *)multipartBodyForImageData:(NSData *)data
                             filename:(NSString *)filename
                             boundary:(NSString *)boundary;

+ (nullable NSString *)urlFromResponseData:(nullable NSData *)data
                                statusCode:(NSInteger)statusCode
                                     error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
