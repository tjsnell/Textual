# Automated URL Shortener Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-shorten long URLs in outgoing messages via a preference, with a choice of TinyURL / is.gd / v.gd and a configurable minimum length (default 40).

**Architecture:** A new `TXURLShortener` class (modeled on `TXImageUploader`) does detection, request building, response validation, and async batch shortening. `TVCMainWindow -inputText:asCommand:` intercepts qualifying messages after plugin dispatch, shortens asynchronously, then continues the send via `IRCClient -inputText:asCommand:destination:`. Three new `TPCPreferences` keys back a checkbox + popup + number field in the Behavior preferences pane.

**Tech Stack:** Objective-C (ARC), Foundation `NSURLSession`/`NSDataDetector`, Cocoa bindings in `TDCPreferences.xib`, standalone clang-compiled tests (existing pattern in `Tests/`), ruby `xcodeproj` gem for project registration.

**Spec:** `docs/superpowers/specs/2026-08-10-url-shortener-design.md`

**Branch:** `feature/url-shortener` (already created; work here, commit after every task).

## Context for a fresh engineer

- Textual is a macOS IRC client. The app is normally built in Xcode. New `.m` files must be registered in `Sources/App/Textual App.xcodeproj/project.pbxproj` (Task 8) before the app target compiles them.
- Tests are NOT XCTest. They are standalone `main()` programs in `Tests/` compiled directly with clang and run from the shell (see `Tests/TXImageUploaderTests.m` for the pattern). Run them from the repo root `/Users/tjs/code/textual`.
- `RZUserDefaults()` is Textual's shared `NSUserDefaults` accessor (group container). Preference defaults are registered in `Sources/App/Resources/Property Lists/Preferences/RegisteredUserDefaultsInContainer.plist`.
- Preference UI controls bind to an `NSUserDefaultsController` inside `TDCPreferences.xib` whose object id is `G2Q-fc-ddg`, using key paths like `values.SomeKey`.
- Input flow: `TVCMainWindow -textEntered` → `-inputTextAsCommand:` (grabs `NSAttributedString` from the input field) → `-inputText:asCommand:` (runs `THOPluginDispatcher +interceptUserInput:command:`, which returns `nullable id` — **either `NSString` or `NSAttributedString`**) → `IRCClient -inputText:asCommand:`. Slash-command parsing happens later, inside `IRCClient`, so at our interception point the string still starts with `/` for commands.
- `IRCClientPrivate.h` declares `- (void)inputText:(id)string asCommand:(IRCRemoteCommand)command destination:(IRCTreeItem *)destination;` — use this after async work so the message goes to the channel that was selected when the user hit enter, even if selection changed while requests were in flight.

---

### Task 1: TXURLShortener skeleton + request URL builder

**Files:**
- Create: `Tests/TXURLShortenerTests.m`
- Create: `Sources/App/Classes/Headers/TXURLShortener.h`
- Create: `Sources/App/Classes/Library/TXURLShortener.m`

- [ ] **Step 1: Write the failing test**

Create `Tests/TXURLShortenerTests.m`:

```objc
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m -o /tmp/shorttest 2>&1 | head`
Expected: FAILS to compile — `TXURLShortener.h` not found.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/App/Classes/Headers/TXURLShortener.h`:

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, TXURLShortenerService) {
	TXURLShortenerServiceTinyURL = 0,
	TXURLShortenerServiceIsGd = 1,
	TXURLShortenerServiceVGd = 2
};

@interface TXURLShortener : NSObject

#pragma mark - Pure helpers (exposed for testing)

/* Returns the GET request URL for shortening originalURL with service,
 or nil for an unknown service. originalURL is fully percent-encoded. */
+ (nullable NSURL *)requestURLForService:(TXURLShortenerService)service
                             originalURL:(NSString *)originalURL;

@end

NS_ASSUME_NONNULL_END
```

Create `Sources/App/Classes/Library/TXURLShortener.m`:

```objc
#import "TXURLShortener.h"

NS_ASSUME_NONNULL_BEGIN

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

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 4: Run test to verify it passes**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest && /tmp/shorttest`
Expected: `ALL PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Tests/TXURLShortenerTests.m Sources/App/Classes/Headers/TXURLShortener.h Sources/App/Classes/Library/TXURLShortener.m
git commit -m "feat: TXURLShortener request URL builder for TinyURL/is.gd/v.gd"
```

---

### Task 2: Response validation

