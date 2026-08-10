#import "TXURLShortener.h"

NS_ASSUME_NONNULL_BEGIN

@implementation TXURLShortener

+ (nullable NSURL *)requestURLForService:(TXURLShortenerService)service
                             originalURL:(NSString *)originalURL
{
	/* Encode everything except unreserved characters so the original URL's
	 own query delimiters (and '+', which PHP decodes as a space) survive. */
	static NSCharacterSet *allowed = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		allowed = [NSCharacterSet characterSetWithCharactersInString:
			@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	});

	NSString *encoded = [originalURL stringByAddingPercentEncodingWithAllowedCharacters:allowed];

	if (encoded == nil) {
		return nil;
	}

	NSString *endpoint = nil;

	switch (service) {
		case TXURLShortenerServiceTinyURL:
			endpoint = @"https://tinyurl.com/api-create.php?url=";
			break;
		case TXURLShortenerServiceIsGd:
			endpoint = @"https://is.gd/create.php?format=simple&url=";
			break;
		case TXURLShortenerServiceVGd:
			endpoint = @"https://v.gd/create.php?format=simple&url=";
			break;
		default:
			return nil;
	}

	return [NSURL URLWithString:[endpoint stringByAppendingString:encoded]];
}

@end

NS_ASSUME_NONNULL_END
