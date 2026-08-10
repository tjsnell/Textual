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

int main(void) { @autoreleasepool {
	testRequestURLBuilding();
	printf(gFailures ? "\n%d FAILURE(S)\n" : "\nALL PASSED\n", gFailures);
	return gFailures ? 1 : 0;
} }
