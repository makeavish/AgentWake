#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern CFTypeRef IOReportCreateSubscription(CFTypeRef, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFErrorRef *);
extern CFDictionaryRef IOReportCreateSamples(CFTypeRef, CFTypeRef, CFTypeRef);
extern void IOReportIterate(CFTypeRef, int (^)(CFDictionaryRef));
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern uint64_t IOReportChannelGetUnit(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int);

#define CLAWSHELL_IOREPORT_GETUNIT_QUANTITY(unit) (((uint64_t)(unit) >> 56) & 0xff)
#define CLAWSHELL_IOREPORT_GETUNIT_SCALE(unit) ((uint64_t)(unit) & 0x00ffffffffffffff)
#define CLAWSHELL_IOREPORT_QUANTITY_TEMPERATURE 10
#define CLAWSHELL_IOREPORT_SCALE_UNITY 0

struct ProbeResult {
    int sample_count;
    int scale_verified_count;
};

static void print_cf_string(CFStringRef value) {
    char buffer[512];
    if (!value) {
        printf("-");
        return;
    }
    if (CFStringGetCString(value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("%s", buffer);
    } else {
        printf("<non-utf8>");
    }
}

static int is_temperature_channel(CFStringRef value) {
    if (!value) {
        return 0;
    }
    CFRange range = CFRangeMake(0, CFStringGetLength(value));
    return CFStringFindWithOptions(value, CFSTR("Temp"), range, kCFCompareCaseInsensitive, NULL);
}

static int channel_info_unit(CFDictionaryRef sample, uint64_t *unit) {
    CFTypeRef channel_info = CFDictionaryGetValue(sample, CFSTR("IOReportChannelInfo"));
    if (!channel_info || CFGetTypeID(channel_info) != CFDictionaryGetTypeID()) {
        return 0;
    }

    CFTypeRef raw_unit = CFDictionaryGetValue((CFDictionaryRef)channel_info, CFSTR("IOReportChannelUnit"));
    if (!raw_unit || CFGetTypeID(raw_unit) != CFNumberGetTypeID()) {
        return 0;
    }

    int64_t signed_unit = 0;
    if (!CFNumberGetValue((CFNumberRef)raw_unit, kCFNumberSInt64Type, &signed_unit)) {
        return 0;
    }

    *unit = (uint64_t)signed_unit;
    return 1;
}

static struct ProbeResult probe(CFStringRef group, CFStringRef subgroup) {
    struct ProbeResult result = {0, 0};
    CFMutableDictionaryRef channels = IOReportCopyChannelsInGroup(group, subgroup, 0, 0, 0);
    if (!channels) {
        printf("probeResult group=");
        print_cf_string(group);
        printf(" subgroup=");
        print_cf_string(subgroup);
        printf(" channels=missing\n");
        return result;
    }

    CFMutableDictionaryRef subscribed = NULL;
    CFErrorRef error = NULL;
    CFTypeRef subscription = IOReportCreateSubscription(NULL, channels, &subscribed, 0, &error);
    if (!subscription) {
        printf("probeResult group=");
        print_cf_string(group);
        printf(" subgroup=");
        print_cf_string(subgroup);
        printf(" subscription=missing\n");
        if (error) {
            CFRelease(error);
        }
        CFRelease(channels);
        return result;
    }

    CFDictionaryRef samples = IOReportCreateSamples(subscription, subscribed, NULL);
    if (!samples) {
        printf("probeResult group=");
        print_cf_string(group);
        printf(" subgroup=");
        print_cf_string(subgroup);
        printf(" samples=missing\n");
        CFRelease(subscription);
        if (subscribed) {
            CFRelease(subscribed);
        }
        CFRelease(channels);
        return result;
    }

    __block struct ProbeResult block_result = {0, 0};
    IOReportIterate(samples, ^int(CFDictionaryRef sample) {
        CFStringRef channel_name = IOReportChannelGetChannelName(sample);
        int64_t value = IOReportSimpleGetIntegerValue(sample, 0);
        uint64_t unit = IOReportChannelGetUnit(sample);
        uint64_t raw_unit = 0;
        int raw_unit_present = channel_info_unit(sample, &raw_unit);
        uint64_t unit_quantity = CLAWSHELL_IOREPORT_GETUNIT_QUANTITY(unit);
        uint64_t unit_scale = CLAWSHELL_IOREPORT_GETUNIT_SCALE(unit);
        int scale_verified = unit_quantity == CLAWSHELL_IOREPORT_QUANTITY_TEMPERATURE &&
            unit_scale == CLAWSHELL_IOREPORT_SCALE_UNITY;
        if (!is_temperature_channel(channel_name)) {
            printf("rawSample=%lld group=", (long long)value);
            print_cf_string(IOReportChannelGetGroup(sample));
            printf(" subgroup=");
            print_cf_string(IOReportChannelGetSubGroup(sample));
            printf(" channel=");
            print_cf_string(channel_name);
            printf(" unitFieldPresent=%s unitRaw=0x%llx unitQuantity=%llu unitScale=0x%llx unitLabel=",
                raw_unit_present ? "true" : "false",
                (unsigned long long)raw_unit,
                (unsigned long long)unit_quantity,
                (unsigned long long)unit_scale);
            print_cf_string(IOReportChannelGetUnitLabel(sample));
            printf(" accepted=false source=libIOReport\n");
            return 0;
        }
        block_result.sample_count++;
        if (scale_verified) {
            block_result.scale_verified_count++;
        }
        printf("temperature=%lld group=", (long long)value);
        print_cf_string(IOReportChannelGetGroup(sample));
        printf(" subgroup=");
        print_cf_string(IOReportChannelGetSubGroup(sample));
        printf(" channel=");
        print_cf_string(channel_name);
        printf(" unitFieldPresent=%s unitRaw=0x%llx unitQuantity=%llu unitScale=0x%llx unitLabel=",
            raw_unit_present ? "true" : "false",
            (unsigned long long)raw_unit,
            (unsigned long long)unit_quantity,
            (unsigned long long)unit_scale);
        print_cf_string(IOReportChannelGetUnitLabel(sample));
        printf(" scale=%s scaleVerified=%s source=libIOReport\n", scale_verified ? "celsius" : "unverified", scale_verified ? "true" : "false");
        return 0;
    });

    CFRelease(samples);
    CFRelease(subscription);
    if (subscribed) {
        CFRelease(subscribed);
    }
    CFRelease(channels);
    return block_result;
}

int main(void) {
    struct Probe {
        CFStringRef group;
        CFStringRef subgroup;
    } probes[] = {
        {CFSTR("ANS2"), CFSTR("MSP0")},
        {CFSTR("ANS2"), CFSTR("MSP1")},
        {CFSTR("ANS2"), CFSTR("MSP2")},
        {CFSTR("ANS2"), CFSTR("MSP3")},
    };
    int sample_count = 0;
    int scale_verified_count = 0;

    printf("ioreportTemperatureProbeFormat=ioreport-temperature-probe-v1\n");
    for (size_t index = 0; index < sizeof(probes) / sizeof(probes[0]); index++) {
        struct ProbeResult result = probe(probes[index].group, probes[index].subgroup);
        sample_count += result.sample_count;
        scale_verified_count += result.scale_verified_count;
    }
    printf("temperatureScaleVerified=%s\n", sample_count > 0 && sample_count == scale_verified_count ? "true" : "false");
    printf("temperatureScaleValidationSource=IOReportChannelGetUnit\n");
    printf("temperatureSampleCount=%d\n", sample_count);
    printf("temperatureScaleVerifiedCount=%d\n", scale_verified_count);
    printf("numericTemperatureCandidateCount=%d\n", sample_count);
    printf("numericTemperatureAcceptedCount=%d\n", sample_count);
    return 0;
}
