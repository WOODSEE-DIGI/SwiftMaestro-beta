#import "RAWPreviewDecoder.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <libraw/libraw.h>
#include <cstring>
#include <memory>

// MARK: - Helpers

static NSString* const kRAWDecoderErrorDomain = @"com.woodseedigi.swiftmaestro.rawdecoder";

/// Known camera-raw filename extensions. Used as a second-line guard because
/// the system's UTI database can incorrectly type audio/zip/executable files
/// as `public.raw-image`, which crashes LibRaw's parsers.
static NSSet<NSString*>* RAWExtensions(void) {
    static NSSet<NSString*>* set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [[NSSet alloc] initWithArray:@[
            @"3fr", @"arw", @"cr2", @"cr3", @"crw", @"dcs", @"dcr", @"dng",
            @"drf", @"eip", @"erf", @"fff", @"iiq", @"kdc", @"mef", @"mos",
            @"mrw", @"nef", @"nrw", @"orf", @"pef", @"ptx", @"pxn", @"raf",
            @"raw", @"rw2", @"rwl", @"sr2", @"srf", @"srw", @"x3f"
        ]];
    });
    return set;
}

static NSError* RAWError(int librawCode, NSString* stage, NSString* path) {
    return [NSError errorWithDomain:kRAWDecoderErrorDomain
                               code:librawCode
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"LibRaw %@ failed for %@: %s", stage, path.lastPathComponent,
            libraw_strerror(librawCode)]
    }];
}

/// Converts a LibRaw processed image (JPEG blob or raw bitmap) into an
/// NSImage that owns its pixel data (the LibRaw buffer is freed right after).
/// Defensive: reject malformed LibRaw output before copying memory.
static NSImage* _Nullable ImageFromProcessed(libraw_processed_image_t* img) {
    if (!img || img->data_size == 0 || !img->data) { return nil; }

    // Sanity cap to avoid allocating absurd bitmaps from corrupt metadata.
    const NSUInteger kMaxPixels = 25000000; // ~25 MP
    const NSUInteger pixelCount = (NSUInteger)img->width * (NSUInteger)img->height;
    if (pixelCount == 0 || pixelCount > kMaxPixels) { return nil; }

    if (img->type == LIBRAW_IMAGE_JPEG) {
        // Verify JPEG SOI marker before handing the buffer to NSImage.
        if (img->data_size < 2 ||
            ((const uint8_t*)img->data)[0] != 0xFF ||
            ((const uint8_t*)img->data)[1] != 0xD8) {
            return nil;
        }
        return [[NSImage alloc] initWithData:[NSData dataWithBytes:img->data length:img->data_size]];
    }
    if (img->type == LIBRAW_IMAGE_BITMAP) {
        if (img->bits != 8 && img->bits != 16) { return nil; }
        if (img->colors != 1 && img->colors != 3 && img->colors != 4) { return nil; }

        const NSInteger bytesPerSample = img->bits / 8;
        const NSUInteger bytesPerRow = (NSUInteger)img->width * img->colors * bytesPerSample;
        const NSUInteger expectedSize = bytesPerRow * img->height;
        if (img->data_size < expectedSize) { return nil; }

        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
            pixelsWide:img->width
            pixelsHigh:img->height
            bitsPerSample:img->bits
            samplesPerPixel:img->colors
            hasAlpha:NO
            isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace
            bytesPerRow:(NSInteger)bytesPerRow
            bitsPerPixel:img->colors * img->bits];
        if (!rep || !rep.bitmapData) { return nil; }
        memcpy(rep.bitmapData, img->data, expectedSize);
        NSImage* image = [[NSImage alloc] initWithSize:NSMakeSize(img->width, img->height)];
        [image addRepresentation:rep];
        return image;
    }
    return nil;
}

/// Downscales (longest edge ≤ maxPixelSize) and encodes as JPEG.
static NSData* _Nullable JPEGDataFromImage(NSImage* image, CGFloat maxPixelSize) {
    NSSize src = image.size;
    if (src.width < 1 || src.height < 1) { return nil; }
    const CGFloat scale = MIN(1.0, maxPixelSize / MAX(src.width, src.height));
    const NSSize dst = NSMakeSize(MAX(1, round(src.width * scale)),
                                  MAX(1, round(src.height * scale)));

    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)dst.width
        pixelsHigh:(NSInteger)dst.height
        bitsPerSample:8
        samplesPerPixel:4
        hasAlpha:YES
        isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace
        bytesPerRow:0
        bitsPerPixel:0];
    if (!rep) { return nil; }

    NSGraphicsContext* ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    ctx.imageInterpolation = NSImageInterpolationHigh;
    [image drawInRect:NSMakeRect(0, 0, dst.width, dst.height)];
    [NSGraphicsContext restoreGraphicsState];

    return [rep representationUsingType:NSBitmapImageFileTypeJPEG
                             properties:@{NSImageCompressionFactor: @0.85}];
}

// MARK: - Decoder

@implementation RAWPreviewDecoder

