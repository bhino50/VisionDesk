#import "VirtualDisplayBridge.h"
#import <CoreGraphics/CoreGraphics.h>

// CoreGraphics has no public desktop-creation API. These minimal declarations
// describe an undocumented runtime interface; no private symbols are linked.
// Every used selector is checked before creation. Apple may remove this backend.
// Interface reference: Chromium ui/display/mac/test/virtual_display_util_mac.mm.
@interface NSObject (VDDesktopRuntime)
- (void)setName:(NSString *)name;
- (void)setQueue:(dispatch_queue_t)queue;
- (void)setVendorID:(unsigned int)value;
- (void)setProductID:(unsigned int)value;
- (void)setSerialNum:(unsigned int)value;
- (void)setSerialNumber:(unsigned int)value;
- (void)setMaxPixelsWide:(unsigned int)value;
- (void)setMaxPixelsHigh:(unsigned int)value;
- (void)setSizeInMillimeters:(CGSize)value;
- (void)setRedPrimary:(CGPoint)value;
- (void)setGreenPrimary:(CGPoint)value;
- (void)setBluePrimary:(CGPoint)value;
- (void)setWhitePoint:(CGPoint)value;
- (id)initWithDescriptor:(id)descriptor;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
- (void)setModes:(NSArray *)modes;
- (void)setHiDPI:(unsigned int)value;
- (BOOL)applySettings:(id)settings;
- (unsigned int)displayID;
@end

static BOOL VDHasSelectors(NSString *name, NSArray<NSString *> *selectors) {
    Class cls = NSClassFromString(name);
    if (!cls) return NO;
    for (NSString *selector in selectors) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) return NO;
    }
    return YES;
}

@implementation VDVirtualDisplay {
    id _nativeDisplay;
    uint32_t _displayID;
}
+ (BOOL)isSupported {
    return VDHasSelectors(@"CGVirtualDisplay", @[@"initWithDescriptor:", @"applySettings:", @"displayID"])
        && VDHasSelectors(@"CGVirtualDisplayDescriptor", @[@"init", @"setName:", @"setQueue:",
            @"setVendorID:", @"setProductID:", @"setSerialNum:", @"setSerialNumber:", @"setMaxPixelsWide:",
            @"setMaxPixelsHigh:", @"setSizeInMillimeters:", @"setRedPrimary:",
            @"setGreenPrimary:", @"setBluePrimary:", @"setWhitePoint:"])
        && VDHasSelectors(@"CGVirtualDisplayMode", @[@"initWithWidth:height:refreshRate:"])
        && VDHasSelectors(@"CGVirtualDisplaySettings", @[@"init", @"setModes:", @"setHiDPI:"]);
}
- (instancetype)initWithName:(NSString *)name error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    NSString *failure = nil;
    if (![NSThread isMainThread]) failure = @"Create extra desktops on the main thread.";
    else if (![VDVirtualDisplay isSupported]) failure = @"Extra desktops are unavailable on this version of macOS.";
    if (!failure) {
        @try {
            id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
            [descriptor setName:name];
            [descriptor setQueue:dispatch_get_main_queue()];
            [descriptor setVendorID:0x5644];
            [descriptor setProductID:1];
            unsigned int serial = arc4random_uniform(UINT32_MAX - 1) + 1;
            [descriptor setSerialNum:serial];
            [descriptor setSerialNumber:serial];
            [descriptor setMaxPixelsWide:1920];
            [descriptor setMaxPixelsHigh:1080];
            [descriptor setSizeInMillimeters:CGSizeMake(509, 286)];
            [descriptor setRedPrimary:CGPointMake(0.64, 0.33)];
            [descriptor setGreenPrimary:CGPointMake(0.30, 0.60)];
            [descriptor setBluePrimary:CGPointMake(0.15, 0.06)];
            [descriptor setWhitePoint:CGPointMake(0.3127, 0.3290)];
            id display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
            id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1920 height:1080 refreshRate:60];
            id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
            if (display && mode && settings) {
                [settings setHiDPI:0];
                [settings setModes:@[mode]];
                if ([display applySettings:settings] && [display displayID] != kCGNullDirectDisplay) {
                    _nativeDisplay = display;
                    _displayID = [display displayID];
                    return self;
                }
            }
            failure = @"macOS could not create the extra desktop.";
        } @catch (NSException *exception) {
            // Never expose exception details or crash on an incompatible private API.
            failure = @"This macOS version does not support extra desktops reliably.";
        }
    }
    if (error) *error = [NSError errorWithDomain:@"org.visiondesk.VirtualDisplay" code:1
                                      userInfo:@{NSLocalizedDescriptionKey: failure}];
    return nil;
}
- (uint32_t)displayID { return _displayID; }
- (void)invalidate { _nativeDisplay = nil; _displayID = kCGNullDirectDisplay; }
@end
