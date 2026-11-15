// nxfixup - make the Mach-O files of /var/jb loadable and signed, on the device.
//
//   nxfixup [--all] [--check] [--no-sign] [--verbose] [--quiet] [ROOT]
//           [--then PROGRAM [ARG...]]
//
// ROOT is the directory whose contents are /var/jb (default: /var/jb itself).
// dpkg runs this after every transaction (post-invoke in dpkg.cfg.d), and it is
// run at every boot (Library/LaunchDaemons/rootless.nxfixup.plist).
//
// --then, which ends the options, names a program to become once the work is
// done, if that program exists: the boot job uses it to run the bootstrap's
// own first-time setup after everything has been signed.
//
// For every Mach-O file that is new or changed since the last run it does the
// two things a freshly unpacked rootless binary needs inside Nyxian:
//
//  1. Library paths. The dynamic loader opens /var/jb/usr/lib/libX.dylib by
//     itself, where the path layer (src/rtpatch) cannot help and the real
//     /var/jb does not exist. Such load commands and rpaths are rewritten to
//     @loader_path/..., relative to the file. Same rewrite as
//     scripts/relocate-macho.py, which does it when the bootstrap is packed.
//
//  2. Signature. iOS only maps code signed with the user's certificate.
//     Nyxian signs a program when it is spawned and a library when it is
//     dlopen()ed, but not the libraries a program merely links against. So
//     every file is handed to Nyxian's signing call here (SYS_sign, see
//     ksurface_abi.h; the caller needs the process.spawn entitlement).
//
// What was done is remembered in ROOT/var/lib/nxfixup/stamps, so a run only
// looks at files that changed. --all ignores the stamps (after the signing
// certificate was renewed). --check changes nothing. --no-sign only rewrites
// library paths and leaves the stamps alone.
//
// Original work for this project.

#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../rtpatch/jbmap.h"

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#define MH_MAGIC_32        0xfeedfaceu
#define MH_MAGIC_64        0xfeedfacfu
#define FAT_MAGIC          0xcafebabeu
#define FAT_MAGIC_64       0xcafebabfu
#define LC_REQ_DYLD        0x80000000u
#define LC_SEGMENT         0x1u
#define LC_SEGMENT_64      0x19u
#define LC_LOAD_DYLIB      0xcu
#define LC_LOAD_WEAK_DYLIB (0x18u | LC_REQ_DYLD)
#define LC_REEXPORT_DYLIB  (0x1fu | LC_REQ_DYLD)
#define LC_LAZY_LOAD_DYLIB 0x20u
#define LC_LOAD_UPWARD     (0x23u | LC_REQ_DYLD)
#define LC_RPATH           (0x1cu | LC_REQ_DYLD)

#define SYS_sign 761                   /* Nyxian ksurface_abi.h */
#define STAMP_DIR  "var/lib/nxfixup"
#define STAMP_FILE STAMP_DIR "/stamps"
#define MAX_CMDS_SIZE (4u << 20)

static int opt_all, opt_check, opt_nosign, opt_verbose, opt_quiet;
static char g_root[PATH_MAX];
static int64_t (*g_syscall)(uint32_t, ...);

static long n_paths, n_files, n_failed, n_signed, n_signfail;

