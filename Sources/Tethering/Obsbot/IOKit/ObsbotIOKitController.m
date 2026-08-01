#import "ObsbotIOKitController.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBLib.h>

static const UInt16 kObsbotVendorID = 0x3564;

@interface ObsbotIOKitController () {
    io_service_t _usbDeviceService;
    IOUSBDeviceInterface **_deviceInterface;
}
@property (nonatomic, readwrite) BOOL isConnected;
@end

@implementation ObsbotIOKitController

- (instancetype)init {
    self = [super init];
    if (self) {
        _usbDeviceService = 0;
        _deviceInterface = NULL;
        _isConnected = NO;
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
}

- (nullable NSString *)connectWithProductIDs:(NSArray<NSNumber *> *)productIDs {
    [self disconnect];

    kern_return_t kr;
    mach_port_t masterPort;
    kr = IOMainPort(MACH_PORT_NULL, &masterPort);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[ObsbotIOKit] IOMasterPort failed: 0x%08x", kr);
        return nil;
    }

    __block NSString *matchedName = nil;
    for (NSNumber *pidNumber in productIDs) {
        UInt16 pid = [pidNumber unsignedShortValue];
        CFMutableDictionaryRef matchingDict = IOServiceMatching(kIOUSBDeviceClassName);
        if (!matchingDict) continue;

        CFNumberRef vidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt16Type, &kObsbotVendorID);
        CFNumberRef pidRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt16Type, &pid);
        CFDictionarySetValue(matchingDict, CFSTR(kUSBVendorID), vidRef);
        CFDictionarySetValue(matchingDict, CFSTR(kUSBProductID), pidRef);
        CFRelease(vidRef);
        CFRelease(pidRef);

        io_iterator_t iterator = 0;
        kr = IOServiceGetMatchingServices(masterPort, matchingDict, &iterator);
        if (kr != KERN_SUCCESS) {
            NSLog(@"[ObsbotIOKit] IOServiceGetMatchingServices failed for PID 0x%04x: 0x%08x", pid, kr);
            if (iterator) IOObjectRelease(iterator);
            continue;
        }

        io_service_t service = IOIteratorNext(iterator);
        if (iterator) IOObjectRelease(iterator);

        if (!service) {
            continue;
        }

        _usbDeviceService = service;
        kr = [self openDevice];
        if (kr != KERN_SUCCESS) {
            NSLog(@"[ObsbotIOKit] Open device failed for PID 0x%04x: 0x%08x", pid, kr);
            IOObjectRelease(_usbDeviceService);
            _usbDeviceService = 0;
            continue;
        }

        matchedName = [self deviceNameForService:service];
        self.isConnected = YES;
        NSLog(@"[ObsbotIOKit] Connected to OBSBOT PID 0x%04x (%@)", pid, matchedName);
        break;
    }

    mach_port_deallocate(mach_task_self(), masterPort);
    return matchedName;
}

- (kern_return_t)openDevice {
    kern_return_t kr;
    IOCFPlugInInterface **pluginInterface = NULL;
    SInt32 score = 0;

    kr = IOCreatePlugInInterfaceForService(_usbDeviceService,
                                            kIOUSBDeviceUserClientTypeID,
                                            kIOCFPlugInInterfaceID,
                                            &pluginInterface,
                                            &score);
    if (kr != KERN_SUCCESS || !pluginInterface) {
        NSLog(@"[ObsbotIOKit] IOCreatePlugInInterfaceForService failed: 0x%08x", kr);
        return kr;
    }

    HRESULT hr = (*pluginInterface)->QueryInterface(pluginInterface,
                                                   CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                                   (LPVOID *)&_deviceInterface);
    (*pluginInterface)->Release(pluginInterface);
    pluginInterface = NULL;
    if (hr != S_OK || !_deviceInterface) {
        NSLog(@"[ObsbotIOKit] QueryInterface failed: 0x%08x", hr);
        return hr;
    }

    kr = (*_deviceInterface)->USBDeviceOpen(_deviceInterface);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[ObsbotIOKit] USBDeviceOpen failed: 0x%08x", kr);
        (*_deviceInterface)->Release(_deviceInterface);
        _deviceInterface = NULL;
    }
    return kr;
}

- (nullable NSString *)deviceNameForService:(io_service_t)service {
    CFStringRef nameRef = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBProductString), kCFAllocatorDefault, 0);
    if (nameRef) {
        NSString *name = (__bridge_transfer NSString *)nameRef;
        return name;
    }
    return nil;
}

- (void)disconnect {
    if (_deviceInterface) {
        (*_deviceInterface)->USBDeviceClose(_deviceInterface);
        (*_deviceInterface)->Release(_deviceInterface);
        _deviceInterface = NULL;
    }
    if (_usbDeviceService) {
        IOObjectRelease(_usbDeviceService);
        _usbDeviceService = 0;
    }
    self.isConnected = NO;
}

- (BOOL)sendBytes:(NSData *)bytes selector:(UInt16)selector unit:(UInt8)unit {
    if (!_deviceInterface) return NO;

    IOUSBDevRequest request;
    memset(&request, 0, sizeof(request));
    request.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface);
    request.bRequest = 0x01; // UVC SET_CUR
    request.wValue = selector;
    request.wIndex = ((UInt16)unit << 8) | 0; // interface 0
    request.wLength = (UInt16)bytes.length;
    request.pData = (void *)bytes.bytes;

    kern_return_t kr = (*_deviceInterface)->DeviceRequest(_deviceInterface, &request);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[ObsbotIOKit] SET_CUR selector 0x%04x unit %u failed: 0x%08x", selector, unit, kr);
        return NO;
    }
    return YES;
}

- (nullable NSData *)readBytesWithLength:(NSUInteger)length selector:(UInt16)selector unit:(UInt8)unit {
    return [self readBytesWithLength:length selector:selector unit:unit bRequest:0x81]; // UVC GET_CUR
}

- (nullable NSData *)readBytesWithLength:(NSUInteger)length selector:(UInt16)selector unit:(UInt8)unit bRequest:(UInt8)bRequest {
    if (!_deviceInterface) return nil;

    NSMutableData *data = [NSMutableData dataWithLength:length];
    IOUSBDevRequest request;
    memset(&request, 0, sizeof(request));
    request.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBClass, kUSBInterface);
    request.bRequest = bRequest;
    request.wValue = selector;
    request.wIndex = ((UInt16)unit << 8) | 0; // interface 0
    request.wLength = (UInt16)length;
    request.pData = data.mutableBytes;

    kern_return_t kr = (*_deviceInterface)->DeviceRequest(_deviceInterface, &request);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[ObsbotIOKit] GET request 0x%02x selector 0x%04x unit %u failed: 0x%08x", bRequest, selector, unit, kr);
        return nil;
    }

    // wLength may be updated by the device to the actual number of bytes transferred.
    if (request.wLength < length) {
        [data setLength:request.wLength];
    }
    return data;
}

@end
