# Image Paste/Drop Upload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paste or drag-drop an image onto the message input field, auto-upload it to catbox.moe, and insert the resulting direct URL into the input for the user to review and send.

**Architecture:** A UI-agnostic `TXImageUploader` class owns the catbox HTTP interaction, with its two tricky pieces — multipart body construction and response parsing — factored into pure class methods that are unit-tested via a standalone clang harness. `TVCMainWindowTextView` (the existing input field) detects image content on paste and drag-drop, normalizes it to PNG, inserts a numbered placeholder token, calls the uploader, and swaps the token for the URL (or an auto-clearing failure note).

**Tech Stack:** Objective-C, AppKit (`NSTextView`, `NSPasteboard`, `NSBitmapImageRep`), Foundation (`NSURLSession`), catbox.moe HTTP API. Tested with `clang -framework Foundation`.

---

## Context for the implementer

- This is a large existing Obj-C macOS app (an IRC client). It has **no XCTest target**. Do not try to add one. Pure-logic tests are standalone `.m` files compiled and run with `clang`.
- Public headers live in `Sources/App/Classes/Headers/`. Private headers live in `Sources/App/Classes/Headers/Private/`. Implementations live in `Sources/App/Classes/Library/`.
- The app is normally built in Xcode by the user. New source files must be registered in the app target's `project.pbxproj` (Task 4) before the app will compile them.
- The input field class is `Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m`. It already overrides `paste:` (around line 247) and inherits from `TVCTextViewWithIRCFormatter` (an `NSTextView` subclass) which exposes `@property (nonatomic, copy) NSString *stringValue;`.
- Commit after every task. Work happens on branch `feature/image-paste-upload` (already created).

## catbox.moe API reference (verified contract used by this plan)

- Endpoint: `POST https://catbox.moe/user/api.php`
- Encoding: `multipart/form-data`
- Fields: `reqtype=fileupload`, and file part named `fileToUpload`.
- Success: HTTP 200, response **body is the direct URL as plain text**, e.g. `https://files.catbox.moe/ab12cd.png`.
- Failure: non-200, or a 200 body that is not a URL (an error string).
- Max file size: 200 MB.

## File structure

- Create `Sources/App/Classes/Headers/TXImageUploader.h` — public interface.
- Create `Sources/App/Classes/Library/TXImageUploader.m` — implementation + pure helpers.
- Create `Tests/TXImageUploaderTests.m` — standalone clang test for the pure helpers.
- Modify `Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m` — paste/drop detection, PNG normalization, placeholder swap.
- Modify `Sources/App/Textual App.xcodeproj/project.pbxproj` — register the two new source files in the app target.

---

## Task 1: TXImageUploader multipart body builder (pure, TDD)

**Files:**
- Create: `Sources/App/Classes/Headers/TXImageUploader.h`
- Create: `Sources/App/Classes/Library/TXImageUploader.m`
- Test: `Tests/TXImageUploaderTests.m`

- [ ] **Step 1: Write the failing test**

Create `Tests/TXImageUploaderTests.m`:

```objc
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
```

- [ ] **Step 2: Create the header**

Create `Sources/App/Classes/Headers/TXImageUploader.h`:

