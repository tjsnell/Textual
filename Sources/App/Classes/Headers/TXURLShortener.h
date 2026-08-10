#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, TXURLShortenerService) {
	TXURLShortenerServiceTinyURL = 0,
	TXURLShortenerServiceIsGd = 1,
	TXURLShortenerServiceVGd = 2
};

@interface TXURLShortener : NSObject

/* Injectable for testing; defaults to +[NSURLSession sharedSession]. */
@property (nonatomic, strong) NSURLSession *session;

/* Shortens every URL in urls concurrently using service. completion is
 always called on the main queue with a mapping of original URL ->
 shortened URL. URLs whose request failed, returned an invalid body, or
 timed out (10s) are simply absent from the mapping. */
- (void)shortenURLs:(NSArray<NSString *> *)urls
            service:(TXURLShortenerService)service
         completion:(void (^)(NSDictionary<NSString *, NSString *> *shortURLs))completion;

#pragma mark - Pure helpers (exposed for testing)

/* Returns the GET request URL for shortening originalURL with service,
 or nil for an unknown service. originalURL is fully percent-encoded. */
+ (nullable NSURL *)requestURLForService:(TXURLShortenerService)service
                             originalURL:(NSString *)originalURL;

/* Validates a shortener response. Returns the short URL, or nil with error
 set, when the status is non-2xx or the body is not a single http(s) URL
 (is.gd/v.gd report failures as an "Error: ..." text body). */
+ (nullable NSString *)shortURLFromResponseData:(nullable NSData *)data
                                     statusCode:(NSInteger)statusCode
                                          error:(NSError * _Nullable * _Nullable)error;

/* Returns the unique http(s) URLs in string, as they literally appear, whose
 length is >= minimumLength. Returns an empty array for slash commands other
 than "/me ". */
+ (NSArray<NSString *> *)shortenableURLsInString:(NSString *)string
                                   minimumLength:(NSUInteger)minimumLength;

/* Replace each key of shortURLs with its value. Mappings whose replacement
 is not strictly shorter than the original are skipped. */
+ (NSString *)string:(NSString *)string
 byApplyingShortURLs:(NSDictionary<NSString *, NSString *> *)shortURLs;

+ (NSAttributedString *)attributedString:(NSAttributedString *)string
                     byApplyingShortURLs:(NSDictionary<NSString *, NSString *> *)shortURLs;

@end

NS_ASSUME_NONNULL_END
