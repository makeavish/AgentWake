#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static bool cfstring_to_cstr(CFTypeRef value, char *buffer, size_t length) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() || length == 0) {
        return false;
    }
    return CFStringGetCString((CFStringRef)value, buffer, length, kCFStringEncodingUTF8);
}

static bool contains_case_insensitive(const char *haystack, const char *needle) {
    if (!haystack || !needle || !*needle) {
        return false;
    }
    size_t needle_length = strlen(needle);
    for (const char *cursor = haystack; *cursor; cursor++) {
        if (strncasecmp(cursor, needle, needle_length) == 0) {
            return true;
        }
    }
    return false;
}

static void print_cf_value(CFTypeRef value) {
    if (!value) {
        printf("<null>");
        return;
    }
    CFTypeID type = CFGetTypeID(value);
    if (type == CFStringGetTypeID()) {
        char buffer[1024];
        if (CFStringGetCString((CFStringRef)value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            printf("\"%s\"", buffer);
        } else {
            printf("<string-unprintable>");
        }
    } else if (type == CFNumberGetTypeID()) {
        double number = 0;
        if (CFNumberGetValue((CFNumberRef)value, kCFNumberDoubleType, &number)) {
            printf("%g", number);
        } else {
            printf("<number-unprintable>");
        }
    } else if (type == CFBooleanGetTypeID()) {
        printf("%s", CFBooleanGetValue((CFBooleanRef)value) ? "true" : "false");
    } else if (type == CFDataGetTypeID()) {
        printf("<data length=%ld>", (long)CFDataGetLength((CFDataRef)value));
    } else {
        CFStringRef description = CFCopyDescription(value);
        char buffer[1024];
        if (description && CFStringGetCString(description, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
            printf("%s", buffer);
        } else {
            printf("<type=%lu>", (unsigned long)type);
        }
        if (description) {
            CFRelease(description);
        }
    }
}

static CFTypeRef copy_property(IOHIDServiceClientRef service, const char *key) {
    CFStringRef cf_key = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!cf_key) {
        return NULL;
    }
    CFTypeRef value = IOHIDServiceClientCopyProperty(service, cf_key);
    CFRelease(cf_key);
    return value;
}

static long long registry_id(IOHIDServiceClientRef service) {
    CFTypeRef value = IOHIDServiceClientGetRegistryID(service);
    long long id = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)value, kCFNumberLongLongType, &id);
    }
    return id;
}

int main(int argc, char **argv) {
    int max_details = 200;
    if (argc >= 2) {
        max_details = atoi(argv[1]);
        if (max_details <= 0) {
            max_details = 200;
        }
    }

    const char *value_keys[] = {
        "Temperature",
        "VirtualTemperature",
        "CurrentValue",
        "Value",
        "ScaledValue",
        "SensorValue",
        "Measurement",
        "HIDValue",
        "IOHIDValue"
    };

    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    if (!client) {
        fprintf(stderr, "IOHIDEventSystemClientCreateSimpleClient returned null\n");
        return 70;
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) {
        fprintf(stderr, "IOHIDEventSystemClientCopyServices returned null\n");
        CFRelease(client);
        return 71;
    }

    CFIndex service_count = CFArrayGetCount(services);
    int matched_temperature_services = 0;
    int matched_pmu_products = 0;
    int matched_nvme_products = 0;
    int detail_count = 0;
    int value_property_count = 0;
    int numeric_value_property_count = 0;

    printf("iohidProbeFormat=iohid-service-property-probe-v1\n");
    printf("serviceCount=%ld\n", (long)service_count);

    for (CFIndex index = 0; index < service_count; index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        if (!service || !IOHIDServiceClientConformsTo(service, 65280, 5)) {
            continue;
        }

        matched_temperature_services++;

        CFTypeRef product_value = copy_property(service, "Product");
        CFTypeRef class_value = copy_property(service, "IOClass");
        char product[512] = "";
        char io_class[512] = "";
        cfstring_to_cstr(product_value, product, sizeof(product));
        cfstring_to_cstr(class_value, io_class, sizeof(io_class));

        bool is_pmu = contains_case_insensitive(product, "PMU tdev") ||
            contains_case_insensitive(product, "PMU tdie") ||
            contains_case_insensitive(io_class, "AppleARMPMUTempSensor") ||
            contains_case_insensitive(io_class, "AppleSMCKeysEndpoint");
        bool is_nvme = contains_case_insensitive(product, "NAND") ||
            contains_case_insensitive(io_class, "AppleEmbeddedNVMeTemperatureSensor") ||
            contains_case_insensitive(io_class, "AppleANS");

        if (is_pmu) {
            matched_pmu_products++;
        }
        if (is_nvme) {
            matched_nvme_products++;
        }

        if (detail_count < max_details) {
            printf("service index=%ld registryID=%lld product=", (long)index, registry_id(service));
            print_cf_value(product_value);
            printf(" ioClass=");
            print_cf_value(class_value);
            printf("\n");
            detail_count++;
        }

        for (size_t key_index = 0; key_index < sizeof(value_keys) / sizeof(value_keys[0]); key_index++) {
            CFTypeRef value = copy_property(service, value_keys[key_index]);
            if (!value) {
                continue;
            }
            value_property_count++;
            if (CFGetTypeID(value) == CFNumberGetTypeID()) {
                numeric_value_property_count++;
            }
            if (detail_count < max_details) {
                printf("valueProperty index=%ld registryID=%lld key=%s value=", (long)index, registry_id(service), value_keys[key_index]);
                print_cf_value(value);
                printf("\n");
                detail_count++;
            }
            CFRelease(value);
        }

        if (product_value) {
            CFRelease(product_value);
        }
        if (class_value) {
            CFRelease(class_value);
        }
    }

    printf("matchedTemperatureServices=%d\n", matched_temperature_services);
    printf("matchedPmuProductCount=%d\n", matched_pmu_products);
    printf("matchedNvmeProductCount=%d\n", matched_nvme_products);
    printf("valuePropertyCount=%d\n", value_property_count);
    printf("numericValuePropertyCount=%d\n", numeric_value_property_count);

    CFRelease(services);
    CFRelease(client);
    return 0;
}
