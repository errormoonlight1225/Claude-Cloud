// nxrom_install.m - the ROM's NXRomInstaller.
//
// Nyxian's bootloader dlopen()s this and calls NXRomInstall(slotPath) once, at
// flash time, before the slot is sealed. It runs in the Nyxian app process, so
// it may write the app container. Its one job: lay the rootless /var/jb
// bootstrap into the ROM's data partition (the writable area that survives
// flashes), the first time only, so an overwrite-upgrade keeps the user's
// installed packages.
//
// The bootstrap ships inside the ROM as an uncompressed tar at
//   <slot>/bootstrap/bootstrap.tar
// with entries relative to /var/jb (e.g. "usr/bin/apt", "etc/apt/sources.list").
// We extract it into  $(BOOTROOT)/Documents/rootfs/var/jb , which the manifest
// declares as NXRomDataPartitionPath, and which a guest sees as /var/jb because
// Documents/rootfs is the guest vroot.
//
// Original work for this project. Uses only a minimal in-process tar reader so
// it needs no fork/exec (an iOS app cannot spawn) and no external archiver.

#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

// Must match NXRomDataPartitionPath in manifest.plist (minus the $(BOOTROOT)/).
static NSString *const kDataPartitionSuffix = @"Documents/rootfs/var/jb";
static NSString *const kBootstrapInSlot      = @"bootstrap/bootstrap.tar";
static NSString *const kStrapMarker          = @".nx_bootstrapped";

static void emit(NSString *line) { fprintf(stderr, "%s\n", line.UTF8String); }

// ---- minimal tar (ustar + GNU long name/link) reader ----

static unsigned long octal(const char *p, size_t n)
{
    unsigned long v = 0;
    for (size_t i = 0; i < n && p[i]; i++) {
        if (p[i] < '0' || p[i] > '7') continue;
        v = (v << 3) + (unsigned long)(p[i] - '0');
    }
    return v;
}

// Reject an entry name that would escape the destination root.
static BOOL nameIsSafe(NSString *name)
{
    if (name.length == 0) return NO;
    if ([name hasPrefix:@"/"]) return NO;
    for (NSString *c in [name componentsSeparatedByString:@"/"])
        if ([c isEqualToString:@".."]) return NO;
    return YES;
}

static BOOL makeDirs(NSString *path)
{
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
                withIntermediateDirectories:YES attributes:nil error:NULL];
}