**Files:**
- Modify: `Tests/TXURLShortenerTests.m`
- Modify: `Sources/App/Classes/Headers/TXURLShortener.h`
- Modify: `Sources/App/Classes/Library/TXURLShortener.m`

- [ ] **Step 1: Write the failing test**

In `Tests/TXURLShortenerTests.m`, add above `main()`:

```objc
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
```

And call it in `main()` after `testRequestURLBuilding();`:

```objc
	testResponseValidation();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest 2>&1 | head`
Expected: FAILS to compile — no known class method `shortURLFromResponseData:statusCode:error:`.

- [ ] **Step 3: Write minimal implementation**

In `TXURLShortener.h`, add below the `requestURLForService:` declaration:

```objc
/* Validates a shortener response. Returns the short URL, or nil with error
 set, when the status is non-2xx or the body is not a single http(s) URL
 (is.gd/v.gd report failures as an "Error: ..." text body). */
+ (nullable NSString *)shortURLFromResponseData:(nullable NSData *)data
                                     statusCode:(NSInteger)statusCode
                                          error:(NSError * _Nullable * _Nullable)error;
```

In `TXURLShortener.m`, add above `@implementation` (mirrors `TXImageUploader.m`):

```objc
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
```

And inside `@implementation`:

```objc
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest && /tmp/shorttest`
Expected: `ALL PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Tests/TXURLShortenerTests.m Sources/App/Classes/Headers/TXURLShortener.h Sources/App/Classes/Library/TXURLShortener.m
git commit -m "feat: TXURLShortener response validation"
```

---

### Task 3: URL detection in outgoing text

**Files:**
- Modify: `Tests/TXURLShortenerTests.m`
- Modify: `Sources/App/Classes/Headers/TXURLShortener.h`
- Modify: `Sources/App/Classes/Library/TXURLShortener.m`

- [ ] **Step 1: Write the failing test**

Add above `main()`:

```objc
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
```

And call it in `main()`:

```objc
	testURLDetection();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest 2>&1 | head`
Expected: FAILS to compile — no known class method `shortenableURLsInString:minimumLength:`.

- [ ] **Step 3: Write minimal implementation**

In `TXURLShortener.h`:

```objc
/* Returns the unique http(s) URLs in string, as they literally appear, whose
 length is >= minimumLength. Returns an empty array for slash commands other
 than "/me ". */
+ (NSArray<NSString *> *)shortenableURLsInString:(NSString *)string
                                   minimumLength:(NSUInteger)minimumLength;
```

In `TXURLShortener.m`:

```objc
+ (NSArray<NSString *> *)shortenableURLsInString:(NSString *)string
                                   minimumLength:(NSUInteger)minimumLength
{
	/* Slash-command parsing happens downstream in IRCClient; only plain
	 messages and "/me" actions are eligible for shortening. */
	if ([string hasPrefix:@"/"] &&
		[string.lowercaseString hasPrefix:@"/me "] == NO)
	{
		return @[];
	}

	NSDataDetector *detector =
	[NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];

	if (detector == nil) {
		return @[];
	}

	NSMutableArray<NSString *> *urls = [NSMutableArray array];

	[detector enumerateMatchesInString:string
	                           options:0
	                             range:NSMakeRange(0, string.length)
	                        usingBlock:^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop)
	{
		NSString *matched = [string substringWithRange:result.range];

		/* Require an explicit scheme so the literal substring is a complete
		 URL the shortener API will accept. */
		NSString *lowercased = matched.lowercaseString;

		if ([lowercased hasPrefix:@"http://"] == NO &&
			[lowercased hasPrefix:@"https://"] == NO)
		{
			return;
		}

		if (matched.length < minimumLength) {
			return;
		}

		if ([urls containsObject:matched] == NO) {
			[urls addObject:matched];
		}
	}];

	return [urls copy];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest && /tmp/shorttest`
Expected: `ALL PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Tests/TXURLShortenerTests.m Sources/App/Classes/Headers/TXURLShortener.h Sources/App/Classes/Library/TXURLShortener.m
git commit -m "feat: TXURLShortener detection of shortenable URLs in outgoing text"
```

---

### Task 4: Substitution helpers (plain + attributed)

The input pipeline delivers either `NSString` or `NSAttributedString` (formatted text). Attributed replacement uses `NSMutableAttributedString` so IRC formatting survives.

