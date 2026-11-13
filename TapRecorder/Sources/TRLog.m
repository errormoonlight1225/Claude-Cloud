#import "TRLog.h"
#include <stdio.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>

#define TR_DIR "/var/mobile/Library/TapRecorder"
#define TR_LOG TR_DIR "/log.txt"

void TRLog(NSString *format, ...) {
    static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    NSLog(@"[TapRecorder] %@", msg);

    pthread_mutex_lock(&lock);
    mkdir(TR_DIR, 0755);
    // Keep the file small: start over when it grows past 64 KB.
    struct stat st;
    const char *mode = (stat(TR_LOG, &st) == 0 && st.st_size > 64 * 1024) ? "w" : "a";
    FILE *f = fopen(TR_LOG, mode);
    if (f) {
        time_t now = time(NULL);
        struct tm tm;
        localtime_r(&now, &tm);
        char ts[32];
        strftime(ts, sizeof ts, "%m-%d %H:%M:%S", &tm);
        fprintf(f, "%s [%d] %s\n", ts, getpid(), msg.UTF8String ?: "");
        fflush(f);
        fsync(fileno(f));
        fclose(f);
    }
    pthread_mutex_unlock(&lock);
}
