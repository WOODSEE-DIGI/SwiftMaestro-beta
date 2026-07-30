#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Decodes camera RAW files (IIQ/NEF/CR2/CR3/ARW/DNG/RAF/ORF/RW2) into JPEG
/// data using LibRaw — the same decode engine digiKam and darktable use.
///
/// Used for RAW variants Apple's RAWCamera/ImageIO can't handle (e.g. Phase
/// One IIQ written by Capture One backs — `RA30 initImage err=-50`), and as
/// the fallback when QuickLook thumbnailing fails on any other RAW.
@interface RAWPreviewDecoder : NSObject

/// Returns JPEG data for the RAW file at `path`, downscaled so the longest
/// edge is at most `maxPixelSize`.
///
/// Strategy: try the file's embedded preview first (cheap — e.g. the IIQ
/// IFD0 588×442 RGB strip, or the JPEG previews inside NEF/CR2/ARW). When
/// no preview exists, fall back to a half-resolution debayer of the raw
/// sensor data with camera white balance and sRGB output.
///
/// Thread-safe: each call uses its own LibRaw instance. Returns nil and
/// sets `error` when the file can't be decoded at all.
+ (nullable NSData *)jpegPreviewForRAWAtPath:(NSString *)path
                                maxPixelSize:(CGFloat)maxPixelSize
                                       error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
