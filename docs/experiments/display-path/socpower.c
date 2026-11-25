// socpower SECONDS: the whole Mac's power and the GPU's, without root, for Macs without a battery gauge.
// Over SECONDS it prints one JSON line: sys_w, the mean of the SMC's system power (key PSTR) read every
// 100 ms; gpu_w, the GPU's energy from IOReport's "Energy Model" group over the window; and gpu_states,
// the share of the window the GPU spent in each performance state (IOReport "GPU Performance States",
// OFF and P1, its slowest clock, up to P15).
// Build: clang -O2 -o socpower socpower.c -framework IOKit -framework CoreFoundation -lIOReport
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

// libIOReport has no public header; these are the calls powermetrics and macmon use.
typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef,
                                                          CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);

// AppleSMC's user client: selector 2 takes this 80-byte struct (data8 9 = key info, 5 = read).
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfoData;
typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static io_connect_t smc;

static int smc_call(SMCKeyData *in, SMCKeyData *out)
{
    size_t n = sizeof(*out);
    return IOConnectCallStructMethod(smc, 2, in, sizeof(*in), out, &n);
}

// A 4-byte float key such as PSTR; -1 if the SMC has no such key.
static float smc_float(const char *k)
{
    SMCKeyData in = { 0 }, out = { 0 };
    in.key = (uint32_t)k[0] << 24 | (uint32_t)k[1] << 16 | (uint32_t)k[2] << 8 | (uint32_t)k[3];
    in.data8 = 9;
    if (smc_call(&in, &out) || out.result) {
        return -1;
    }
    in.keyInfo.dataSize = out.keyInfo.dataSize;
    in.data8 = 5;
    memset(&out, 0, sizeof(out));
    if (smc_call(&in, &out) || out.result) {
        return -1;
    }
    float f;
    memcpy(&f, out.bytes, 4);
    return f;
}

static void cstr(CFStringRef s, char *buf, size_t n)
{
    buf[0] = 0;
    if (s) {
        CFStringGetCString(s, buf, n, kCFStringEncodingUTF8);
    }
}

int main(int argc, char **argv)
{
    double secs = argc > 1 ? atof(argv[1]) : 10;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc || IOServiceOpen(svc, mach_task_self(), 0, &smc)) {
        smc = 0;
    }

    CFDictionaryRef energy = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
    CFDictionaryRef gpu = IOReportCopyChannelsInGroup(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), 0, 0, 0);
    IOReportMergeChannels(energy, gpu, NULL);
    CFMutableDictionaryRef want = CFDictionaryCreateMutableCopy(NULL, CFDictionaryGetCount(energy), energy);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, want, &subbed, 0, NULL);
    if (!sub) {
        fprintf(stderr, "socpower: no IOReport subscription\n");
        return 1;
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    CFDictionaryRef a = IOReportCreateSamples(sub, subbed, NULL);
    double sys = 0;
    int nsys = 0;
    for (int i = 0; i < (int)(secs * 10); i++) {
        usleep(100000);
        float p = smc ? smc_float("PSTR") : -1;
        if (p >= 0) {
            sys += p;
            nsys++;
        }
    }
    CFDictionaryRef b = IOReportCreateSamples(sub, subbed, NULL);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double took = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    CFDictionaryRef d = IOReportCreateSamplesDelta(a, b, NULL);
    CFArrayRef chans = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));

    double gpu_j = 0;
    char states[2048] = "";
    size_t sl = 0;
    for (CFIndex i = 0; chans && i < CFArrayGetCount(chans); i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(chans, i);
        char grp[128], name[128], unit[32];
        cstr(IOReportChannelGetGroup(ch), grp, sizeof(grp));
        cstr(IOReportChannelGetChannelName(ch), name, sizeof(name));
        if (!strcmp(grp, "Energy Model") && !strcmp(name, "GPU Energy")) {
            cstr(IOReportChannelGetUnitLabel(ch), unit, sizeof(unit));
            double scale = !strcmp(unit, "mJ") ? 1e-3 : !strcmp(unit, "uJ") ? 1e-6 : !strcmp(unit, "nJ") ? 1e-9 : 0;
            gpu_j += (double)IOReportSimpleGetIntegerValue(ch, 0) * scale;
        } else if (!strcmp(name, "GPUPH")) {
            int n = IOReportStateGetCount(ch);
            int64_t tot = 0;
            for (int s = 0; s < n; s++) {
                tot += IOReportStateGetResidency(ch, s);
            }
            for (int s = 0; s < n && sl < sizeof(states) - 64; s++) {
                char sn[32];
                cstr(IOReportStateGetNameForIndex(ch, s), sn, sizeof(sn));
                sl += snprintf(states + sl, sizeof(states) - sl, "%s\"%s\":%.4f", sl ? "," : "", sn,
                               tot ? (double)IOReportStateGetResidency(ch, s) / tot : 0);
            }
        }
    }
    printf("{\"seconds\":%.1f,\"sys_w\":%.2f,\"gpu_w\":%.3f,\"gpu_states\":{%s}}\n",
           took, nsys ? sys / nsys : -1, gpu_j / took, states);
    return 0;
}