static uint32_t rd32(const unsigned char *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const unsigned char *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void wr32(unsigned char *p, uint32_t v) { memcpy(p, &v, 4); }
static uint32_t be32(const unsigned char *p)
{ return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint64_t be64(const unsigned char *p) { return ((uint64_t)be32(p) << 32) | be32(p + 4); }

static int pread_all(int fd, void *buf, size_t n, off_t off)
{
    size_t done = 0;
    while (done < n) {
        ssize_t r = pread(fd, (char *)buf + done, n - done, off + (off_t)done);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        done += (size_t)r;
    }
    return 0;
}

static int pwrite_all(int fd, const void *buf, size_t n, off_t off)
{
    size_t done = 0;
    while (done < n) {
        ssize_t r = pwrite(fd, (const char *)buf + done, n - done, off + (off_t)done);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        done += (size_t)r;
    }
    return 0;
}

// ---- library paths ----------------------------------------------------------

// "@loader_path/..." for /var/jb<rest>, seen from the file at ROOT/<rel>.
static int loader_relative(const char *rel, const char *rest, char *out, size_t outsz)
{
    const char *here[128], *there[128];
    size_t herelen[128], therelen[128], nh = 0, nt = 0;
    const char *slash = strrchr(rel, '/');
    for (const char *s = rel; slash != NULL && s < slash; ) {
        const char *e = memchr(s, '/', (size_t)(slash - s));
        size_t n = e ? (size_t)(e - s) : (size_t)(slash - s);
        if (n > 0) { if (nh == 128) return -1; here[nh] = s; herelen[nh++] = n; }
        s += n + 1;
    }
    for (const char *s = rest; *s; ) {
        const char *e = strchr(s, '/');
        size_t n = e ? (size_t)(e - s) : strlen(s);
        if (n > 0) { if (nt == 128) return -1; there[nt] = s; therelen[nt++] = n; }
        if (e == NULL) break;
        s = e + 1;
    }
    size_t common = 0;
    while (common < nh && common < nt && herelen[common] == therelen[common] &&
           memcmp(here[common], there[common], herelen[common]) == 0) common++;

    size_t pos = strlen("@loader_path");
    if (pos + 1 > outsz) return -1;
    memcpy(out, "@loader_path", pos);
    for (size_t i = common; i < nh; i++) {
        if (pos + 3 + 1 > outsz) return -1;
        memcpy(out + pos, "/..", 3); pos += 3;
    }
    for (size_t i = common; i < nt; i++) {
        if (pos + 1 + therelen[i] + 1 > outsz) return -1;
        out[pos++] = '/';
        memcpy(out + pos, there[i], therelen[i]); pos += therelen[i];
    }
    out[pos] = '\0';
    return 0;
}

// Rewrites one thin Mach-O at `base` in fd. Returns the number of rewritten
// paths, or -1 with *why set.
static int relocate_slice(int fd, off_t base, const char *rel, const char **why)
{
    unsigned char hdr[32];
    if (pread_all(fd, hdr, sizeof hdr, base) != 0) return 0;
    uint32_t magic = rd32(hdr);
    size_t hs, align;
    if (magic == MH_MAGIC_64) { hs = 32; align = 8; }
    else if (magic == MH_MAGIC_32) { hs = 28; align = 4; }
    else return 0;                              // big-endian or not Mach-O
    uint32_t ncmds = rd32(hdr + 16), sizeofcmds = rd32(hdr + 20);
    if (sizeofcmds > MAX_CMDS_SIZE) { *why = "malformed load commands"; return -1; }

    unsigned char *in = malloc(sizeofcmds ? sizeofcmds : 1);
    size_t cap = (size_t)sizeofcmds + 65536, len = 0;
    unsigned char *out = calloc(1, cap);
    int changes = -1;
    uint64_t limit = 0;                         // file offset of the first section's data
    if (in == NULL || out == NULL) { *why = "out of memory"; goto done; }
    if (pread_all(fd, in, sizeofcmds, base + (off_t)hs) != 0) { *why = "malformed load commands"; goto done; }

    changes = 0;
    size_t p = 0;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (p + 8 > sizeofcmds) { *why = "malformed load commands"; changes = -1; goto done; }
        uint32_t cmd = rd32(in + p), size = rd32(in + p + 4);
        if (size < 8 || p + size > sizeofcmds) { *why = "malformed load commands"; changes = -1; goto done; }
        const unsigned char *c = in + p;
        const char *newname = NULL;
        char rewritten[PATH_MAX];
        uint32_t name_at = 0;

        if (cmd == LC_SEGMENT_64 && size >= 72) {
            uint32_t nsects = rd32(c + 64);
            for (uint32_t s = 0; s < nsects && 72 + (size_t)(s + 1) * 80 <= size; s++) {
                const unsigned char *sec = c + 72 + (size_t)s * 80;
                uint64_t ssize = rd64(sec + 40); uint32_t soff = rd32(sec + 48);
                if (soff && ssize && (limit == 0 || soff < limit)) limit = soff;
            }
        } else if (cmd == LC_SEGMENT && size >= 56) {
            uint32_t nsects = rd32(c + 48);
            for (uint32_t s = 0; s < nsects && 56 + (size_t)(s + 1) * 68 <= size; s++) {
                const unsigned char *sec = c + 56 + (size_t)s * 68;
                uint32_t ssize = rd32(sec + 36), soff = rd32(sec + 40);
                if (soff && ssize && (limit == 0 || soff < limit)) limit = soff;
            }
        } else if ((cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB ||
                    cmd == LC_LAZY_LOAD_DYLIB || cmd == LC_LOAD_UPWARD || cmd == LC_RPATH) && size >= 12) {
            name_at = rd32(c + 8);
            if (name_at >= 12 && name_at < size && memchr(c + name_at, '\0', size - name_at) != NULL) {
                const char *old = (const char *)c + name_at;
                const char *rest = nx_jb_rest(old);
                if (rest != NULL && loader_relative(rel, rest, rewritten, sizeof rewritten) == 0) {
                    newname = rewritten;
                    if (opt_verbose) printf("%s: %s -> %s\n", rel, old, newname);
                }
            }
        }

        if (newname != NULL) {
            size_t nsize = (name_at + strlen(newname) + 1 + align - 1) / align * align;
            if (len + nsize > cap) { *why = "not enough header space for the longer paths"; changes = -1; goto done; }
            memcpy(out + len, c, name_at);
            wr32(out + len + 4, (uint32_t)nsize);
            memcpy(out + len + name_at, newname, strlen(newname));
            len += nsize;
            changes++;
        } else {
            if (len + size > cap) { *why = "not enough header space for the longer paths"; changes = -1; goto done; }
            memcpy(out + len, c, size);
            len += size;
        }
        p += size;
    }
    if (changes == 0) goto done;
    if (limit == 0 || hs + len > limit) {
        *why = "not enough header space for the longer paths"; changes = -1; goto done;
    }
    if (!opt_check) {
        size_t pad = len > sizeofcmds ? len : sizeofcmds;   // also clears what a shorter path leaves
        unsigned char sz[4]; wr32(sz, (uint32_t)len);
        if (pwrite_all(fd, out, pad, base + (off_t)hs) != 0 || pwrite_all(fd, sz, 4, base + 20) != 0) {
            *why = strerror(errno); changes = -1;
        }
    }
done:
    free(in); free(out);
    return changes;
}

// 0: not Mach-O. 1: Mach-O (paths rewritten are added to *changes). -1: error.
static int relocate_file(int fd, const char *rel, int *changes, const char **why)
{
    unsigned char head[8];
    *changes = 0;
    if (pread_all(fd, head, sizeof head, 0) != 0) return 0;
    uint32_t le = rd32(head), be = be32(head);
    if (le == MH_MAGIC_64 || le == MH_MAGIC_32) {
        int c = relocate_slice(fd, 0, rel, why);
        if (c < 0) return -1;
        *changes = c;
        return 1;
    }
    if (be != FAT_MAGIC && be != FAT_MAGIC_64) return 0;
    uint32_t count = be32(head + 4);
    if (count == 0 || count > 64) return 0;       // a Java class file has the same magic
    size_t entry = be == FAT_MAGIC_64 ? 32 : 20;
    int failed = 0;
    for (uint32_t i = 0; i < count; i++) {
        unsigned char arch[32];
        if (pread_all(fd, arch, entry, (off_t)(8 + i * entry)) != 0) return 0;
        off_t base = be == FAT_MAGIC_64 ? (off_t)be64(arch + 8) : (off_t)be32(arch + 8);
        int c = relocate_slice(fd, base, rel, why);
        if (c < 0) failed = 1; else *changes += c;
    }
    return failed ? -1 : 1;
}

// ---- stamps -----------------------------------------------------------------

struct stamp { char *rel; long long size, sec, nsec, ino; };
static struct stamp *g_old, *g_new;
static size_t g_nold, g_nnew, g_capnew;

static int stamp_cmp(const void *a, const void *b)
{ return strcmp(((const struct stamp *)a)->rel, ((const struct stamp *)b)->rel); }

static void stamp_of(const struct stat *sb, struct stamp *s)
{
    s->size = (long long)sb->st_size; s->ino = (long long)sb->st_ino;
#if defined(__APPLE__)
    s->sec = (long long)sb->st_mtimespec.tv_sec; s->nsec = (long long)sb->st_mtimespec.tv_nsec;
#else
    s->sec = (long long)sb->st_mtim.tv_sec; s->nsec = (long long)sb->st_mtim.tv_nsec;
#endif
}

static void stamps_load(void)
{
    char path[PATH_MAX + 64];
    snprintf(path, sizeof path, "%s/%s", g_root, STAMP_FILE);
    FILE *f = fopen(path, "r");
    if (f == NULL) return;
    char *line = NULL; size_t cap = 0, capold = 0; ssize_t n;
    while ((n = getline(&line, &cap, f)) > 0) {
        if (line[n - 1] == '\n') line[n - 1] = '\0';
        struct stamp s; int used = 0;
        if (sscanf(line, "%lld %lld %lld %lld %n", &s.size, &s.sec, &s.nsec, &s.ino, &used) != 4 || used == 0) continue;
        if (g_nold == capold) {
            capold = capold ? capold * 2 : 256;
            g_old = realloc(g_old, capold * sizeof *g_old);
            if (g_old == NULL) { g_nold = 0; break; }
        }
        s.rel = strdup(line + used);
        if (s.rel != NULL) g_old[g_nold++] = s;
    }
    free(line);
    fclose(f);
    qsort(g_old, g_nold, sizeof *g_old, stamp_cmp);
}

static int stamp_current(const char *rel, const struct stat *sb)
{
    struct stamp key, now; key.rel = (char *)rel;
    struct stamp *hit = g_old ? bsearch(&key, g_old, g_nold, sizeof *g_old, stamp_cmp) : NULL;
    if (hit == NULL) return 0;
    stamp_of(sb, &now);
    return hit->size == now.size && hit->sec == now.sec && hit->nsec == now.nsec && hit->ino == now.ino;
}

static void stamp_keep(const char *rel, const struct stat *sb)
{
    if (g_nnew == g_capnew) {
        g_capnew = g_capnew ? g_capnew * 2 : 256;
        struct stamp *grown = realloc(g_new, g_capnew * sizeof *g_new);
        if (grown == NULL) return;
        g_new = grown;
    }
    struct stamp s; stamp_of(sb, &s);
    s.rel = strdup(rel);
    if (s.rel != NULL) g_new[g_nnew++] = s;
}

static void stamps_save(void)
{
    char dir[PATH_MAX + 64], path[PATH_MAX + 64], tmp[PATH_MAX + 72];
    snprintf(dir, sizeof dir, "%s/var", g_root); mkdir(dir, 0755);
    snprintf(dir, sizeof dir, "%s/var/lib", g_root); mkdir(dir, 0755);
    snprintf(dir, sizeof dir, "%s/%s", g_root, STAMP_DIR); mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/%s", g_root, STAMP_FILE);
    snprintf(tmp, sizeof tmp, "%s.new", path);
    FILE *f = fopen(tmp, "w");
    if (f == NULL) { fprintf(stderr, "nxfixup: cannot write %s: %s\n", tmp, strerror(errno)); return; }
    for (size_t i = 0; i < g_nnew; i++)
        fprintf(f, "%lld %lld %lld %lld %s\n", g_new[i].size, g_new[i].sec, g_new[i].nsec, g_new[i].ino, g_new[i].rel);
    if (fclose(f) != 0 || rename(tmp, path) != 0)
        fprintf(stderr, "nxfixup: cannot write %s: %s\n", path, strerror(errno));
}

// ---- the walk ---------------------------------------------------------------

static void fix_file(const char *path, const char *rel, const struct stat *sb)
{
    if (!opt_all && stamp_current(rel, sb)) { stamp_keep(rel, sb); return; }

    int fd = open(path, opt_check ? O_RDONLY : O_RDWR);
    if (fd < 0) {
        // Not writable by us: still worth knowing whether it is a Mach-O.
        if (opt_check) return;
        fd = open(path, O_RDONLY);
        if (fd < 0) return;
        unsigned char head[4];
        int macho = pread_all(fd, head, 4, 0) == 0 &&
            (rd32(head) == MH_MAGIC_64 || rd32(head) == MH_MAGIC_32 || be32(head) == FAT_MAGIC || be32(head) == FAT_MAGIC_64);
        close(fd);
        if (macho) { n_failed++; fprintf(stderr, "relocate: %s: not writable\n", rel); }
        return;
    }

    int changes = 0; const char *why = "error";
    int kind = relocate_file(fd, rel, &changes, &why);
    if (kind == 0) { close(fd); return; }
    if (kind < 0) {
        n_failed++;
        fprintf(stderr, "relocate: %s: %s\n", rel, why);
        close(fd);
        return;
    }
    if (changes > 0) { n_files++; n_paths += changes; }
    if (opt_check) { close(fd); return; }

    int ok = 1;
    if (!opt_nosign) {
        if (g_syscall == NULL) ok = 0;
        else if (g_syscall(SYS_sign, fd) != 0) {
            ok = 0; n_signfail++;
            if (!opt_quiet) fprintf(stderr, "sign: %s: %s\n", rel, strerror(errno));
        } else n_signed++;
    }
    close(fd);

    struct stat after;
    if (ok && lstat(path, &after) == 0) stamp_keep(rel, &after);
}

static void walk(const char *dir, const char *rel)
{
    DIR *d = opendir(dir);
    if (d == NULL) return;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) continue;
        char path[PATH_MAX], sub[PATH_MAX];
        if (snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= (int)sizeof path) continue;
        if (snprintf(sub, sizeof sub, "%s%s%s", rel, rel[0] ? "/" : "", e->d_name) >= (int)sizeof sub) continue;
        struct stat sb;
        if (lstat(path, &sb) != 0) continue;
        if (S_ISDIR(sb.st_mode)) {
            if (strcmp(sub, STAMP_DIR) != 0) walk(path, sub);
        } else if (S_ISREG(sb.st_mode) && sb.st_size >= 28) {
            fix_file(path, sub, &sb);
        }
    }
    closedir(d);
}

