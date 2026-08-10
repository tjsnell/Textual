#import <Foundation/Foundation.h>
#import "../Sources/App/Classes/Headers/TXURLShortener.h"

static int gFailures = 0;
static void check(BOOL cond, const char *msg) {
	if (cond) { printf("PASS: %s\n", msg); }
	else { printf("FAIL: %s\n", msg); gFailures++; }
}

static void testRequestURLBuilding(void) {
	NSString *plain = @"https://example.com/page";

	NSURL *tiny = [TXURLShortener requestURLForService:TXURLShortenerServiceTinyURL originalURL:plain];
	check([tiny.absoluteString isEqualToString:
		@"https://tinyurl.com/api-create.php?url=https%3A%2F%2Fexample.com%2Fpage"],
		"tinyurl endpoint with encoded url");

	NSURL *isgd = [TXURLShortener requestURLForService:TXURLShortenerServiceIsGd originalURL:plain];
	check([isgd.absoluteString isEqualToString:
		@"https://is.gd/create.php?format=simple&url=https%3A%2F%2Fexample.com%2Fpage"],
		"is.gd endpoint with encoded url");

	NSURL *vgd = [TXURLShortener requestURLForService:TXURLShortenerServiceVGd originalURL:plain];
	check([vgd.absoluteString isEqualToString:
		@"https://v.gd/create.php?format=simple&url=https%3A%2F%2Fexample.com%2Fpage"],
		"v.gd endpoint with encoded url");

	NSURL *tricky = [TXURLShortener requestURLForService:TXURLShortenerServiceTinyURL
	                                         originalURL:@"https://example.com/a?b=c&d=e+f"];
	check([tricky.absoluteString isEqualToString:
		@"https://tinyurl.com/api-create.php?url=https%3A%2F%2Fexample.com%2Fa%3Fb%3Dc%26d%3De%2Bf"],
		"query characters and plus fully percent-encoded");
}

static void testResponseValidation(void) {
	NSError *err = nil;

	NSData *ok = [@"https://tinyurl.com/abc123\n" dataUsingEncoding:NSUTF8StringEncoding];
	NSString *url = [TXURLShortener shortURLFromResponseData:ok statusCode:200 error:&err];
	check([url isEqualToString:@"https://tinyurl.com/abc123"], "200 + url body -> trimmed url");
	check(err == nil, "success leaves error nil");

	err = nil;
	NSData *httpOK = [@"http://tinyurl.com/abc123" dataUsingEncoding:NSUTF8StringEncoding];
	url = [TXURLShortener shortURLFromResponseData:httpOK statusCode:200 error:&err];
	check([url isEqualToString:@"http://tinyurl.com/abc123"], "http scheme accepted");

	err = nil;
	NSData *isgdError = [@"Error: Please enter a valid URL to shorten" dataUsingEncoding:NSUTF8StringEncoding];
	url = [TXURLShortener shortURLFromResponseData:isgdError statusCode:200 error:&err];
	check(url == nil && err != nil, "200 + error body -> error");

	err = nil;
	url = [TXURLShortener shortURLFromResponseData:ok statusCode:503 error:&err];
	check(url == nil && err != nil, "non-2xx status -> error");

	err = nil;
	url = [TXURLShortener shortURLFromResponseData:nil statusCode:200 error:&err];
	check(url == nil && err != nil, "nil body -> error");

	err = nil;
	NSData *multiword = [@"https://is.gd/x y junk" dataUsingEncoding:NSUTF8StringEncoding];
	url = [TXURLShortener shortURLFromResponseData:multiword statusCode:200 error:&err];
	check(url == nil && err != nil, "body with embedded whitespace -> error");
}

