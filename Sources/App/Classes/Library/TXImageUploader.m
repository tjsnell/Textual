#import "TXImageUploader.h"

NS_ASSUME_NONNULL_BEGIN

@implementation TXImageUploader

+ (NSData *)multipartBodyForImageData:(NSData *)data
                             filename:(NSString *)filename
                             boundary:(NSString *)boundary
{
	NSMutableData *body = [NSMutableData data];

	void (^append)(NSString *) = ^(NSString *string) {
		[body appendData:[string dataUsingEncoding:NSUTF8StringEncoding]];
	};

	append([NSString stringWithFormat:@"--%@\r\n", boundary]);
	append(@"Content-Disposition: form-data; name=\"reqtype\"\r\n\r\n");
	append(@"fileupload\r\n");

	append([NSString stringWithFormat:@"--%@\r\n", boundary]);
	append([NSString stringWithFormat:
		@"Content-Disposition: form-data; name=\"fileToUpload\"; filename=\"%@\"\r\n", filename]);
	append(@"Content-Type: image/png\r\n\r\n");
	[body appendData:data];
	append(@"\r\n");

	append([NSString stringWithFormat:@"--%@--\r\n", boundary]);

	return body;
}

+ (nullable NSString *)urlFromResponseData:(nullable NSData *)data
                                statusCode:(NSInteger)statusCode
                                     error:(NSError * _Nullable * _Nullable)error
{
	NSString * (^makeError)(NSString *) = ^NSString * _Nullable (NSString *message) {
		if (error) {
			*error = [NSError errorWithDomain:@"TXImageUploaderErrorDomain"
			                             code:statusCode
			                         userInfo:@{NSLocalizedDescriptionKey: message}];
		}
		return nil;
	};

	if (statusCode != 200) {
		return makeError([NSString stringWithFormat:@"Server returned status %ld", (long)statusCode]);
	}

	if (data.length == 0) {
		return makeError(@"Empty response from server");
	}

	NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	NSString *trimmed = [body stringByTrimmingCharactersInSet:
		[NSCharacterSet whitespaceAndNewlineCharacterSet]];

	if ([trimmed hasPrefix:@"https://"] == NO) {
		return makeError(trimmed.length ? trimmed : @"Unexpected response from server");
	}

	return trimmed;
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
             completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion
{
	NSString *boundary = [NSString stringWithFormat:@"Boundary-%@", [[NSUUID UUID] UUIDString]];

	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:
		[NSURL URLWithString:@"https://catbox.moe/user/api.php"]];
	request.HTTPMethod = @"POST";
	[request setValue:[NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary]
	         forHTTPHeaderField:@"Content-Type"];
	request.HTTPBody = [[self class] multipartBodyForImageData:data filename:filename boundary:boundary];

	void (^finish)(NSString *, NSError *) = ^(NSString * _Nullable url, NSError * _Nullable error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(url, error);
		});
	};

	NSURLSessionDataTask *task =
		[self.session dataTaskWithRequest:request
		                completionHandler:^(NSData * _Nullable respData,
		                                    NSURLResponse * _Nullable response,
		                                    NSError * _Nullable transportError)
	{
		if (transportError != nil) {
			finish(nil, transportError);
			return;
		}

		NSInteger status = 0;
		if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
			status = ((NSHTTPURLResponse *)response).statusCode;
		}

		NSError *parseError = nil;
		NSString *url = [[self class] urlFromResponseData:respData statusCode:status error:&parseError];
		finish(url, url ? nil : parseError);
	}];

	[task resume];
}

@end

NS_ASSUME_NONNULL_END