```objc
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TXImageUploader : NSObject

/* Injectable for testing; defaults to +[NSURLSession sharedSession]. */
@property (nonatomic, strong) NSURLSession *session;

/* Uploads PNG data to catbox.moe. completion is always called on the main queue.
 On success, url is the direct https URL and error is nil. On failure, url is nil. */
- (void)uploadImageData:(NSData *)data
               filename:(NSString *)filename
             completion:(void (^)(NSString * _Nullable url, NSError * _Nullable error))completion;

#pragma mark - Pure helpers (exposed for testing)

+ (NSData *)multipartBodyForImageData:(NSData *)data
                             filename:(NSString *)filename
                             boundary:(NSString *)boundary;

+ (nullable NSString *)urlFromResponseData:(nullable NSData *)data
                                statusCode:(NSInteger)statusCode
                                     error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 3: Run test to verify it fails**

Run: `clang -framework Foundation -fobjc-arc Tests/TXImageUploaderTests.m -o /tmp/uptest 2>&1 | head`
Expected: FAIL — link/compile error, `TXImageUploader.m` not yet implemented (undefined symbol `_OBJC_CLASS_$_TXImageUploader`).

- [ ] **Step 4: Write minimal implementation**

Create `Sources/App/Classes/Library/TXImageUploader.m`:

```objc
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `clang -framework Foundation -fobjc-arc Tests/TXImageUploaderTests.m Sources/App/Classes/Library/TXImageUploader.m -o /tmp/uptest && /tmp/uptest`
Expected: 5 PASS lines, `ALL PASSED`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/App/Classes/Headers/TXImageUploader.h Sources/App/Classes/Library/TXImageUploader.m Tests/TXImageUploaderTests.m
git commit -m "feat: TXImageUploader multipart body builder + tests"
```

---

## Task 2: Response parser (pure, TDD)

**Files:**
- Modify: `Sources/App/Classes/Library/TXImageUploader.m` (replace `urlFromResponseData:` stub)
- Test: `Tests/TXImageUploaderTests.m` (add cases)

- [ ] **Step 1: Add failing tests**

In `Tests/TXImageUploaderTests.m`, add this function and call it from `main` (add `testResponseParsing();` before the summary `printf`):

```objc
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `clang -framework Foundation -fobjc-arc Tests/TXImageUploaderTests.m Sources/App/Classes/Library/TXImageUploader.m -o /tmp/uptest && /tmp/uptest`
Expected: the four new checks FAIL (stub returns nil, no error set).

- [ ] **Step 3: Implement the parser**

In `Sources/App/Classes/Library/TXImageUploader.m`, replace the `urlFromResponseData:` stub body with:

```objc
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `clang -framework Foundation -fobjc-arc Tests/TXImageUploaderTests.m Sources/App/Classes/Library/TXImageUploader.m -o /tmp/uptest && /tmp/uptest`
Expected: all checks PASS, `ALL PASSED`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/Classes/Library/TXImageUploader.m Tests/TXImageUploaderTests.m
git commit -m "feat: TXImageUploader response parser + tests"
```

---

## Task 3: Async upload method (integration, manual verification)

**Files:**
- Modify: `Sources/App/Classes/Library/TXImageUploader.m` (replace `uploadImageData:filename:completion:` stub)

This wires the pure pieces to `NSURLSession`. It is not covered by the standalone test (it makes a live request); it is verified end-to-end in Task 9. Get the code exactly right here.

- [ ] **Step 1: Implement the upload method**

In `Sources/App/Classes/Library/TXImageUploader.m`, replace the `uploadImageData:filename:completion:` stub with:

```objc
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
```

- [ ] **Step 2: Verify it still compiles against the tests**

Run: `clang -framework Foundation -fobjc-arc Tests/TXImageUploaderTests.m Sources/App/Classes/Library/TXImageUploader.m -o /tmp/uptest && /tmp/uptest`
Expected: `ALL PASSED` (existing pure tests unaffected; the new method just needs to compile).

- [ ] **Step 3: Commit**

```bash
git add Sources/App/Classes/Library/TXImageUploader.m
git commit -m "feat: TXImageUploader async catbox upload via NSURLSession"
```

---

## Task 4: Register new files in the Xcode app target

**Files:**
- Modify: `Sources/App/Textual App.xcodeproj/project.pbxproj`

The app target must know about `TXImageUploader.h`/`.m` or it won't compile them. Prefer the scripted approach; fall back to Xcode GUI.

- [ ] **Step 1: Check whether the `xcodeproj` ruby gem is available**

Run: `ruby -e "require 'xcodeproj'; puts 'ok'" 2>&1`
Expected: either `ok` (use Step 2a) or a `LoadError` (use Step 2b).

- [ ] **Step 2a: Scripted registration (if gem available)**

Run this from the repo root:

```bash
ruby - <<'RUBY'
require 'xcodeproj'
path = 'Sources/App/Textual App.xcodeproj'
proj = Xcodeproj::Project.open(path)
target = proj.targets.find { |t| t.name == 'Textual' } || proj.targets.first
group = proj.main_group.find_subpath('Classes/Library', true)
m = group.new_file('Classes/Library/TXImageUploader.m')
target.add_file_references([m])
# Header: add a file reference so it is visible; headers need not be in a build phase.
hgroup = proj.main_group.find_subpath('Classes/Headers', true)
hgroup.new_file('Classes/Headers/TXImageUploader.h')
proj.save
puts "Registered TXImageUploader in target #{target.name}"
RUBY
```

