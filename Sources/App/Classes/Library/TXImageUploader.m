#import "TXImageUploader.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TXImageUploaderError) {
	TXImageUploaderErrorBadResponse = -1000,
	TXImageUploaderErrorUnknownService = -1001
};

static NSString * _Nullable TXImageUploaderSetError(NSError * _Nullable * _Nullable error,
                                                    NSInteger code,
                                                    NSString *message) {
	if (error) {
		*error = [NSError errorWithDomain:@"TXImageUploaderErrorDomain"
		                             code:code
		                         userInfo:@{NSLocalizedDescriptionKey: message}];
	}
	return nil;
}

@implementation TXImageUploader

+ (nullable NSURL *)requestURLForService:(TXImageUploadService)service
{
	switch (service) {
		case TXImageUploadServiceLitterbox:
			return [NSURL URLWithString:@"https://litterbox.catbox.moe/resources/internals/api.php"];
		case TXImageUploadServiceX0At:
			return [NSURL URLWithString:@"https://x0.at/"];
		case TXImageUploadServiceKappaLol:
			return [NSURL URLWithString:@"https://kappa.lol/api/upload"];
		case TXImageUploadServiceNuuls:
			return [NSURL URLWithString:@"https://i.nuuls.com/upload"];
		case TXImageUploadServiceUguu:
			return [NSURL URLWithString:@"https://uguu.se/upload?output=text"];
	}

	return nil;
}

/* Name of the multipart form field that carries the image for service. */
+ (NSString *)fileFieldNameForService:(TXImageUploadService)service
{
	switch (service) {
		case TXImageUploadServiceLitterbox:
			return @"fileToUpload";
		case TXImageUploadServiceNuuls:
			return @"attachment";
		case TXImageUploadServiceUguu:
			return @"files[]";
		case TXImageUploadServiceX0At:
		case TXImageUploadServiceKappaLol:
			break;
	}

	return @"file";
}

+ (BOOL)serviceSupportsRetention:(TXImageUploadService)service
{
	return (service == TXImageUploadServiceLitterbox ||
			service == TXImageUploadServiceKappaLol);
}

/* Litterbox only accepts 1h, 12h, 24h and 72h. Other values round up to the
 next step; 0 (forever) and anything longer get the 72h maximum. */
+ (NSString *)litterboxTimeForRetentionHours:(NSUInteger)retentionHours
{
	if (retentionHours == 0 || retentionHours > 24) {
		return @"72h";
	} else if (retentionHours > 12) {
		return @"24h";
	} else if (retentionHours > 1) {
		return @"12h";
	}

	return @"1h";
}

/* Caller must pass a header-safe filename (no quotes or CRLF). */
+ (NSData *)multipartBodyForImageData:(NSData *)data
                             filename:(NSString *)filename
                             boundary:(NSString *)boundary
                              service:(TXImageUploadService)service
                       retentionHours:(NSUInteger)retentionHours
{
	NSMutableData *body = [NSMutableData data];

	void (^append)(NSString *) = ^(NSString *string) {
		[body appendData:[string dataUsingEncoding:NSUTF8StringEncoding]];
	};

	if (service == TXImageUploadServiceLitterbox) {
		append([NSString stringWithFormat:@"--%@\r\n", boundary]);
		append(@"Content-Disposition: form-data; name=\"reqtype\"\r\n\r\n");
		append(@"fileupload\r\n");

		append([NSString stringWithFormat:@"--%@\r\n", boundary]);
		append(@"Content-Disposition: form-data; name=\"time\"\r\n\r\n");
		append([NSString stringWithFormat:@"%@\r\n",
			[self litterboxTimeForRetentionHours:retentionHours]]);
	}

	append([NSString stringWithFormat:@"--%@\r\n", boundary]);
	append([NSString stringWithFormat:
		@"Content-Disposition: form-data; name=\"%@\"; filename=\"%@\"\r\n",
		[self fileFieldNameForService:service], filename]);
	append(@"Content-Type: image/png\r\n\r\n");
	[body appendData:data];
	append(@"\r\n");

	append([NSString stringWithFormat:@"--%@--\r\n", boundary]);

	return body;
}

/* kappa.lol answers with JSON: "link" has no file extension and "ext" carries
 it separately. The extension is appended so the URL reads as an image. */
+ (nullable NSString *)kappaURLFromResponseData:(NSData *)data
{
	id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];

	if ([json isKindOfClass:[NSDictionary class]] == NO) {
		return nil;
	}

	id link = ((NSDictionary *)json)[@"link"];
	id ext = ((NSDictionary *)json)[@"ext"];

	if ([link isKindOfClass:[NSString class]] == NO) {
		return nil;
	}

	if ([ext isKindOfClass:[NSString class]] &&
		[ext hasPrefix:@"."] &&
		[link hasSuffix:ext] == NO)
	{
		return [link stringByAppendingString:ext];
	}

	return link;
}

