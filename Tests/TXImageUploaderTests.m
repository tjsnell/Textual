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

int main(void) { @autoreleasepool {
	testMultipartBody();
	printf(gFailures ? "\n%d FAILURE(S)\n" : "\nALL PASSED\n", gFailures);
	return gFailures ? 1 : 0;
} }