Expected: `Registered TXImageUploader in target Textual`. If the target name differs, the script picks the first target — verify it is the app target and adjust the `find` line if needed.

- [ ] **Step 2b: Manual registration (if gem NOT available)**

Tell the user to do this in Xcode, then wait for confirmation before continuing:
> In Xcode, right-click the `Classes/Library` group → "Add Files to Textual…", select `TXImageUploader.h` and `TXImageUploader.m`, ensure the "Textual" app target checkbox is ticked, and add them.

- [ ] **Step 3: Verify the `.m` is in the target's sources build phase**

Run: `grep -c "TXImageUploader.m" "Sources/App/Textual App.xcodeproj/project.pbxproj"`
Expected: `>= 2` (a `PBXBuildFile` and a `PBXFileReference` entry).

- [ ] **Step 4: Commit**

```bash
git add "Sources/App/Textual App.xcodeproj/project.pbxproj"
git commit -m "build: add TXImageUploader to Textual app target"
```

---

## Task 5: Image extraction + PNG normalization helpers in the text view

**Files:**
- Modify: `Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m`

Add a private category interface and helper methods. These extract image data from an `NSPasteboard` (used by both paste and drag) and normalize to PNG. AppKit-dependent, so verified by building the app (Task 9), not the clang harness.

- [ ] **Step 1: Add the uploader import and a private ivar/section**

At the top of `TVCMainWindowTextView.m`, add to the existing `#import` block (after `#import "TVCMainWindowTextViewPrivate.h"`):

```objc
#import "TXImageUploader.h"
```

Immediately after the `NS_ASSUME_NONNULL_BEGIN` line, add a private category with the state we need:

```objc
@interface TVCMainWindowTextView ()
@property (nonatomic, strong, nullable) TXImageUploader *imageUploader;
@property (nonatomic, assign) NSUInteger imageUploadCounter;
@end
```

- [ ] **Step 2: Add the pasteboard-image helpers**

Add these methods inside the `@implementation TVCMainWindowTextView` block (place them just above the existing `- (void)paste:` method):

```objc
#pragma mark -
#pragma mark Image Upload

/* Returns PNG data for the first image found on the pasteboard, or nil. */
- (nullable NSData *)pngImageDataFromPasteboard:(NSPasteboard *)pasteboard
{
	/* 1. Direct image data (e.g. a screenshot copied to the clipboard). */
	NSImage *image = [[NSImage alloc] initWithPasteboard:pasteboard];
	if (image != nil) {
		NSData *png = [self pngDataFromImage:image];
		if (png != nil) {
			return png;
		}
	}

	/* 2. A file URL that points at an image file (drag-drop or copied file). */
	NSArray<NSURL *> *urls =
		[pasteboard readObjectsForClasses:@[[NSURL class]]
		                          options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];

	for (NSURL *url in urls) {
		NSString *type = nil;
		if ([url getResourceValue:&type forKey:NSURLTypeIdentifierKey error:NULL] == NO || type == nil) {
			continue;
		}

		if (UTTypeConformsTo((__bridge CFStringRef)type, kUTTypeImage) == NO) {
			continue;
		}

		NSImage *fileImage = [[NSImage alloc] initWithContentsOfURL:url];
		NSData *png = [self pngDataFromImage:fileImage];
		if (png != nil) {
			return png;
		}
	}

	return nil;
}

/* Re-encodes an NSImage as PNG data. */
- (nullable NSData *)pngDataFromImage:(nullable NSImage *)image
{
	if (image == nil) {
		return nil;
	}

	NSData *tiff = image.TIFFRepresentation;
	if (tiff == nil) {
		return nil;
	}

	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:tiff];
	if (rep == nil) {
		return nil;
	}

	return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
```

Note: `UTTypeConformsTo`/`kUTTypeImage` require `#import <CoreServices/CoreServices.h>`. Add that import to the `#import` block at the top of the file if it is not already resolved transitively (verified at build time in Task 9).

- [ ] **Step 3: Verify (deferred)**

These helpers are exercised when the app is built and run in Task 9. No standalone run here.

- [ ] **Step 4: Commit**

