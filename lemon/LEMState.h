//
//  LEMState.h
//  Lemon
//
//  Persistent state shared across a respring. The files live outside the tweak
//  and its package, so reinstalling Lemon keeps them.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reads one property list from Lemon's state directory. A copy left by an
/// earlier build in its old log directory is adopted on the first read.
/// Returns nil when no copy exists.
NSDictionary * _Nullable LEMStateRead(NSString *name);

/// Writes one property list atomically into Lemon's state directory, with file
/// protection disabled so the state is readable before the first unlock.
/// Returns NO when the file could not be written.
BOOL LEMStateWrite(NSString *name, NSDictionary *contents);

NS_ASSUME_NONNULL_END
