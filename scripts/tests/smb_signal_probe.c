/* Fixture-only POSIX signal regression. No production signal handler changes. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/time.h>
#include <time.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>

extern void *ap_connect_options(const char *, const char *, const char *,
                               const char *, const char *, int32_t, int32_t *);
extern void *ap_open(void *, const char *);
extern int32_t ap_read(void *, void *, uint8_t *, uint32_t, uint64_t);
extern void ap_close(void *, void *);
extern void ap_disconnect(void *);

static volatile sig_atomic_t signals_received;
static void interrupted(int number) { (void)number; ++signals_received; }

static int start_signals(void) {
        struct sigaction action;
        struct itimerval timer;
        memset(&action, 0, sizeof(action));
        action.sa_handler = interrupted;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGALRM, &action, NULL) != 0) return -1;
        memset(&timer, 0, sizeof(timer));
        timer.it_interval.tv_usec = timer.it_value.tv_usec = 200;
        return setitimer(ITIMER_REAL, &timer, NULL);
}

static void stop_signals(void) {
        struct itimerval timer = {{0, 0}, {0, 0}};
        setitimer(ITIMER_REAL, &timer, NULL);
}

static int authenticated_read(const char *user) {
        int32_t error = 0;
        if (start_signals() != 0) return 2;
        void *source = ap_connect_options("127.0.0.1:1445", "video", user,
                "aiplayer-fixture-password", "", 1, &error);
        const int authentication_signals = signals_received;
        if (!source) {
                stop_signals();
                fprintf(stderr, "Authenticated fixture connect failed: %d; signals=%d\n",
                        error, authentication_signals);
                return 3;
        }
        void *file = ap_open(source, "中文视频.mkv");
        uint8_t buffer[64 * 1024];
        const int before_reads = signals_received;
        int result = file ? 0 : 4;
        for (int block = 0; file && block < 64 && !result; ++block) {
                const uint64_t offset = (uint64_t)(block % 32) * sizeof(buffer);
                const int count = ap_read(source, file, buffer, sizeof(buffer), offset);
                if (count != sizeof(buffer)) { result = 5; break; }
                for (int byte = 0; byte < count; ++byte) {
                        if (buffer[byte] != (uint8_t)byte) { result = 6; break; }
                }
        }
        const int read_signals = signals_received - before_reads;
        if (file) ap_close(source, file);
        ap_disconnect(source);
        stop_signals();
        printf("{\"authenticationSignals\":%d,\"readSignals\":%d,\"result\":%d}\n",
                authentication_signals, read_signals, result);
        return result;
}

static int timeout_under_signals(const char *address) {
        struct smb2_context *source = smb2_init_context();
        struct timespec before, after;
        if (!source) return 7;
        smb2_set_timeout(source, 1);
        smb2_set_user(source, "fixture");
        smb2_set_password(source, "fixture");
        clock_gettime(CLOCK_MONOTONIC, &before);
        if (start_signals() != 0) return 2;
        const int result = smb2_connect_share(source, address, "video", "fixture");
        clock_gettime(CLOCK_MONOTONIC, &after);
        stop_signals();
        smb2_destroy_context(source);
        const double milliseconds = (after.tv_sec - before.tv_sec) * 1000.0 +
                (after.tv_nsec - before.tv_nsec) / 1000000.0;
        printf("{\"elapsedMillis\":%.3f,\"signals\":%d,\"result\":%d}\n",
                milliseconds, signals_received, result);
        return result < 0 ? 0 : 8;
}

int main(int argc, char **argv) {
        if (argc != 3) return 1;
        return strcmp(argv[1], "timeout") == 0
                ? timeout_under_signals(argv[2]) : authenticated_read(argv[2]);
}