+ (NSData*)jpegPreviewForRAWAtPath:(NSString*)path
                      maxPixelSize:(CGFloat)maxPixelSize
                             error:(NSError**)error {
    @autoreleasepool {
        if (!path || path.length == 0) {
            if (error) {
                *error = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                             code:-10
                                         userInfo:@{NSLocalizedDescriptionKey: @"Empty RAW path"}];
            }
            return nil;
        }

        NSFileManager* fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            if (error) {
                *error = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                             code:-11
                                         userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"RAW file not found: %@", path.lastPathComponent]}];
            }
            return nil;
        }

        NSError* attrsError = nil;
        NSDictionary* attrs = [fm attributesOfItemAtPath:path error:&attrsError];
        if (!attrs) {
            if (error) { *error = attrsError; }
            return nil;
        }
        if ([attrs fileSize] == 0) {
            if (error) {
                *error = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                             code:-12
                                         userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"Empty RAW file: %@", path.lastPathComponent]}];
            }
            return nil;
        }

        NSData* result = nil;
        NSError* localError = nil;
        @try {
            try {
                result = [self decodeImplAtPath:path maxPixelSize:maxPixelSize error:&localError];
            } catch (const std::exception& e) {
                localError = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                                 code:-20
                                             userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:@"LibRaw exception (%@): %s",
                                 path.lastPathComponent, e.what()]}];
            } catch (...) {
                localError = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                                 code:-21
                                             userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:@"Unknown LibRaw exception (%@)",
                                 path.lastPathComponent]}];
            }
        } @catch (NSException* e) {
            localError = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                             code:-22
                                         userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"Objective-C exception (%@): %@",
                             path.lastPathComponent, e]}];
        }

        if (!result && error) { *error = localError; }
        return result;
    }
}

+ (NSData*)decodeImplAtPath:(NSString*)path
               maxPixelSize:(CGFloat)maxPixelSize
                       error:(NSError**)error {
    @autoreleasepool {
        // Hard guard: refuse anything that isn't a camera-raw UTI. LibRaw's
        // parsers can crash (EXC_BAD_ACCESS) on audio, video, archive, or
        // executable bytes if they are mis-typed as raw-image.
        NSString* ext = [path.pathExtension lowercaseString];
        if (ext.length > 0) {
            UTType* type = [UTType typeWithFilenameExtension:ext];
            if (![type conformsToType:UTTypeRAWImage]
                || [type conformsToType:UTTypeAudio]
                || [type conformsToType:UTTypeMovie]) {
                if (error) {
                    *error = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                                 code:-30
                                             userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:@"Refusing non-RAW file: %@", path.lastPathComponent]}];
                }
                return nil;
            }
            if (![RAWExtensions() containsObject:ext]) {
                if (error) {
                    *error = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                                 code:-31
                                             userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:@"Extension not in RAW allowlist: %@", path.lastPathComponent]}];
                }
                return nil;
            }
        }

        // LibRaw's object is very large (~MB-scale imgdata) — it must be
        // heap-allocated. Stack allocation fits the 8 MB main-thread stack
        // but overflows the 512 KB stacks of Swift concurrency cooperative
        // threads (EXC_BAD_ACCESS at the stack-guard page).
        std::unique_ptr<LibRaw> rawPtr(new LibRaw);
        LibRaw& raw = *rawPtr;
        raw.imgdata.params.use_camera_wb = 1;   // honor in-camera white balance
        raw.imgdata.params.output_color = 1;    // sRGB
        raw.imgdata.params.user_qual = 0;       // linear debayer — fastest, fine for thumbs
        raw.imgdata.params.output_bps = 8;

        int ret = raw.open_file(path.fileSystemRepresentation);
        if (ret != LIBRAW_SUCCESS) {
            if (error) { *error = RAWError(ret, @"open", path); }
            return nil;
        }

        NSImage* image = nil;

        // Fast path: embedded preview (IIQ IFD0 RGB strip, NEF/CR2/ARW/DNG
        // JPEG previews). Reads only the preview bytes — no full raw decode.
        if (raw.unpack_thumb() == LIBRAW_SUCCESS) {
            int errc = 0;
            if (libraw_processed_image_t* thumb = raw.dcraw_make_mem_thumb(&errc)) {
                image = ImageFromProcessed(thumb);
                libraw_dcraw_clear_mem(thumb);
            }
        }

        // Accept the embedded preview only when it's actually big enough for
        // the request. Many RAWs (DNG especially) embed only a tiny
        // thumbnail (e.g. 160×120) — upscaling that to a 512px grid cell
        // renders as mush, so too-small previews fall through to a real
        // debayer decode instead.
        if (image) {
            const CGFloat longest = MAX(image.size.width, image.size.height);
            if (longest < maxPixelSize * 0.9) {
                image = nil;
            }
        }

        // Slow path: half-resolution debayer of the sensor data.
        if (!image) {
            raw.imgdata.params.half_size = 1;

            ret = raw.unpack();
            if (ret != LIBRAW_SUCCESS) {
                if (error) { *error = RAWError(ret, @"unpack", path); }
                return nil;
            }
            ret = raw.dcraw_process();
            if (ret != LIBRAW_SUCCESS) {
                if (error) { *error = RAWError(ret, @"process", path); }
                return nil;
            }
            int errc = 0;
            if (libraw_processed_image_t* processed = raw.dcraw_make_mem_image(&errc)) {
                image = ImageFromProcessed(processed);
                libraw_dcraw_clear_mem(processed);
            }
        }

        if (!image) {
            if (error) {
                *error = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                             code:-1
                                         userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"No decodable image in %@", path.lastPathComponent]}];
            }
            return nil;
        }

        NSData* jpeg = JPEGDataFromImage(image, maxPixelSize);
        if (!jpeg && error) {
            *error = [NSError errorWithDomain:kRAWDecoderErrorDomain
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"JPEG encoding failed for %@", path.lastPathComponent]}];
        }
        return jpeg;
    }
}

@end
