#import <Foundation/Foundation.h>
#import "../Sources/App/Classes/Headers/TXImageUploader.h"

static int gFailures = 0;
static void check(BOOL cond, const char *msg) {
	if (cond) { printf("PASS: %s\n", msg); }
	else { printf("FAIL: %s\n", msg); gFailures++; }
}

static NSString *bodyString(TXImageUploadService service) {
	NSData *image = [@"PNGDATA" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *body = [TXImageUploader multipartBodyForImageData:image
	                                                 filename:@"image.png"
	                                                 boundary:@"BOUND"
	                                                  service:service];
	return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
}

static NSString *parse(NSString * _Nullable body, NSInteger status, TXImageUploadService service, NSError **err) {
	return [TXImageUploader urlFromResponseData:[body dataUsingEncoding:NSUTF8StringEncoding]
	                                 statusCode:status
	                                    service:service
	                                      error:err];
}

static void testRequestURLs(void) {
	check([[TXImageUploader requestURLForService:TXImageUploadServiceCatbox].absoluteString
		isEqualToString:@"https://catbox.moe/user/api.php"], "catbox request URL");
	check([[TXImageUploader requestURLForService:TXImageUploadServiceX0At].absoluteString
		isEqualToString:@"https://x0.at/"], "x0.at request URL");
	check([[TXImageUploader requestURLForService:TXImageUploadServiceKappaLol].absoluteString
		isEqualToString:@"https://kappa.lol/api/upload"], "kappa.lol request URL");
	check([[TXImageUploader requestURLForService:TXImageUploadServiceNuuls].absoluteString
		isEqualToString:@"https://i.nuuls.com/upload"], "i.nuuls.com request URL");
	check([[TXImageUploader requestURLForService:TXImageUploadServiceUguu].absoluteString
		isEqualToString:@"https://uguu.se/upload?output=text"], "uguu.se request URL");
	check([TXImageUploader requestURLForService:(TXImageUploadService)99] == nil, "unknown service -> nil request URL");
}

static void testMultipartBody(void) {
	NSString *s = bodyString(TXImageUploadServiceCatbox);

	check([s hasPrefix:@"--BOUND\r\n"], "body starts with boundary");
	check([s containsString:@"name=\"reqtype\"\r\n\r\nfileupload\r\n"], "catbox has reqtype field");
	check([s containsString:@"name=\"fileToUpload\"; filename=\"image.png\""], "catbox has file field with filename");
	check([s containsString:@"Content-Type: image/png\r\n\r\nPNGDATA\r\n"], "has content-type and payload");
	check([s hasSuffix:@"--BOUND--\r\n"], "body ends with closing boundary");

	s = bodyString(TXImageUploadServiceX0At);
	check([s containsString:@"name=\"file\"; filename=\"image.png\""], "x0.at uses file field");
	check([s containsString:@"reqtype"] == NO, "x0.at has no reqtype field");
	check([s hasPrefix:@"--BOUND\r\n"] && [s hasSuffix:@"--BOUND--\r\n"], "x0.at body is bounded");

	s = bodyString(TXImageUploadServiceKappaLol);
	check([s containsString:@"name=\"file\"; filename=\"image.png\""], "kappa.lol uses file field");

	s = bodyString(TXImageUploadServiceNuuls);
	check([s containsString:@"name=\"attachment\"; filename=\"image.png\""], "i.nuuls.com uses attachment field");

	s = bodyString(TXImageUploadServiceUguu);
	check([s containsString:@"name=\"files[]\"; filename=\"image.png\""], "uguu.se uses files[] field");
	check([s containsString:@"reqtype"] == NO, "uguu.se has no reqtype field");
}

static void testPlainTextResponseParsing(void) {
	NSError *err = nil;

	NSString *url = parse(@"https://files.catbox.moe/ab12cd.png\n", 200, TXImageUploadServiceCatbox, &err);
	check([url isEqualToString:@"https://files.catbox.moe/ab12cd.png"], "200 + url body -> trimmed url");
	check(err == nil, "success leaves error nil");

	err = nil;
	url = parse(@"Something went wrong.", 200, TXImageUploadServiceCatbox, &err);
	check(url == nil && err != nil, "200 + non-url body -> error");

	err = nil;
	url = parse(@"https://files.catbox.moe/ab12cd.png\n", 503, TXImageUploadServiceCatbox, &err);
	check(url == nil && err != nil, "non-200 status -> error");

	err = nil;
	url = [TXImageUploader urlFromResponseData:nil statusCode:200 service:TXImageUploadServiceCatbox error:&err];
	check(url == nil && err != nil, "nil body -> error");

	err = nil;
	url = parse(@"https://x0.at/mItS.png\n\n", 200, TXImageUploadServiceX0At, &err);
	check([url isEqualToString:@"https://x0.at/mItS.png"] && err == nil, "x0.at url with trailing blank line");

	err = nil;
	url = parse(@"https://i.nuuls.com/qsNJc.png", 200, TXImageUploadServiceNuuls, &err);
	check([url isEqualToString:@"https://i.nuuls.com/qsNJc.png"] && err == nil, "i.nuuls.com url");

	err = nil;
	url = parse(@"https://h.uguu.se/LbOEgxWy.png\n", 200, TXImageUploadServiceUguu, &err);
	check([url isEqualToString:@"https://h.uguu.se/LbOEgxWy.png"] && err == nil, "uguu.se url");

	err = nil;
	url = parse(@"https://x0.at/a.png\n<html>oops</html>", 200, TXImageUploadServiceX0At, &err);
	check(url == nil && err != nil, "url followed by other content -> error");
}

static void testKappaResponseParsing(void) {
	NSError *err = nil;

	NSString *url = parse(@"{\"id\":\"vcXQAk\",\"ext\":\".png\",\"type\":\"image/png\","
		"\"link\":\"https://kappa.lol/vcXQAk\",\"delete\":\"https://kappa.lol/delete?K\"}",
		200, TXImageUploadServiceKappaLol, &err);
	check([url isEqualToString:@"https://kappa.lol/vcXQAk.png"], "kappa.lol link gets its extension appended");
	check(err == nil, "kappa.lol success leaves error nil");

	err = nil;
	url = parse(@"{\"link\":\"https://kappa.lol/vcXQAk\"}", 200, TXImageUploadServiceKappaLol, &err);
	check([url isEqualToString:@"https://kappa.lol/vcXQAk"] && err == nil, "kappa.lol link without ext is used as is");

	err = nil;
	url = parse(@"{\"link\":\"https://kappa.lol/vcXQAk.png\",\"ext\":\".png\"}", 200, TXImageUploadServiceKappaLol, &err);
	check([url isEqualToString:@"https://kappa.lol/vcXQAk.png"] && err == nil, "kappa.lol ext is not appended twice");

	err = nil;
	url = parse(@"{\"error\":\"file too large\"}", 200, TXImageUploadServiceKappaLol, &err);
	check(url == nil && err != nil, "kappa.lol json without link -> error");

	err = nil;
	url = parse(@"{\"link\":\"javascript:alert(1)\",\"ext\":\".png\"}", 200, TXImageUploadServiceKappaLol, &err);
	check(url == nil && err != nil, "kappa.lol non-https link -> error");

	err = nil;
	url = parse(@"{\"link\":42}", 200, TXImageUploadServiceKappaLol, &err);
	check(url == nil && err != nil, "kappa.lol non-string link -> error");

	err = nil;
	url = parse(@"<html>Bad Gateway</html>", 200, TXImageUploadServiceKappaLol, &err);
	check(url == nil && err != nil, "kappa.lol non-json body -> error");

	err = nil;
	url = parse(@"{\"link\":\"https://kappa.lol/vcXQAk\"}", 500, TXImageUploadServiceKappaLol, &err);
	check(url == nil && err != nil, "kappa.lol non-200 status -> error");
}

int main(void) { @autoreleasepool {
	testRequestURLs();
	testMultipartBody();
	testPlainTextResponseParsing();
	testKappaResponseParsing();
	printf(gFailures ? "\n%d FAILURE(S)\n" : "\nALL PASSED\n", gFailures);
	return gFailures ? 1 : 0;
} }
