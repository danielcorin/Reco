#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts Objective-C exceptions from narrow framework call sites into
/// recoverable NSError values. Swift cannot catch NSException directly.
@interface RecoExceptionCatcher : NSObject

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
                error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