**Files:**
- Modify: `Tests/TXURLShortenerTests.m`
- Modify: `Sources/App/Classes/Headers/TXURLShortener.h`
- Modify: `Sources/App/Classes/Library/TXURLShortener.m`

- [ ] **Step 1: Write the failing test**

Add above `main()`:

```objc
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
}
```

And call it in `main()`:

```objc
	testSubstitution();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest 2>&1 | head`
Expected: FAILS to compile — unknown substitution methods.

- [ ] **Step 3: Write minimal implementation**

In `TXURLShortener.h`:

```objc
/* Replace each key of shortURLs with its value. Mappings whose replacement
 is not strictly shorter than the original are skipped. */
+ (NSString *)string:(NSString *)string
 byApplyingShortURLs:(NSDictionary<NSString *, NSString *> *)shortURLs;

+ (NSAttributedString *)attributedString:(NSAttributedString *)string
                     byApplyingShortURLs:(NSDictionary<NSString *, NSString *> *)shortURLs;
```

In `TXURLShortener.m`:

```objc
+ (NSString *)string:(NSString *)string
 byApplyingShortURLs:(NSDictionary<NSString *, NSString *> *)shortURLs
{
	NSAttributedString *wrapped = [[NSAttributedString alloc] initWithString:string];

	return [self attributedString:wrapped byApplyingShortURLs:shortURLs].string;
}

+ (NSAttributedString *)attributedString:(NSAttributedString *)string
                     byApplyingShortURLs:(NSDictionary<NSString *, NSString *> *)shortURLs
{
	NSMutableAttributedString *result = [string mutableCopy];

	for (NSString *original in shortURLs) {
		NSString *shortened = shortURLs[original];

		if (shortened.length >= original.length) {
			continue;
		}

		NSRange searchRange = NSMakeRange(0, result.length);
		NSRange found;

		while ((found = [result.string rangeOfString:original
		                                     options:0
		                                       range:searchRange]).location != NSNotFound)
		{
			[result replaceCharactersInRange:found withString:shortened];

			NSUInteger resumeAt = (found.location + shortened.length);

			searchRange = NSMakeRange(resumeAt, (result.length - resumeAt));
		}
	}

	return [result copy];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest && /tmp/shorttest`
Expected: `ALL PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Tests/TXURLShortenerTests.m Sources/App/Classes/Headers/TXURLShortener.h Sources/App/Classes/Library/TXURLShortener.m
git commit -m "feat: TXURLShortener substitution helpers for plain and attributed text"
```

---

### Task 5: Async batch shortening

Network method — no unit test (matches `TXImageUploader` precedent: only pure helpers are unit-tested). Verified by compilation here and by hand at the end.

**Files:**
- Modify: `Sources/App/Classes/Headers/TXURLShortener.h`
- Modify: `Sources/App/Classes/Library/TXURLShortener.m`

- [ ] **Step 1: Add the API**

In `TXURLShortener.h`, inside the interface but ABOVE the `#pragma mark - Pure helpers` line, add:

```objc
/* Injectable for testing; defaults to +[NSURLSession sharedSession]. */
@property (nonatomic, strong) NSURLSession *session;

/* Shortens every URL in urls concurrently using service. completion is
 always called on the main queue with a mapping of original URL ->
 shortened URL. URLs whose request failed, returned an invalid body, or
 timed out (10s) are simply absent from the mapping. */
- (void)shortenURLs:(NSArray<NSString *> *)urls
            service:(TXURLShortenerService)service
         completion:(void (^)(NSDictionary<NSString *, NSString *> *shortURLs))completion;
```

- [ ] **Step 2: Implement**

In `TXURLShortener.m`, inside `@implementation`:

```objc
- (NSURLSession *)session
{
	if (self->_session == nil) {
		self->_session = [NSURLSession sharedSession];
	}
	return self->_session;
}

- (void)shortenURLs:(NSArray<NSString *> *)urls
            service:(TXURLShortenerService)service
         completion:(void (^)(NSDictionary<NSString *, NSString *> *))completion
{
	NSMutableDictionary<NSString *, NSString *> *results = [NSMutableDictionary dictionary];

	dispatch_group_t group = dispatch_group_create();

	dispatch_queue_t resultsQueue =
	dispatch_queue_create("Textual.TXURLShortener.results", DISPATCH_QUEUE_SERIAL);

	for (NSString *url in urls) {
		NSURL *requestURL = [[self class] requestURLForService:service originalURL:url];

		if (requestURL == nil) {
			continue;
		}

		NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:requestURL];

		request.timeoutInterval = 10.0;

		dispatch_group_enter(group);

		NSURLSessionDataTask *task =
		[self.session dataTaskWithRequest:request
		                completionHandler:^(NSData * _Nullable data,
		                                    NSURLResponse * _Nullable response,
		                                    NSError * _Nullable transportError)
		{
			NSString *shortURL = nil;

			if (transportError == nil) {
				NSInteger status = 0;

				if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
					status = ((NSHTTPURLResponse *)response).statusCode;
				}

				shortURL = [[self class] shortURLFromResponseData:data statusCode:status error:NULL];
			}

			dispatch_async(resultsQueue, ^{
				if (shortURL != nil) {
					results[url] = shortURL;
				}

				dispatch_group_leave(group);
			});
		}];

		[task resume];
	}

	dispatch_group_notify(group, dispatch_get_main_queue(), ^{
		completion([results copy]);
	});
}
```

- [ ] **Step 3: Verify everything still compiles and tests pass**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest && /tmp/shorttest`
Expected: `ALL PASSED`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/Classes/Headers/TXURLShortener.h Sources/App/Classes/Library/TXURLShortener.m
git commit -m "feat: TXURLShortener async batch shortening with 10s timeout"
```

---

### Task 6: Preference accessors + registered defaults

**Files:**
- Modify: `Sources/App/Classes/Headers/TPCPreferencesLocal.h` (near line 316, after `+ (CGFloat)swipeMinimumLength;`)
- Modify: `Sources/App/Classes/Preferences/TPCPreferencesLocal.m` (near line 443, after the `swipeMinimumLength` implementation)
- Modify: `Sources/App/Resources/Property Lists/Preferences/RegisteredUserDefaultsInContainer.plist`

- [ ] **Step 1: Declare accessors**

In `TPCPreferencesLocal.h`, directly after `+ (CGFloat)swipeMinimumLength;`:

```objc
+ (BOOL)shortenOutgoingURLs;
+ (NSUInteger)urlShortenerService; /* cast to TXURLShortenerService */
+ (NSUInteger)urlShortenerMinimumLength;
```

- [ ] **Step 2: Implement accessors**

In `TPCPreferencesLocal.m`, directly after the closing brace of `+ (CGFloat)swipeMinimumLength`:

```objc
+ (BOOL)shortenOutgoingURLs
{
	return [RZUserDefaults() boolForKey:@"AutomaticallyShortenOutgoingLinks"];
}

+ (NSUInteger)urlShortenerService
{
	return [RZUserDefaults() unsignedIntegerForKey:@"URLShortenerService"];
}

+ (NSUInteger)urlShortenerMinimumLength
{
	return [RZUserDefaults() unsignedIntegerForKey:@"URLShortenerMinimumLength"];
}
```

- [ ] **Step 3: Register defaults**

In `RegisteredUserDefaultsInContainer.plist` (keys are roughly alphabetical):

Directly after the `<key>AutojoinChannelOnInvite</key>` / `<false/>` pair, insert:

```xml
	<key>AutomaticallyShortenOutgoingLinks</key>
	<false/>
```

Directly after the `<key>SwipeMinimumLength</key>` / `<integer>30</integer>` pair, insert:

```xml
	<key>URLShortenerMinimumLength</key>
	<integer>40</integer>
	<key>URLShortenerService</key>
	<integer>0</integer>
```

- [ ] **Step 4: Verify plist is still valid**

Run: `plutil -lint "Sources/App/Resources/Property Lists/Preferences/RegisteredUserDefaultsInContainer.plist"`
Expected: `... OK`

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Classes/Headers/TPCPreferencesLocal.h Sources/App/Classes/Preferences/TPCPreferencesLocal.m "Sources/App/Resources/Property Lists/Preferences/RegisteredUserDefaultsInContainer.plist"
git commit -m "feat: URL shortener preference keys with registered defaults"
```

---

### Task 7: Wire shortening into the send path

**Files:**
- Modify: `Sources/App/Classes/Views/Main Window/TVCMainWindow.m`

- [ ] **Step 1: Add import and property**

Near the other `#import` lines at the top of `TVCMainWindow.m` (e.g. after `#import "TVCServerListPrivate.h"`), add:

```objc
#import "TXURLShortener.h"
```