// Extract `tarPath` under `destRoot`. Returns NO on a read/format/write error.
static BOOL extractTar(NSString *tarPath, NSString *destRoot)
{
    int fd = open(tarPath.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) { emit([NSString stringWithFormat:@"cannot open %@: %s", tarPath, strerror(errno)]); return NO; }

    BOOL ok = YES;
    NSString *longName = nil, *longLink = nil;   // GNU 'L'/'K'
    NSString *paxName = nil, *paxLink = nil;      // PAX 'x' path=/linkpath=
    char block[512];
    long nFiles = 0, nDirs = 0, nLinks = 0;

    for (;;) {
        ssize_t r = read(fd, block, 512);
        if (r == 0) break;                      // clean EOF (no end blocks)
        if (r != 512) { emit(@"short read in tar"); ok = NO; break; }

        // Two zero blocks mark the end; one all-zero header ends the stream.
        BOOL allZero = YES;
        for (int i = 0; i < 512; i++) if (block[i]) { allZero = NO; break; }
        if (allZero) break;

        char typeflag = block[156];
        unsigned long size = octal(block + 124, 12);
        unsigned long mode = octal(block + 100, 8);

        // Name precedence: PAX path=, then GNU long name, then header (+ustar prefix).
        NSString *name;
        if (paxName) { name = paxName; paxName = nil; }
        else if (longName) { name = longName; longName = nil; }
        else {
            char nbuf[101]; memcpy(nbuf, block, 100); nbuf[100] = 0;
            NSString *base = [NSString stringWithUTF8String:nbuf] ?: @"";
            char pbuf[156]; memcpy(pbuf, block + 345, 155); pbuf[155] = 0;
            NSString *prefix = (block[345] && strncmp(block + 257, "ustar", 5) == 0)
                ? [NSString stringWithUTF8String:pbuf] : nil;
            name = prefix.length ? [NSString stringWithFormat:@"%@/%@", prefix, base] : base;
        }
        NSString *linkname = nil;
        if (paxLink) { linkname = paxLink; paxLink = nil; }
        else if (longLink) { linkname = longLink; longLink = nil; }
        else { char lbuf[101]; memcpy(lbuf, block + 157, 100); lbuf[100] = 0; linkname = [NSString stringWithUTF8String:lbuf]; }

        size_t dataBlocks = (size + 511) / 512;

        // GNU long-name / long-link: the datum is the real name for the NEXT header.
        if (typeflag == 'L' || typeflag == 'K') {
            NSMutableData *acc = [NSMutableData data];
            for (size_t i = 0; i < dataBlocks; i++) {
                if (read(fd, block, 512) != 512) { ok = NO; break; }
                NSUInteger take = (i == dataBlocks - 1) ? (size - i * 512) : 512;
                [acc appendBytes:block length:take];
            }
            if (!ok) break;
            NSString *s = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding];
            s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
            if (typeflag == 'L') longName = s; else longLink = s;
            continue;
        }
        // PAX extended header: records "LEN KEY=VALUE\n". We read path= and
        // linkpath= and apply them to the next entry. ('g' globals are rare in
        // bootstraps; treat them the same, applying to what follows.)
        if (typeflag == 'x' || typeflag == 'g') {
            NSMutableData *acc = [NSMutableData data];
            for (size_t i = 0; i < dataBlocks; i++) {
                if (read(fd, block, 512) != 512) { ok = NO; break; }
                NSUInteger take = (i == dataBlocks - 1) ? (size - i * 512) : 512;
                [acc appendBytes:block length:take];
            }
            if (!ok) break;
            const char *b = acc.bytes; size_t n = acc.length, i = 0;
            while (i < n) {
                size_t j = i; unsigned long reclen = 0;
                while (j < n && b[j] >= '0' && b[j] <= '9') { reclen = reclen * 10 + (b[j] - '0'); j++; }
                if (reclen == 0 || i + reclen > n || j >= n || b[j] != ' ') break;
                size_t kstart = j + 1, eq = kstart;
                while (eq < i + reclen && b[eq] != '=') eq++;
                if (eq < i + reclen && b[eq] == '=') {
                    NSString *key = [[NSString alloc] initWithBytes:b + kstart length:eq - kstart encoding:NSUTF8StringEncoding];
                    size_t vstart = eq + 1, vend = i + reclen;             // record ends with '\n'
                    if (vend > vstart && b[vend - 1] == '\n') vend--;
                    NSString *val = [[NSString alloc] initWithBytes:b + vstart length:vend - vstart encoding:NSUTF8StringEncoding];
                    if ([key isEqualToString:@"path"]) paxName = val;
                    else if ([key isEqualToString:@"linkpath"]) paxLink = val;
                }
                i += reclen;
            }
            continue;
        }

        if (!nameIsSafe(name)) { emit([NSString stringWithFormat:@"unsafe entry skipped: %@", name]);
            for (size_t i = 0; i < dataBlocks; i++) if (read(fd, block, 512) != 512) { ok = NO; break; }
            if (!ok) break; continue; }

        NSString *dest = [destRoot stringByAppendingPathComponent:name];

        if (typeflag == '5') {                  // directory
            if (!makeDirs(dest)) { emit([NSString stringWithFormat:@"mkdir failed: %@", dest]); ok = NO; break; }
            if (mode) chmod(dest.fileSystemRepresentation, (mode_t)mode);
            nDirs++;
            continue;
        }
        if (typeflag == '2') {                   // symlink
            makeDirs([dest stringByDeletingLastPathComponent]);
            unlink(dest.fileSystemRepresentation);
            if (symlink(linkname.fileSystemRepresentation, dest.fileSystemRepresentation) != 0)
                emit([NSString stringWithFormat:@"symlink %@ failed: %s", dest, strerror(errno)]);
            else nLinks++;
            continue;
        }
        if (typeflag == '1') {                    // hard link
            makeDirs([dest stringByDeletingLastPathComponent]);
            NSString *target = [destRoot stringByAppendingPathComponent:linkname];
            unlink(dest.fileSystemRepresentation);
            if (link(target.fileSystemRepresentation, dest.fileSystemRepresentation) != 0)
                emit([NSString stringWithFormat:@"hardlink %@ failed: %s", dest, strerror(errno)]);
            else nLinks++;
            continue;
        }
        // '0' or '\0': a regular file.
        makeDirs([dest stringByDeletingLastPathComponent]);
        int out = open(dest.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, mode ? (mode_t)mode : 0644);
        if (out < 0) { emit([NSString stringWithFormat:@"create %@ failed: %s", dest, strerror(errno)]); ok = NO; break; }
        unsigned long remaining = size;
        for (size_t i = 0; i < dataBlocks; i++) {
            if (read(fd, block, 512) != 512) { emit(@"short read in file data"); ok = NO; break; }
            size_t take = remaining < 512 ? remaining : 512;
            if (take && write(out, block, take) != (ssize_t)take) { emit([NSString stringWithFormat:@"write %@ failed", dest]); ok = NO; }
            remaining -= take;
        }
        close(out);
        if (mode) chmod(dest.fileSystemRepresentation, (mode_t)mode);
        if (!ok) break;
        nFiles++;
    }

    close(fd);
    if (ok) emit([NSString stringWithFormat:@"extracted %ld files, %ld dirs, %ld links", nFiles, nDirs, nLinks]);
    return ok;
}

// ---- entry point ----

int NXRomInstall(const char *slotPath)
{
    @autoreleasepool {
        NSString *slot = [NSString stringWithUTF8String:slotPath ?: ""];
        NSString *home = NSHomeDirectory();
        NSString *dest = [home stringByAppendingPathComponent:kDataPartitionSuffix];
        NSString *marker = [dest stringByAppendingPathComponent:kStrapMarker];
        NSFileManager *fm = [NSFileManager defaultManager];

        if ([fm fileExistsAtPath:marker]) {
            emit(@"/var/jb already set up by an earlier flash; keeping it");
            return 0;
        }

        NSString *tar = [slot stringByAppendingPathComponent:kBootstrapInSlot];
        if (![fm fileExistsAtPath:tar]) {
            emit([NSString stringWithFormat:@"no bootstrap at %@; nothing to install", tar]);
            return 0;  // an empty ROM is allowed; just no bootstrap
        }

        if (!makeDirs(dest)) { emit([NSString stringWithFormat:@"cannot create %@", dest]); return 1; }
        emit([NSString stringWithFormat:@"installing rootless bootstrap into %@", dest]);
        if (!extractTar(tar, dest)) { emit(@"bootstrap extraction failed"); return 1; }

        [@"" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        emit(@"bootstrap installed");
        return 0;
    }
}
