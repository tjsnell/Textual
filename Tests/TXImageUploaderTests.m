#import <Foundation/Foundation.h>
#import "../Sources/App/Classes/Headers/TXImageUploader.h"

static int gFailures = 0;
static void check(BOOL cond, const char *msg) {
	if (cond) { printf("PASS: %s\n", msg); }
	else { printf("FAIL: %s\n", msg); gFailures++; }
}

static void testMultipartBody(void) {
	NSData *image = [@"PNGDATA" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *body = [TXImageUploader multipartBodyForImageData:image
	                                                 filename:@"image.png"
	                                                 boundary:@"BOUND"];
	NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];

	check([s hasPrefix:@"--BOUND\r\n"], "body starts with boundary");
	check([s containsString:@"name=\"reqtype\"\r\n\r\nfileupload\r\n"], "has reqtype field");
	check([s containsString:@"name=\"fileToUpload\"; filename=\"image.png\""], "has file field with filename");
	check([s containsString:@"Content-Type: image/png\r\n\r\nPNGDATA\r\n"], "has content-type and payload");
	check([s hasSuffix:@"--BOUND--\r\n"], "body ends with closing boundary");
}

static void testResponseParsing(void) {
	NSError *err = nil;

	NSData *ok = [@"https://files.catbox.moe/ab12cd.png\n" dataUsingEncoding:NSUTF8StringEncoding];
	NSString *url = [TXImageUploader urlFromResponseData:ok statusCode:200 error:&err];
	check([url isEqualToString:@"https://files.catbox.moe/ab12cd.png"], "200 + url body -> trimmed url");
	check(err == nil, "success leaves error nil");

	err = nil;
	NSData *bad = [@"Something went wrong." dataUsingEncoding:NSUTF8StringEncoding];
	url = [TXImageUploader urlFromResponseData:bad statusCode:200 error:&err];
	check(url == nil && err != nil, "200 + non-url body -> error");

	err = nil;
	url = [TXImageUploader urlFromResponseData:ok statusCode:503 error:&err];
	check(url == nil && err != nil, "non-200 status -> error");

	err = nil;
	url = [TXImageUploader urlFromResponseData:nil statusCode:200 error:&err];
	check(url == nil && err != nil, "nil body -> error");
}

int main(void) { @autoreleasepool {
	testMultipartBody();
	testResponseParsing();
	printf(gFailures ? "\n%d FAILURE(S)\n" : "\nALL PASSED\n", gFailures);
	return gFailures ? 1 : 0;
} }