int main(int argc, char **argv)
{
    const char *root = "/var/jb";
    char **then = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--then") == 0) {
            if (i + 1 < argc) then = argv + i + 1;
            break;
        }
        else if (strcmp(argv[i], "--all") == 0) opt_all = 1;
        else if (strcmp(argv[i], "--check") == 0) opt_check = 1;
        else if (strcmp(argv[i], "--no-sign") == 0) opt_nosign = 1;
        else if (strcmp(argv[i], "--verbose") == 0) opt_verbose = 1;
        else if (strcmp(argv[i], "--quiet") == 0) opt_quiet = 1;
        else if (argv[i][0] == '-') {
            fprintf(stderr, "usage: nxfixup [--all] [--check] [--no-sign] [--verbose] [--quiet] [ROOT]"
                            " [--then PROGRAM [ARG...]]\n");
            return 2;
        } else root = argv[i];
    }

    // Work on the real directory from here on: realpath goes through the path
    // layer once, and nothing below depends on it any more.
    if (realpath(root, g_root) == NULL) {
        fprintf(stderr, "nxfixup: %s: %s\n", root, strerror(errno));
        return 2;
    }

    if (!opt_nosign && !opt_check) {
        g_syscall = (int64_t (*)(uint32_t, ...))dlsym(RTLD_DEFAULT, "liveshim_syscall");
        if (g_syscall == NULL)
            fprintf(stderr, "nxfixup: not running inside Nyxian: nothing will be signed (--no-sign to only relocate)\n");
    }

    // A stamp means "relocated and signed": without signing, neither read nor
    // write them, so a later full run still signs everything.
    if (!opt_nosign) stamps_load();
    walk(g_root, "");
    if (!opt_check && !opt_nosign) stamps_save();

    if (!opt_quiet || n_failed) {
        printf("relocate: %s %ld path(s) in %ld file(s), %ld failed\n",
               opt_check ? "would rewrite" : "rewrote", n_paths, n_files, n_failed);
        if (!opt_nosign && !opt_check && g_syscall != NULL)
            printf("sign: signed %ld file(s), %ld failed\n", n_signed, n_signfail);
    }
    int status = (n_failed || n_signfail || (!opt_nosign && !opt_check && g_syscall == NULL)) ? 1 : 0;
    if (then != NULL && !opt_check && access(then[0], X_OK) == 0) {
        fflush(stdout);
        execv(then[0], then);
        fprintf(stderr, "nxfixup: %s: %s\n", then[0], strerror(errno));
        return 1;
    }
    return status;
}
