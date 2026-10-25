//
//  FIZZHook.m
//  Fizz
//

#import "FIZZHook.h"

#import <dlfcn.h>

typedef void (*FIZZHookMessageExFunction)(Class, SEL, IMP, IMP *);

static FIZZHookMessageExFunction FIZZHookMessageExFunctionPointer(void) {
    static FIZZHookMessageExFunction function = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        function = (FIZZHookMessageExFunction)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    });
    return function;
}

BOOL FIZZClassOwnsSelector(Class cls, SEL selector) {
    if (!cls || !selector) {
        return NO;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (sel_isEqual(method_getName(methods[index]), selector)) {
            found = YES;
            break;
        }
    }
    if (methods) {
        free(methods);
    }
    return found;
}

Class FIZZHookOwner(Class cls, SEL selector) {
    Class current = cls;
    while (current && !FIZZClassOwnsSelector(current, selector)) {
        current = class_getSuperclass(current);
    }
    return current;
}

BOOL FIZZInstallHook(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement) {
        return NO;
    }
    Class owner = FIZZHookOwner(cls, selector);
    if (!owner) {
        return NO;
    }
    Method method = class_getInstanceMethod(owner, selector);
    if (!method) {
        return NO;
    }
    FIZZHookMessageExFunction hook = FIZZHookMessageExFunctionPointer();
    if (hook) {
        hook(owner, selector, replacement, original);
    } else if (original) {
        *original = method_setImplementation(method, replacement);
    } else {
        method_setImplementation(method, replacement);
    }
    return YES;
}
