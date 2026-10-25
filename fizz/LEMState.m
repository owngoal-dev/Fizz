//
//  LEMState.m
//  Fizz
//
//  Fizz keeps its state in <jbroot>/var/mobile/Library/Fizz, with the plain
//  /var/mobile/Library/Fizz and the temporary directory as fallbacks for other
//  bootstrap layouts. The bootstrap root is found by walking up from the loaded
//  image, the same way on roothide and rootful layouts.
//

#import "LEMState.h"

#import <dlfcn.h>

static NSString *const LEMStateDirectoryName = @"Fizz";

static NSString *LEMJBRootPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info info;
        if (dladdr((const void *)LEMJBRootPath, &info) == 0 || info.dli_fname == NULL) {
            return;
        }
        NSString *current = [NSString stringWithUTF8String:info.dli_fname];
        for (NSUInteger depth = 0; depth < 10 && current.length > 1; depth++) {
            current = [current stringByDeletingLastPathComponent];
            if ([current.lastPathComponent hasPrefix:@".jbroot-"]) {
                path = current;
                return;
            }
        }
    });
    return path;
}

static NSArray<NSString *> *LEMStateDirectoryCandidates(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *jbroot = LEMJBRootPath();
    if (jbroot.length > 0) {
        [candidates addObject:[jbroot stringByAppendingPathComponent:@"var/mobile/Library/Fizz"]];
    }
    [candidates addObject:@"/var/mobile/Library/Fizz"];
    [candidates addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:LEMStateDirectoryName]];
    return candidates;
}

static NSString *LEMStateDirectory(void) {
    static NSString *directory = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *manager = [NSFileManager defaultManager];
        for (NSString *candidate in LEMStateDirectoryCandidates()) {
            BOOL created = [manager createDirectoryAtPath:candidate
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
            if (created && [manager isWritableFileAtPath:candidate]) {
                directory = candidate;
                break;
            }
        }
    });
    return directory;
}

static NSArray<NSString *> *LEMLegacyStatePaths(NSString *name) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *jbroot = LEMJBRootPath();
    if (jbroot.length > 0) {
        NSString *directory = [jbroot stringByAppendingPathComponent:@"var/log/lemon"];
        [paths addObject:[directory stringByAppendingPathComponent:name]];
    }
    [paths addObject:[@"/var/jb/var/log/lemon" stringByAppendingPathComponent:name]];
    return paths;
}

NSDictionary *LEMStateRead(NSString *name) {
    if (name.length == 0) {
        return nil;
    }
    NSString *directory = LEMStateDirectory();
    if (directory.length > 0) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:path];
        if (stored) {
            return stored;
        }
    }
    for (NSString *legacyPath in LEMLegacyStatePaths(name)) {
        NSDictionary *stored = [NSDictionary dictionaryWithContentsOfFile:legacyPath];
        if (!stored) {
            continue;
        }
        // Older builds wrote here; carry the file over so the first launch after
        // an upgrade does not lose what was already recorded.
        LEMStateWrite(name, stored);
        return stored;
    }
    return nil;
}

BOOL LEMStateWrite(NSString *name, NSDictionary *contents) {
    NSString *directory = LEMStateDirectory();
    if (name.length == 0 || directory.length == 0) {
        return NO;
    }
    NSString *path = [directory stringByAppendingPathComponent:name];
    if (![contents writeToFile:path atomically:YES]) {
        return NO;
    }
    [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                     ofItemAtPath:path
                                            error:NULL];
    return YES;
}
