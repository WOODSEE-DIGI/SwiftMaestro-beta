#import "RAWPreviewDecoder.h"

#include <libraw/libraw.h>
#include <cstring>
#include <memory>

// MARK: - Helpers

static NSString* const kRAWDecoderErrorDomain = @"com.woodseedigi.swiftmaestro.rawdecoder";

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
static NSImage* _Nullable ImageFromProcessed(libraw_processed_image_t* img) {
    if (img->type == LIBRAW_IMAGE_JPEG) {
        return [[NSImage alloc] initWithData:[NSData dataWithBytes:img->data length:img->data_size]];
    }
    if (img->type == LIBRAW_IMAGE_BITMAP) {
        const NSInteger bytesPerSample = img->bits / 8;
        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
            pixelsWide:img->width
            pixelsHigh:img->height
            bitsPerSample:img->bits
            samplesPerPixel:img->colors
            hasAlpha:NO
            isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace
            bytesPerRow:img->width * img->colors * bytesPerSample
            bitsPerPixel:img->colors * img->bits];
        if (!rep) { return nil; }
        memcpy(rep.bitmapData, img->data, (size_t)img->data_size);
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