In the `@interface TVCMainWindow ()` class extension (around line 93), after the `@property (nonatomic, strong) TLOInputHistory *inputHistoryManager;` line, add:

```objc
@property (nonatomic, strong, nullable) TXURLShortener *urlShortener;
```

- [ ] **Step 2: Replace `-inputText:asCommand:`**

Replace the existing method (around line 1265):

```objc
- (void)inputText:(id)string asCommand:(IRCRemoteCommand)command
{
	NSParameterAssert(string != nil);

	if (self.selectedItem == nil) {
		return;
	}

	NSString *stringValue = [THOPluginDispatcher interceptUserInput:string command:command];
	
	if (stringValue == nil) {
		return;
	}

	[self.selectedClient inputText:stringValue asCommand:command];
}
```

with:

```objc
- (void)inputText:(id)string asCommand:(IRCRemoteCommand)command
{
	NSParameterAssert(string != nil);

	if (self.selectedItem == nil) {
		return;
	}

	/* Plugins may return either NSString or NSAttributedString here. */
	id stringValue = [THOPluginDispatcher interceptUserInput:string command:command];

	if (stringValue == nil) {
		return;
	}

	if (command == IRCRemoteCommandPrivmsg && [TPCPreferences shortenOutgoingURLs]) {
		NSString *plainText = nil;

		if ([stringValue isKindOfClass:[NSAttributedString class]]) {
			plainText = ((NSAttributedString *)stringValue).string;
		} else if ([stringValue isKindOfClass:[NSString class]]) {
			plainText = stringValue;
		}

		NSArray<NSString *> *urls = @[];

		if (plainText != nil) {
			urls = [TXURLShortener shortenableURLsInString:plainText
			                                 minimumLength:[TPCPreferences urlShortenerMinimumLength]];
		}

		if (urls.count > 0) {
			[self sendInputText:stringValue asCommand:command shorteningURLs:urls];

			return;
		}
	}

	[self.selectedClient inputText:stringValue asCommand:command];
}

- (void)sendInputText:(id)stringValue asCommand:(IRCRemoteCommand)command shorteningURLs:(NSArray<NSString *> *)urls
{
	if (self.urlShortener == nil) {
		self.urlShortener = [TXURLShortener new];
	}

	/* Capture the destination now so the message reaches the view that was
	 selected when the user hit enter, even if selection changes while the
	 shortener requests are in flight. */
	IRCClient *client = self.selectedClient;
	IRCTreeItem *destination = self.selectedItem;

	TXURLShortenerService service =
	(TXURLShortenerService)[TPCPreferences urlShortenerService];

	[self.urlShortener shortenURLs:urls
	                       service:service
	                    completion:^(NSDictionary<NSString *, NSString *> *shortURLs)
	{
		id result = stringValue;

		/* Failed URLs are absent from the mapping and remain unmodified —
		 the message always sends. */
		if (shortURLs.count > 0) {
			if ([stringValue isKindOfClass:[NSAttributedString class]]) {
				result = [TXURLShortener attributedString:stringValue byApplyingShortURLs:shortURLs];
			} else {
				result = [TXURLShortener string:stringValue byApplyingShortURLs:shortURLs];
			}
		}

		[client inputText:result asCommand:command destination:destination];
	}];
}
```

Notes for the engineer:
- `TPCPreferences` and `THOPluginDispatcher` are already imported/used by this file.
- `IRCClient -inputText:asCommand:destination:` is declared in `IRCClientPrivate.h`, which `TVCMainWindow.m` already imports.
- `IRCTreeItem` is already a known type in this file.

- [ ] **Step 3: Syntax-check the edit**

A full build needs the whole workspace (done in Task 10). For a quick sanity pass, verify the method bodies balance and names match:

Run: `grep -n "sendInputText:asCommand:shorteningURLs\|urlShortener" "Sources/App/Classes/Views/Main Window/TVCMainWindow.m" | head`
Expected: the property declaration, both call sites, and the method definition appear.

- [ ] **Step 4: Commit**

```bash
git add "Sources/App/Classes/Views/Main Window/TVCMainWindow.m"
git commit -m "feat: auto-shorten long URLs in outgoing messages when enabled"
```

---

### Task 8: Register new files in the Xcode project

**Files:**
- Modify: `Sources/App/Textual App.xcodeproj/project.pbxproj` (via ruby `xcodeproj` gem — do not hand-edit)

