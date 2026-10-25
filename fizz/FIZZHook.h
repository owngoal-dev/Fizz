//
//  FIZZHook.h
//  Fizz
//
//  Method hooking shared by the Fizz modules. The device has no Substrate
//  headers, so MSHookMessageEx is resolved at runtime and the plain Objective-C
//  runtime is used when it is missing.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether the class implements the selector itself instead of inheriting it.
BOOL FIZZClassOwnsSelector(Class cls, SEL selector);

/// The class in the hierarchy of `cls` that implements `selector`, or Nil.
Class FIZZHookOwner(Class cls, SEL selector);

/// Replaces a method implementation, through MSHookMessageEx when it is
/// available, and stores the original in `original` when it is not NULL.
/// Returns NO when no class in the hierarchy implements the selector.
BOOL FIZZInstallHook(Class cls, SEL selector, IMP replacement, IMP _Nullable *_Nullable original);

NS_ASSUME_NONNULL_END
