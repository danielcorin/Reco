#import "RecoExceptionCatcher.h"

@implementation RecoExceptionCatcher

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *description = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:@"llc.wvlen.Reco.ObjectiveCException"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return NO;
    }
}

@end
