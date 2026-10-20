#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Owns one optional, process-local desktop. Releasing this object removes it.
@interface VDVirtualDisplay : NSObject
@property(nonatomic, readonly) uint32_t displayID;
+ (BOOL)isSupported;
- (nullable instancetype)initWithName:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (void)invalidate;
@end
NS_ASSUME_NONNULL_END
