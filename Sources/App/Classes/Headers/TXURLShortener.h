#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, TXURLShortenerService) {
	TXURLShortenerServiceTinyURL = 0,
	TXURLShortenerServiceIsGd = 1,
	TXURLShortenerServiceVGd = 2
};

@interface TXURLShortener : NSObject

#pragma mark - Pure helpers (exposed for testing)

/* Returns the GET request URL for shortening originalURL with service,
 or nil for an unknown service. originalURL is fully percent-encoded. */
+ (nullable NSURL *)requestURLForService:(TXURLShortenerService)service
                             originalURL:(NSString *)originalURL;

@end

NS_ASSUME_NONNULL_END
