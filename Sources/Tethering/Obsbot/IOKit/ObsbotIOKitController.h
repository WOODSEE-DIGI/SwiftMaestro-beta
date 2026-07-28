#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// IOKit-based USB controller for OBSBOT Tiny-series webcams.
/// Unlike libusb, this opens the USB device (not the interface) so it can
/// coexist with macOS UVCAssistant on macOS 14+.
@interface ObsbotIOKitController : NSObject

- (instancetype)init NS_DESIGNATED_INITIALIZER;

/// Attempt to open the first attached OBSBOT device matching the supplied PIDs.
/// @param productIDs Array of NSNumber(UInt16) product IDs to try.
/// @return Device name on success, nil on failure.
- (nullable NSString *)connectWithProductIDs:(NSArray<NSNumber *> *)productIDs NS_SWIFT_NAME(connect(withProductIDs:));

/// Close the device handle.
- (void)disconnect;

/// Whether the device is currently open.
@property (nonatomic, readonly) BOOL isConnected;

/// Send a UVC control transfer (SET_CUR) to the device.
/// @param bytes  Payload bytes.
/// @param selector UVC control selector.
/// @param unit UVC unit ID (used as high byte of wIndex; interface is 0).
/// @return YES on success, NO on failure.
- (BOOL)sendBytes:(NSData *)bytes selector:(UInt16)selector unit:(UInt8)unit NS_SWIFT_NAME(send(_:selector:unit:));

/// Read a UVC control transfer (GET_CUR) from the device.
/// @param length Number of bytes to read.
/// @param selector UVC control selector.
/// @param unit UVC unit ID.
/// @return NSData on success, nil on failure.
- (nullable NSData *)readBytesWithLength:(NSUInteger)length selector:(UInt16)selector unit:(UInt8)unit NS_SWIFT_NAME(readBytes(withLength:selector:unit:));

/// Read a UVC control transfer with an explicit bRequest (GET_CUR/GET_MIN/GET_MAX/GET_RES/GET_INFO).
/// @param length Number of bytes to read.
/// @param selector UVC control selector.
/// @param unit UVC unit ID.
/// @param bRequest UVC request code (e.g. 0x81 for GET_CUR, 0x82 for GET_MIN, 0x83 for GET_MAX).
/// @return NSData on success, nil on failure.
- (nullable NSData *)readBytesWithLength:(NSUInteger)length selector:(UInt16)selector unit:(UInt8)unit bRequest:(UInt8)bRequest NS_SWIFT_NAME(readBytes(withLength:selector:unit:bRequest:));

@end

NS_ASSUME_NONNULL_END