```bash
git add "Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m"
git commit -m "feat: pasteboard image extraction + PNG normalization helpers"
```

---

## Task 6: Placeholder insert / swap logic

**Files:**
- Modify: `Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m`

The core UX: insert a numbered token, upload, then replace the exact token with the URL, or with an auto-clearing failure note.

- [ ] **Step 1: Add the upload-and-swap method**

Add inside the `@implementation` block, directly below the helpers from Task 5:

```objc
/* Inserts a placeholder token at the caret, uploads the image, and swaps the
 token for the resulting URL (or an auto-clearing failure note). */
- (void)uploadPNGImageData:(NSData *)pngData
{
	self.imageUploadCounter += 1;
	NSString *token = [NSString stringWithFormat:@"[uploading image #%lu…]",
		(unsigned long)self.imageUploadCounter];

	/* Insert the token at the current caret position. */
	if ([self shouldChangeTextInRange:self.selectedRange replacementString:token]) {
		[self.textStorage replaceCharactersInRange:self.selectedRange
		                                withString:token];
		[self didChangeText];
	}

	if (self.imageUploader == nil) {
		self.imageUploader = [TXImageUploader new];
	}

	__weak TVCMainWindowTextView *weakSelf = self;

	[self.imageUploader uploadImageData:pngData
	                          filename:@"image.png"
	                        completion:^(NSString * _Nullable url, NSError * _Nullable error)
	{
		TVCMainWindowTextView *strongSelf = weakSelf;
		if (strongSelf == nil) {
			return;
		}

		if (url != nil) {
			[strongSelf replaceToken:token withString:url appendIfMissing:YES];
		} else {
			NSString *failure = @"[image upload failed]";
			[strongSelf replaceToken:token withString:failure appendIfMissing:NO];

			/* Auto-clear the failure note after 5 seconds. */
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
			               dispatch_get_main_queue(), ^{
				[strongSelf replaceToken:failure withString:@"" appendIfMissing:NO];
			});
		}
	}];
}

/* Replaces the first occurrence of token in the field. If not found and
 appendIfMissing is YES, appends replacement to the end instead. */
- (void)replaceToken:(NSString *)token
          withString:(NSString *)replacement
     appendIfMissing:(BOOL)appendIfMissing
{
	NSString *current = self.stringValue;
	NSRange range = [current rangeOfString:token];

	if (range.location != NSNotFound) {
		if ([self shouldChangeTextInRange:range replacementString:replacement]) {
			[self.textStorage replaceCharactersInRange:range withString:replacement];
			[self didChangeText];
		}
		return;
	}

	if (appendIfMissing && replacement.length > 0) {
		NSString *separator = (current.length > 0 && [current hasSuffix:@" "] == NO) ? @" " : @"";
		self.stringValue = [current stringByAppendingFormat:@"%@%@", separator, replacement];
	}
}
```

- [ ] **Step 2: Verify (deferred)**

Exercised in Task 9 (build + run).

- [ ] **Step 3: Commit**

```bash
git add "Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m"
git commit -m "feat: placeholder token insert/swap for image uploads"
```

---

## Task 7: Hook `paste:`

**Files:**
- Modify: `Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m` (existing `- (void)paste:` at ~line 247)

- [ ] **Step 1: Route image pastes to the uploader**

Replace the existing `paste:` method:

```objc
- (void)paste:(nullable id)sender
{
	[super paste:self];

	[self recalculateTextViewSize];
}
```

with:

```objc
- (void)paste:(nullable id)sender
{
	NSData *png = [self pngImageDataFromPasteboard:[NSPasteboard generalPasteboard]];

	if (png != nil) {
		[self uploadPNGImageData:png];
		[self recalculateTextViewSize];
		return;
	}

	[super paste:self];

	[self recalculateTextViewSize];
}
```

- [ ] **Step 2: Verify (deferred)**

Exercised in Task 9.

- [ ] **Step 3: Commit**

```bash
git add "Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m"
git commit -m "feat: upload images pasted into the input field"
```

---

## Task 8: Drag & drop support

**Files:**
- Modify: `Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m`

`NSTextView` already accepts dragged text/images by default and would *insert* an image attachment. We override to intercept image drags and upload them instead, while letting everything else fall through to `super`.

- [ ] **Step 1: Register for dragged types and handle the drop**

