import Foundation

/// FileHandle's Foundation read can leave an autoreleased NSData backing each
/// block alive until the enclosing synchronous task returns. Cold recovery and
/// archive verification can read many GiB without yielding; ARC alone does not
/// bound that temporary storage. Drain Foundation temporaries per read while
/// the returned Swift Data retains its own block for the caller to consume.
enum ImageAllMigrationFileIO {
    // Match the archive verifier's bounded sequential window. Small 64 KiB
    // requests add avoidable syscall / external-volume I/O overhead for videos.
    static let resourceBlockBytes = 1_048_576
    static func read(_ handle: FileHandle, upToCount count: Int) throws -> Data? {
        try autoreleasepool {
            try handle.read(upToCount: count)
        }
    }
}