+ (nullable NSString *)urlFromResponseData:(nullable NSData *)data
                                statusCode:(NSInteger)statusCode
                                   service:(TXImageUploadService)service
                                     error:(NSError * _Nullable * _Nullable)error
{
	if (statusCode != 200) {
		return TXImageUploaderSetError(error, statusCode,
			[NSString stringWithFormat:@"Server returned status %ld", (long)statusCode]);
	}

	if (data.length == 0) {
		return TXImageUploaderSetError(error, TXImageUploaderErrorBadResponse,
			@"Empty response from server");
	}

	NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	NSString *trimmed = [body stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	NSString *url = trimmed;

	if (service == TXImageUploadServiceKappaLol) {
		url = [self kappaURLFromResponseData:data];
	}

	if ([url hasPrefix:@"https://"] == NO ||
		[url rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound)
	{
		return TXImageUploaderSetError(error, TXImageUploaderErrorBadResponse,
			trimmed.length ? trimmed : @"Unexpected response from server");
	}

	return url;
}

+ (nullable NSString *)deleteKeyFromResponseData:(nullable NSData *)data
                                         service:(TXImageUploadService)service
{
	if (service != TXImageUploadServiceKappaLol || data.length == 0) {
		return nil;
	}

	id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];

	if ([json isKindOfClass:[NSDictionary class]] == NO) {
		return nil;
	}

	id key = ((NSDictionary *)json)[@"key"];

	if ([key isKindOfClass:[NSString class]] == NO || [key length] == 0) {
		return nil;
	}

	return key;
}

+ (nullable NSURL *)deleteRequestURLForService:(TXImageUploadService)service
                                     deleteKey:(NSString *)deleteKey
{
	if (service != TXImageUploadServiceKappaLol) {
		return nil;
	}

	NSURLComponents *components =
		[NSURLComponents componentsWithString:@"https://kappa.lol/api/delete"];

	NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
	[allowed removeCharactersInString:@"&=+?#"];

	components.percentEncodedQuery = [NSString stringWithFormat:@"key=%@",
		[deleteKey stringByAddingPercentEncodingWithAllowedCharacters:allowed]];

	return components.URL;
}

- (NSURLSession *)session
{
	if (self->_session == nil) {
		self->_session = [NSURLSession sharedSession];
	}
	return self->_session;
}

- (void)uploadImageData:(NSData *)data
               filename:(NSString *)filename
                service:(TXImageUploadService)service
         retentionHours:(NSUInteger)retentionHours
             completion:(void (^)(NSString * _Nullable, NSString * _Nullable, NSError * _Nullable))completion
{
	void (^finish)(NSString *, NSString *, NSError *) =
		^(NSString * _Nullable url, NSString * _Nullable deleteKey, NSError * _Nullable error)
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(url, deleteKey, error);
		});
	};

	NSURL *requestURL = [[self class] requestURLForService:service];

	if (requestURL == nil) {
		NSError *serviceError = nil;
		TXImageUploaderSetError(&serviceError, TXImageUploaderErrorUnknownService,
			@"Unknown image upload service");
		finish(nil, nil, serviceError);
		return;
	}

	NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];
	request.HTTPMethod = @"POST";
	[request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
	         forHTTPHeaderField:@"Content-Type"];
	request.HTTPBody = [[self class] multipartBodyForImageData:data
	                                                  filename:filename
	                                                  boundary:boundary
	                                                   service:service
	                                            retentionHours:retentionHours];

	NSURLSessionDataTask *task =
		[self.session dataTaskWithRequest:request
		                completionHandler:^(NSData * _Nullable respData,
		                                    NSURLResponse * _Nullable response,
		                                    NSError * _Nullable transportError)
	{
		if (transportError != nil) {
			finish(nil, nil, transportError);
			return;
		}

		NSInteger status = 0;
		if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
			status = ((NSHTTPURLResponse *)response).statusCode;
		}

		NSError *parseError = nil;
		NSString *url = [[self class] urlFromResponseData:respData
		                                       statusCode:status
		                                          service:service
		                                            error:&parseError];

		if (url == nil) {
			finish(nil, nil, parseError);
			return;
		}

		finish(url, [[self class] deleteKeyFromResponseData:respData service:service], nil);
	}];

	[task resume];
}

@end

NS_ASSUME_NONNULL_END