Add these methods inside the `@implementation` block (near the image-upload section):

```objc
#pragma mark -
#pragma mark Drag and Drop

/* Called once during init via awakeFromNib on the superclass path; register here lazily. */
- (void)registerImageDragTypes
{
	[self registerForDraggedTypes:@[
		NSPasteboardTypePNG,
		NSPasteboardTypeTIFF,
		(NSString *)kUTTypeFileURL
	]];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender
{
	if ([self pngImageDataFromPasteboard:sender.draggingPasteboard] != nil) {
		return NSDragOperationCopy;
	}

	return [super draggingEntered:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender
{
	if ([self pngImageDataFromPasteboard:sender.draggingPasteboard] != nil) {
		return NSDragOperationCopy;
	}

	return [super draggingUpdated:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender
{
	NSData *png = [self pngImageDataFromPasteboard:sender.draggingPasteboard];

	if (png != nil) {
		[self uploadPNGImageData:png];
		[self recalculateTextViewSize];
		return YES;
	}

	return [super performDragOperation:sender];
}
```

- [ ] **Step 2: Call `registerImageDragTypes` at init**

Find the existing designated init or `awakeFromNib` in `TVCMainWindowTextView.m` (search for `awakeFromNib` or `initWithCoder`). Add a call to `[self registerImageDragTypes];` at the end of it.

If neither exists in this file, add:

```objc
- (void)awakeFromNib
{
	[super awakeFromNib];

	[self registerImageDragTypes];
}
```

Note: verify at build time (Task 9) that `super`'s dragging methods exist on the `NSTextView` chain; they do for standard `NSTextView`. `kUTTypeFileURL` requires `<CoreServices/CoreServices.h>` (same import as Task 5).

- [ ] **Step 3: Verify (deferred)**

Exercised in Task 9.

- [ ] **Step 4: Commit**

```bash
git add "Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m"
git commit -m "feat: upload images dropped onto the input field"
```

---

## Task 9: Build and end-to-end manual verification

**Files:** none (verification only)

- [ ] **Step 1: Build the app**

Build in Xcode (the user's normal flow), or from CLI:

Run: `xcodebuild -workspace Textual.xcworkspace -scheme Textual -configuration Debug build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. If it fails on a missing `CoreServices`/`UTType` symbol, add `#import <CoreServices/CoreServices.h>` to `TVCMainWindowTextView.m` and rebuild. (On newer SDKs you may instead need `#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>` and the `UTType` API; prefer the `CoreServices` form first since `kUTTypeImage` is already used widely in this codebase.)

- [ ] **Step 2: Manual test matrix**

Run the app, join/open any channel, and verify each:

1. **Screenshot paste:** Cmd-Shift-Ctrl-4 to copy a screenshot, focus the input, Cmd-V → `[uploading image #1…]` appears, then swaps to a `https://files.catbox.moe/…` URL. Press Enter → URL posts to the channel.
2. **Drag a PNG file** from Finder onto the input → placeholder → URL.
3. **Drag a JPG file** onto the input → placeholder → URL (uploaded as PNG).
4. **Paste plain text** (regression) → text inserts normally, no placeholder, no upload.
5. **Failure path:** temporarily disable network (turn off Wi-Fi), paste an image → placeholder swaps to `[image upload failed]`, which disappears after ~5s. Re-enable network.
6. **Two rapid pastes:** paste two images quickly → `#1` and `#2` tokens, both resolve to their own URLs.

- [ ] **Step 3: Commit (if any import fixes were needed)**

```bash
git add "Sources/App/Classes/Views/Main Window/TVCMainWindowTextView.m"
git commit -m "fix: import CoreServices for UTType image checks"
```

- [ ] **Step 4: Finish the branch**

Invoke the `superpowers:finishing-a-development-branch` skill to decide how to integrate (merge to `master` / open PR / etc.).

---

## Notes

- **No auto-send** is enforced structurally: the URL only ever lands in the input field; sending remains a manual Enter press. No task posts to a channel.
- **catbox permanent uploads only**; the host URL and `reqtype` are the single seam (in `TXImageUploader.m` / the pure body builder) for adding litterbox/expiry or an alternate host later.
- **All images normalized to PNG**; JPEG passthrough is a possible later refinement, not in v1.
