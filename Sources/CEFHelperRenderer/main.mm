// CEFHelperRenderer — renderer subprocess entry (same logic as CEFHelper; CEF selects role via argv).

#import <Foundation/Foundation.h>
#import "CEFWrapper.h"

int main(int argc, char* argv[]) {
    @autoreleasepool {
        int code = [CEFWrapper executeSubprocessWithArgc:argc argv:argv];
        if (code >= 0) {
            return code;
        }
        return 1;
    }
}
