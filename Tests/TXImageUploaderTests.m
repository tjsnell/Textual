#import <Foundation/Foundation.h>
#import "../Sources/App/Classes/Headers/TXImageUploader.h"

static int gFailures = 0;
static void check(BOOL cond, const char *msg) {
	if (cond) { printf("PASS: %s\n", msg); }
	else { printf("FAIL: %s\n", msg); gFailures++; }
}

static NSString *bodyStringWithRetention(TXImageUploadService service, NSUInteger retentionHours) {
	NSData *image = [@"PNGDATA" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *body = [TXImageUploader multipartBodyForImageData:image
	                                                 filename:@"image.png"
	                                                 boundary:@"BOUND"
	                                                  service:service
	                                           retentionHours:retentionHours];
	return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
}

static NSString *bodyString(TXImageUploadService service) {
	return bodyStringWithRetention(service, 0);
}

static NSString *parse(NSString * _Nullable body, NSInteger status, TXImageUploadService service, NSError **err) {
	return [TXImageUploader urlFromResponseData:[body dataUsingEncoding:NSUTF8StringEncoding]
	                                 statusCode:status
	                                    service:service
	                                      error:err];
}

static void testRequestURLs(void) {
	check([[TXImageUploader requestURLForService:TXImageUploadServiceLitterbox].absoluteString
		isEqualToString:@"https://litterbox.catbox.moe/resources/internals/api.php"], "litterbox request URL");
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
	NSString *s = bodyString(TXImageUploadServiceLitterbox);

	check([s hasPrefix:@"--BOUND\r\n"], "body starts with boundary");
	check([s containsString:@"name=\"reqtype\"\r\n\r\nfileupload\r\n"], "litterbox has reqtype field");
	check([s containsString:@"name=\"fileToUpload\"; filename=\"image.png\""], "litterbox has file field with filename");
	check([s containsString:@"Content-Type: image/png\r\n\r\nPNGDATA\r\n"], "has content-type and payload");
	check([s hasSuffix:@"--BOUND--\r\n"], "body ends with closing boundary");

	check([s containsString:@"name=\"time\"\r\n\r\n72h\r\n"], "litterbox keeps for its 72h maximum when retention is forever");

	s = bodyStringWithRetention(TXImageUploadServiceLitterbox, 1);
	check([s containsString:@"name=\"time\"\r\n\r\n1h\r\n"], "litterbox 1 hour");
	s = bodyStringWithRetention(TXImageUploadServiceLitterbox, 12);
	check([s containsString:@"name=\"time\"\r\n\r\n12h\r\n"], "litterbox 12 hours");
	s = bodyStringWithRetention(TXImageUploadServiceLitterbox, 24);
	check([s containsString:@"name=\"time\"\r\n\r\n24h\r\n"], "litterbox 1 day");
	s = bodyStringWithRetention(TXImageUploadServiceLitterbox, 72);
	check([s containsString:@"name=\"time\"\r\n\r\n72h\r\n"], "litterbox 3 days");
	s = bodyStringWithRetention(TXImageUploadServiceLitterbox, 5);
	check([s containsString:@"name=\"time\"\r\n\r\n12h\r\n"], "litterbox rounds an odd retention up to the next step");
	s = bodyStringWithRetention(TXImageUploadServiceLitterbox, 500);
	check([s containsString:@"name=\"time\"\r\n\r\n72h\r\n"], "litterbox caps retention at 72h");

	s = bodyStringWithRetention(TXImageUploadServiceKappaLol, 12);
	check([s containsString:@"name=\"time\""] == NO, "retention adds no form field for other services");

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

	NSString *url = parse(@"https://litter.catbox.moe/ab12cd.png\n", 200, TXImageUploadServiceLitterbox, &err);
	check([url isEqualToString:@"https://litter.catbox.moe/ab12cd.png"], "200 + url body -> trimmed url");
	check(err == nil, "success leaves error nil");

	err = nil;
	url = parse(@"Something went wrong.", 200, TXImageUploadServiceLitterbox, &err);
	check(url == nil && err != nil, "200 + non-url body -> error");

	err = nil;
	url = parse(@"https://litter.catbox.moe/ab12cd.png\n", 503, TXImageUploadServiceLitterbox, &err);
	check(url == nil && err != nil, "non-200 status -> error");

	err = nil;
	url = [TXImageUploader urlFromResponseData:nil statusCode:200 service:TXImageUploadServiceLitterbox error:&err];
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

static void testRetentionSupport(void) {
	check([TXImageUploader serviceSupportsRetention:TXImageUploadServiceLitterbox], "litterbox supports retention");
	check([TXImageUploader serviceSupportsRetention:TXImageUploadServiceKappaLol], "kappa.lol supports retention");
	check([TXImageUploader serviceSupportsRetention:TXImageUploadServiceX0At] == NO, "x0.at does not support retention");
	check([TXImageUploader serviceSupportsRetention:TXImageUploadServiceNuuls] == NO, "i.nuuls.com does not support retention");
	check([TXImageUploader serviceSupportsRetention:TXImageUploadServiceUguu] == NO, "uguu.se does not support retention");
}

static NSString *deleteKey(NSString *body, TXImageUploadService service) {
	return [TXImageUploader deleteKeyFromResponseData:[body dataUsingEncoding:NSUTF8StringEncoding]
	                                          service:service];
}

static void testDeleteKeys(void) {
	NSString *kappa = @"{\"id\":\"vcXQAk\",\"ext\":\".png\",\"key\":\"K35Sr5GyPuyXBKzl\","
		"\"link\":\"https://kappa.lol/vcXQAk\",\"delete\":\"https://kappa.lol/delete?K35Sr5GyPuyXBKzl\"}";

	check([deleteKey(kappa, TXImageUploadServiceKappaLol) isEqualToString:@"K35Sr5GyPuyXBKzl"], "kappa.lol delete key is read from the response");
	check(deleteKey(@"{\"link\":\"https://kappa.lol/a\"}", TXImageUploadServiceKappaLol) == nil, "kappa.lol response without key -> nil");
	check(deleteKey(@"{\"key\":42}", TXImageUploadServiceKappaLol) == nil, "kappa.lol non-string key -> nil");
	check(deleteKey(@"{\"key\":\"\"}", TXImageUploadServiceKappaLol) == nil, "kappa.lol empty key -> nil");
	check(deleteKey(@"not json", TXImageUploadServiceKappaLol) == nil, "kappa.lol non-json -> nil");
	check(deleteKey(kappa, TXImageUploadServiceX0At) == nil, "other services never yield a delete key");
	check([TXImageUploader deleteKeyFromResponseData:nil service:TXImageUploadServiceKappaLol] == nil, "nil body -> nil key");

	check([[TXImageUploader deleteRequestURLForService:TXImageUploadServiceKappaLol deleteKey:@"K35Sr5GyPuyXBKzl"].absoluteString
		isEqualToString:@"https://kappa.lol/api/delete?key=K35Sr5GyPuyXBKzl"], "kappa.lol delete request URL");
	check([[TXImageUploader deleteRequestURLForService:TXImageUploadServiceKappaLol deleteKey:@"a b&c=d"].absoluteString
		isEqualToString:@"https://kappa.lol/api/delete?key=a%20b%26c%3Dd"], "delete key is percent-encoded");
	check([TXImageUploader deleteRequestURLForService:TXImageUploadServiceLitterbox deleteKey:@"K"] == nil, "litterbox has no delete request");
	check([TXImageUploader deleteRequestURLForService:TXImageUploadServiceX0At deleteKey:@"K"] == nil, "x0.at has no delete request");
}

int main(void) { @autoreleasepool {
	testRequestURLs();
	testMultipartBody();
	testPlainTextResponseParsing();
	testKappaResponseParsing();
	testRetentionSupport();
	testDeleteKeys();
	printf(gFailures ? "\n%d FAILURE(S)\n" : "\nALL PASSED\n", gFailures);
	return gFailures ? 1 : 0;
} }