static void testURLDetection(void) {
	NSArray *urls;

	urls = [TXURLShortener shortenableURLsInString:
		@"check this https://example.com/some/very/long/path/that/keeps/going out"
	                                 minimumLength:40];
	check(urls.count == 1 &&
		[urls[0] isEqualToString:@"https://example.com/some/very/long/path/that/keeps/going"],
		"long https url detected");

	urls = [TXURLShortener shortenableURLsInString:@"see https://ex.co/a" minimumLength:40];
	check(urls.count == 0, "short url below threshold ignored");

	urls = [TXURLShortener shortenableURLsInString:
		@"ftp://example.com/some/very/long/path/that/keeps/going/x" minimumLength:40];
	check(urls.count == 0, "non-http scheme ignored");

	urls = [TXURLShortener shortenableURLsInString:
		@"www.example.com/some/very/long/path/that/keeps/going/xy" minimumLength:40];
	check(urls.count == 0, "schemeless link ignored");

	urls = [TXURLShortener shortenableURLsInString:
		@"/topic https://example.com/some/very/long/path/that/keeps/going" minimumLength:40];
	check(urls.count == 0, "slash command not processed");

	urls = [TXURLShortener shortenableURLsInString:
		@"/me shares https://example.com/some/very/long/path/that/keeps/going" minimumLength:40];
	check(urls.count == 1, "/me action processed");

	urls = [TXURLShortener shortenableURLsInString:
		@"https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa and "
		@"https://example.com/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb and "
		@"https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	                                 minimumLength:40];
	check(urls.count == 2, "multiple urls deduplicated");
}

static void testSubstitution(void) {
	NSDictionary *mapping = @{
		@"https://example.com/some/very/long/path/that/keeps/going": @"https://tinyurl.com/abc123"
	};

	NSString *result =
	[TXURLShortener string:@"check https://example.com/some/very/long/path/that/keeps/going out"
	   byApplyingShortURLs:mapping];
	check([result isEqualToString:@"check https://tinyurl.com/abc123 out"],
		"url replaced inside message");

	result = [TXURLShortener string:@"https://a.co/b"
	            byApplyingShortURLs:@{@"https://a.co/b": @"https://tinyurl.com/longer-than-original"}];
	check([result isEqualToString:@"https://a.co/b"],
		"replacement longer than original keeps original");

	NSAttributedString *attributed =
	[[NSAttributedString alloc] initWithString:
		@"see https://example.com/some/very/long/path/that/keeps/going twice "
		@"https://example.com/some/very/long/path/that/keeps/going"];
	NSAttributedString *attributedResult =
	[TXURLShortener attributedString:attributed byApplyingShortURLs:mapping];
	check([attributedResult.string isEqualToString:
		@"see https://tinyurl.com/abc123 twice https://tinyurl.com/abc123"],
		"attributed string replaces every occurrence");

	NSDictionary *overlapping = @{
		@"https://example.com/some/very/long/path/that/keeps/going": @"https://is.gd/AAA1",
		@"https://example.com/some/very/long/path/that/keeps/going/further": @"https://is.gd/BBB2"
	};

	result = [TXURLShortener string:@"a https://example.com/some/very/long/path/that/keeps/going/further b https://example.com/some/very/long/path/that/keeps/going c"
	            byApplyingShortURLs:overlapping];
	check([result isEqualToString:@"a https://is.gd/BBB2 b https://is.gd/AAA1 c"],
		"longer overlapping url replaced before its prefix");

	result = [TXURLShortener string:
		@"see https://example.com/some/very/long/path/that/keeps/going/further and https://example.com/some/very/long/path/that/keeps/going"
	            byApplyingShortURLs:@{
		@"https://example.com/some/very/long/path/that/keeps/going": @"https://is.gd/AAA1"
	}];
	check([result isEqualToString:
		@"see https://example.com/some/very/long/path/that/keeps/going/further and https://is.gd/AAA1"],
		"failed longer url not corrupted by its successful prefix");
}

int main(void) { @autoreleasepool {
	testRequestURLBuilding();
	testResponseValidation();
	testURLDetection();
	testSubstitution();
	printf(gFailures ? "\n%d FAILURE(S)\n" : "\nALL PASSED\n", gFailures);
	return gFailures ? 1 : 0;
} }