Lesson from the image-uploader feature: create references with group-relative basenames inside the same parent groups as `TXImageUploader.h`/`.m` — group-prefixed paths produce doubled paths that break the build.

- [ ] **Step 1: Write the registration script**

Create `/private/tmp/claude-501/-Users-tjs-code-textual/6edc0465-ce26-4dac-9594-9fdc43bea0f1/scratchpad/register_shortener.rb`:

```ruby
require 'xcodeproj'

project = Xcodeproj::Project.open('Sources/App/Textual App.xcodeproj')

existing_m = project.files.find { |f| f.path.to_s.end_with?('TXImageUploader.m') }
existing_h = project.files.find { |f| f.path.to_s.end_with?('TXImageUploader.h') }
abort 'TXImageUploader.m reference not found' if existing_m.nil?

new_m = existing_m.parent.new_reference('TXURLShortener.m')

unless existing_h.nil?
  existing_h.parent.new_reference('TXURLShortener.h')
end

project.targets.each do |target|
  next unless target.respond_to?(:source_build_phase)
  next unless target.source_build_phase.files_references.include?(existing_m)
  target.source_build_phase.add_file_reference(new_m)
  puts "Added TXURLShortener.m to target: #{target.name}"
end

project.save
puts 'Saved.'
```

- [ ] **Step 2: Run it from the repo root**

Run: `cd /Users/tjs/code/textual && ruby /private/tmp/claude-501/-Users-tjs-code-textual/6edc0465-ce26-4dac-9594-9fdc43bea0f1/scratchpad/register_shortener.rb`
Expected output includes: `Added TXURLShortener.m to target: Textual (Debug)` and `Added TXURLShortener.m to target: Textual (Standard Release)`, then `Saved.`
(If the `xcodeproj` gem is missing: `gem install --user-install xcodeproj` first.)

- [ ] **Step 3: Verify registration**

Run: `grep -c "TXURLShortener.m" "Sources/App/Textual App.xcodeproj/project.pbxproj"`
Expected: a count of at least 4 (file reference + build file entries for two targets).

- [ ] **Step 4: Commit**

```bash
git add "Sources/App/Textual App.xcodeproj/project.pbxproj"
git commit -m "build: register TXURLShortener in app targets"
```

---

### Task 9: Preferences UI in the Behavior pane

**Files:**
- Modify: `Sources/App/Resources/User Interface/en.lproj/TDCPreferences.xib`

The Behavior pane is the `<customView ... id="Yrc-pc-3Zr" userLabel="Behavior">` element (line ~864). Its last control is checkbox `2fI-fE-Q2a`, and constraint `5OK-SG-6Vw` pins the pane bottom to that checkbox. We append: separator → checkbox → row (label, popup, label, number field), and re-anchor the bottom. Bindings target the defaults controller `G2Q-fc-ddg`. Frame `rect` values are advisory (autolayout governs); approximate values are fine.

- [ ] **Step 1: Add the new subviews**

Inside the Behavior pane's `<subviews>`, directly after the closing `</button>` of `2fI-fE-Q2a` (line ~932), insert:

```xml
                <box verticalHuggingPriority="750" boxType="separator" translatesAutoresizingMaskIntoConstraints="NO" id="uS1-eP-arA">
                    <rect key="frame" x="40" y="-1" width="590" height="5"/>
                </box>
                <button verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="uS2-cB-oxA">
                    <rect key="frame" x="40" y="-34" width="330" height="18"/>
                    <buttonCell key="cell" type="check" title="Automatically shorten links in sent messages" bezelStyle="regularSquare" imagePosition="left" inset="2" id="uS2-cE-llA">
                        <behavior key="behavior" changeContents="YES" doesNotDimImage="YES" lightByContents="YES"/>
                        <font key="font" metaFont="system"/>
                    </buttonCell>
                    <connections>
                        <binding destination="G2Q-fc-ddg" name="value" keyPath="values.AutomaticallyShortenOutgoingLinks" id="uS2-bD-001"/>
                    </connections>
                </button>
                <stackView distribution="fill" orientation="horizontal" alignment="centerY" spacing="8" horizontalStackHuggingPriority="250" verticalStackHuggingPriority="250" detachesHiddenViews="YES" translatesAutoresizingMaskIntoConstraints="NO" id="uS6-sV-rwA">
                    <rect key="frame" x="62" y="-73" width="440" height="25"/>
                    <subviews>
                        <textField horizontalHuggingPriority="251" verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="uS4-lB-el1">
                            <rect key="frame" x="0.0" y="4" width="52" height="16"/>
                            <textFieldCell key="cell" lineBreakMode="clipping" title="Service:" id="uS4-cE-ll1">
                                <font key="font" metaFont="system"/>
                                <color key="textColor" name="labelColor" catalog="System" colorSpace="catalog"/>
                                <color key="backgroundColor" name="controlColor" catalog="System" colorSpace="catalog"/>
                            </textFieldCell>
                        </textField>
                        <popUpButton verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="uS3-pU-pbA">
                            <rect key="frame" x="57" y="0.0" width="110" height="25"/>
                            <popUpButtonCell key="cell" type="push" title="TinyURL" bezelStyle="rounded" alignment="left" lineBreakMode="truncatingTail" state="on" borderStyle="borderAndBezel" inset="2" selectedItem="uS3-mI-001" id="uS3-cE-llA">
                                <behavior key="behavior" lightByBackground="YES" lightByGray="YES"/>
                                <font key="font" usesAppearanceFont="YES"/>
                                <menu key="menu" title="OtherViews" id="uS3-mE-nuA">
                                    <items>
                                        <menuItem title="TinyURL" state="on" id="uS3-mI-001"/>
                                        <menuItem title="is.gd" tag="1" id="uS3-mI-002"/>
                                        <menuItem title="v.gd" tag="2" id="uS3-mI-003"/>
                                    </items>
                                </menu>
                            </popUpButtonCell>
                            <accessibility description="URL Shortener Service"/>
                            <connections>
                                <binding destination="G2Q-fc-ddg" name="selectedTag" keyPath="values.URLShortenerService" id="uS3-bD-001"/>
                                <binding destination="G2Q-fc-ddg" name="enabled" keyPath="values.AutomaticallyShortenOutgoingLinks" id="uS3-bD-002"/>
                            </connections>
                        </popUpButton>
                        <textField horizontalHuggingPriority="251" verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="uS4-lB-el2">
                            <rect key="frame" x="175" y="4" width="130" height="16"/>
                            <textFieldCell key="cell" lineBreakMode="clipping" title="Minimum link length:" id="uS4-cE-ll2">
                                <font key="font" metaFont="system"/>
                                <color key="textColor" name="labelColor" catalog="System" colorSpace="catalog"/>
                                <color key="backgroundColor" name="controlColor" catalog="System" colorSpace="catalog"/>
                            </textFieldCell>
                        </textField>
                        <textField verticalHuggingPriority="750" translatesAutoresizingMaskIntoConstraints="NO" id="uS5-tF-ldA">
                            <rect key="frame" x="313" y="2" width="50" height="21"/>
                            <constraints>
                                <constraint firstAttribute="width" constant="50" id="uS5-cN-wid"/>
                            </constraints>
                            <textFieldCell key="cell" scrollable="YES" lineBreakMode="clipping" selectable="YES" editable="YES" state="on" borderStyle="bezel" alignment="right" title="40" drawsBackground="YES" id="uS5-cE-llA">
                                <numberFormatter key="formatter" formatterBehavior="default10_4" numberStyle="none" minimumIntegerDigits="1" maximumIntegerDigits="4" id="uS5-fM-t01">
                                    <real key="minimum" value="1"/>
                                    <real key="maximum" value="4096"/>
                                </numberFormatter>
                                <font key="font" metaFont="system"/>
                                <color key="textColor" name="textColor" catalog="System" colorSpace="catalog"/>
                                <color key="backgroundColor" name="textBackgroundColor" catalog="System" colorSpace="catalog"/>
                            </textFieldCell>
                            <connections>
                                <binding destination="G2Q-fc-ddg" name="value" keyPath="values.URLShortenerMinimumLength" id="uS5-bD-001"/>
                                <binding destination="G2Q-fc-ddg" name="enabled" keyPath="values.AutomaticallyShortenOutgoingLinks" id="uS5-bD-002"/>
                            </connections>
                        </textField>
                    </subviews>
                </stackView>
```

If `ibtool` (Step 4) rejects the stackView, compare against the existing stackView `mdN-TE-pOJ` (line ~606) and mirror any additional required child elements (e.g. `visibilityPriorities`, `customSpacing`) from a freshly IB-saved example.

- [ ] **Step 2: Re-anchor the pane bottom**

