#import "TXURLShortener.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TXURLShortenerErrorCode) {
	TXURLShortenerErrorBadResponse = -1000
};

static NSString * _Nullable TXURLShortenerSetError(NSError * _Nullable * _Nullable error,
                                                   NSInteger code,
                                                   NSString *message)
{
	if (error) {
		*error = [NSError errorWithDomain:@"TXURLShortenerErrorDomain"
		                             code:code
		                         userInfo:@{NSLocalizedDescriptionKey: message}];
	}
	return nil;
}

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

+ (nullable NSString *)shortURLFromResponseData:(nullable NSData *)data
                                     statusCode:(NSInteger)statusCode
                                          error:(NSError * _Nullable * _Nullable)error
{
	if (statusCode < 200 || statusCode > 299) {
		return TXURLShortenerSetError(error, statusCode,
			[NSString stringWithFormat:@"Server returned status %ld", (long)statusCode]);
	}

	if (data.length == 0) {
		return TXURLShortenerSetError(error, TXURLShortenerErrorBadResponse,
			@"Empty response from server");
	}

	NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	NSString *trimmed = [body stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	BOOL looksLikeURL =
	([trimmed hasPrefix:@"https://"] || [trimmed hasPrefix:@"http://"]);

	if (looksLikeURL == NO ||
		[trimmed rangeOfCharacterFromSet:
			[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
	{
		return TXURLShortenerSetError(error, TXURLShortenerErrorBadResponse,
			trimmed.length ? trimmed : @"Unexpected response from server");
	}

	return trimmed;
}

@end

NS_ASSUME_NONNULL_END
