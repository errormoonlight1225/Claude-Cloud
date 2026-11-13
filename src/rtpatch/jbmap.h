// jbmap.h - where a guest's /var/jb really is.
//
// A Nyxian guest runs on the real iOS filesystem: its "root" is only a directory
// in the app container ($vroot = <container>/Documents/rootfs), and nothing
// translates paths for it. Rootless software has /var/jb compiled in, so every
// such path has to be turned into $vroot/var/jb before it reaches the system.
//
// Pure C, no platform headers: shared by the guest runtime patch (nxjbpath.c),
// the ROM installer and the host tests.

#ifndef NX_JBMAP_H
#define NX_JBMAP_H

#include <stddef.h>
#include <string.h>

#define NX_JB        "/var/jb"
#define NX_JB_LEN    7

// Returns the part of `path` after /var/jb ("" or "/..."), or NULL when `path`
// is not /var/jb or below it. Accepts /private/var/jb and repeated leading '/'.
static inline const char *nx_jb_rest(const char *path)
{
    if (path == NULL || path[0] != '/') return NULL;
    while (path[1] == '/') path++;
    if (strncmp(path, "/private/", 9) == 0) path += 8;
    if (strncmp(path, NX_JB, NX_JB_LEN) != 0) return NULL;
    const char *rest = path + NX_JB_LEN;
    return (rest[0] == '\0' || rest[0] == '/') ? rest : NULL;
}

// Maps a /var/jb path to "<vroot>/var/jb<rest>" in `out` and returns `out`.
// Any other path, or one that does not fit, is returned unchanged.
static inline const char *nx_jbmap(const char *vroot, const char *path, char *out, size_t outsz)
{
    const char *rest = nx_jb_rest(path);
    if (rest == NULL || vroot == NULL || vroot[0] == '\0') return path;
    size_t lv = strlen(vroot), lr = strlen(rest);
    if (lv + NX_JB_LEN + lr + 1 > outsz) return path;
    memcpy(out, vroot, lv);
    memcpy(out + lv, NX_JB, NX_JB_LEN);
    memcpy(out + lv + NX_JB_LEN, rest, lr + 1);
    return out;
}

// A symlink whose target is an absolute /var/jb path would be followed by the
// real kernel to the real /var/jb, which does not exist. Stored relative to the
// link instead, it keeps working wherever the container is.
//
// `link` and `target` are both paths relative to the same root, without a
// leading '/' ("usr/bin/sh", "usr/bin/bash"). Writes the relative target
// ("bash", "../lib/x") to `out`. Returns NULL if a path has "." or ".."
// components, is empty, or the result does not fit.
static inline const char *nx_relative_target(const char *link, const char *target,
                                             char *out, size_t outsz)
{
    if (link == NULL || target == NULL || link[0] == '\0' || target[0] == '\0') return NULL;
    for (int k = 0; k < 2; k++) {
        const char *s = k ? target : link;
        if (s[0] == '/') return NULL;
        while (*s) {
            const char *e = strchr(s, '/');
            size_t n = e ? (size_t)(e - s) : strlen(s);
            if (n == 0 || (n == 1 && s[0] == '.') || (n == 2 && s[0] == '.' && s[1] == '.')) {
                if (!(n == 0 && e == NULL)) return NULL;
            }
            if (e == NULL) break;
            s = e + 1;
        }
    }
    // the directory part of `link`
    const char *slash = strrchr(link, '/');
    size_t dirlen = slash ? (size_t)(slash - link) + 1 : 0;      // includes the '/'
    // skip the components the link's directory and the target have in common
    size_t common = 0, i = 0;
    while (i < dirlen && link[i] == target[i] && target[i] != '\0') {
        if (link[i] == '/') common = i + 1;
        i++;
    }
    // one "../" for every directory left in the link's path
    size_t pos = 0;
    for (size_t j = common; j < dirlen; j++) {
        if (link[j] == '/') {
            if (pos + 3 >= outsz) return NULL;
            memcpy(out + pos, "../", 3);
            pos += 3;
        }
    }
    size_t lt = strlen(target + common);
    if (lt == 0) {                       // the target is the link's own directory or above
        if (pos == 0) { if (outsz < 2) return NULL; out[0] = '.'; out[1] = '\0'; return out; }
        out[pos - 1] = '\0';             // drop the trailing '/'
        return out;
    }
    if (pos + lt + 1 > outsz) return NULL;
    memcpy(out + pos, target + common, lt + 1);
    return out;
}

#endif /* NX_JBMAP_H */