In the Behavior pane's `<constraints>` block, DELETE this line:

```xml
                <constraint firstAttribute="bottom" secondItem="2fI-fE-Q2a" secondAttribute="bottom" constant="30" id="5OK-SG-6Vw"/>
```

- [ ] **Step 3: Add constraints for the new views**

In the same `<constraints>` block, add:

```xml
                <constraint firstItem="uS1-eP-arA" firstAttribute="top" secondItem="2fI-fE-Q2a" secondAttribute="bottom" constant="18" id="uSc-01-aaa"/>
                <constraint firstItem="uS1-eP-arA" firstAttribute="leading" secondItem="Fmc-YR-xfp" secondAttribute="leading" id="uSc-02-aaa"/>
                <constraint firstItem="uS1-eP-arA" firstAttribute="trailing" secondItem="Fmc-YR-xfp" secondAttribute="trailing" id="uSc-03-aaa"/>
                <constraint firstItem="uS2-cB-oxA" firstAttribute="top" secondItem="uS1-eP-arA" secondAttribute="bottom" constant="18" id="uSc-04-aaa"/>
                <constraint firstItem="uS2-cB-oxA" firstAttribute="leading" secondItem="Yrc-pc-3Zr" secondAttribute="leading" constant="42" id="uSc-05-aaa"/>
                <constraint firstAttribute="trailing" relation="greaterThanOrEqual" secondItem="uS2-cB-oxA" secondAttribute="trailing" constant="20" id="uSc-06-aaa"/>
                <constraint firstItem="uS6-sV-rwA" firstAttribute="top" secondItem="uS2-cB-oxA" secondAttribute="bottom" constant="14" id="uSc-07-aaa"/>
                <constraint firstItem="uS6-sV-rwA" firstAttribute="leading" secondItem="Yrc-pc-3Zr" secondAttribute="leading" constant="62" id="uSc-08-aaa"/>
                <constraint firstAttribute="trailing" relation="greaterThanOrEqual" secondItem="uS6-sV-rwA" secondAttribute="trailing" constant="20" id="uSc-09-aaa"/>
                <constraint firstAttribute="bottom" secondItem="uS6-sV-rwA" secondAttribute="bottom" constant="30" id="uSc-10-aaa"/>
```

Also update the pane's advisory frame (line ~865) from `height="272"` to `height="380"`.

- [ ] **Step 4: Validate the xib compiles**

Run: `ibtool --compile /private/tmp/claude-501/-Users-tjs-code-textual/6edc0465-ce26-4dac-9594-9fdc43bea0f1/scratchpad/TDCPreferences.nib "Sources/App/Resources/User Interface/en.lproj/TDCPreferences.xib"`
Expected: exit 0, no error output.

- [ ] **Step 5: Commit**

```bash
git add "Sources/App/Resources/User Interface/en.lproj/TDCPreferences.xib"
git commit -m "feat: URL shortener controls in Behavior preferences pane"
```

---

### Task 10: Full build + final verification

- [ ] **Step 1: Run the unit tests one more time**

Run: `clang -framework Foundation -fobjc-arc -I "Sources/App/Classes/Headers" Tests/TXURLShortenerTests.m Sources/App/Classes/Library/TXURLShortener.m -o /tmp/shorttest && /tmp/shorttest`
Expected: `ALL PASSED`, exit 0.

- [ ] **Step 2: Full app build**

Run: `xcodebuild -workspace Textual.xcworkspace -scheme "Textual (Debug)" -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. Fix any compile errors in the new/modified files before proceeding.

- [ ] **Step 3: Record deviations**

If implementation deviated from the spec (`docs/superpowers/specs/2026-08-10-url-shortener-design.md`), append an "As-built deviations" section there describing each deviation and why.

- [ ] **Step 4: Commit any remaining changes**

```bash
git status --short
git add -A docs/
git commit -m "docs: record as-built notes for URL shortener" || true
```

---

## Manual smoke test (after build, by the user)

1. Launch the built app, open Preferences → Behavior. Verify checkbox, service popup, and minimum-length field appear; popup/field disabled until the checkbox is on.
2. Enable, pick is.gd, connect to a test server/channel, send a message containing a >40-char https URL. The delivered message should contain an `https://is.gd/...` link instead.
3. Send a short URL (<40 chars) — sent unchanged. Send `/topic <long url>` — unchanged.
4. Disconnect the network, send a long URL — after ~10s the original message sends unchanged.
