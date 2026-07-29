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
	return nil; // implemented in Task 2
}

- (void)uploadImageData:(NSData *)data
               filename:(NSString *)filename
             completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion
{
	// implemented in Task 3
}

@end

NS_ASSUME_NONNULL_END
