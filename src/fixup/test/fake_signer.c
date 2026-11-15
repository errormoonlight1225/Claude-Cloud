// Stands in for Nyxian's liveshim_syscall in the host test of nxfixup: records
// every SYS_sign call in $NXFIXUP_SIGN_LOG, and fails when $NXFIXUP_SIGN_FAIL
// is set.
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int64_t liveshim_syscall(uint32_t number, ...)
{
    va_list ap; va_start(ap, number); int fd = va_arg(ap, int); va_end(ap);
    if (getenv("NXFIXUP_SIGN_FAIL") != NULL) { errno = EPERM; return -1; }
    const char *log = getenv("NXFIXUP_SIGN_LOG");
    FILE *f = log ? fopen(log, "a") : NULL;
    if (f != NULL) { fprintf(f, "%u %d\n", number, fd); fclose(f); }
    return 0;
}
