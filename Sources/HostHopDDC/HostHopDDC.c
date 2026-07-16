#include "HostHopDDC.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <unistd.h>

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*CreateServiceFunction)(CFAllocatorRef, io_service_t);
typedef IOReturn (*CopyEDIDFunction)(IOAVServiceRef, CFDataRef *);
typedef IOReturn (*WriteI2CFunction)(IOAVServiceRef, uint32_t, uint32_t, const void *, uint32_t);

typedef struct IOAVFunctions {
    CreateServiceFunction createService;
    CopyEDIDFunction copyEDID;
    WriteI2CFunction writeI2C;
} IOAVFunctions;

static IOAVFunctions resolveFunctions(void) {
    IOAVFunctions functions = {
        .createService = (CreateServiceFunction)dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService"),
        .copyEDID = (CopyEDIDFunction)dlsym(RTLD_DEFAULT, "IOAVServiceCopyEDID"),
        .writeI2C = (WriteI2CFunction)dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C"),
    };
    return functions;
}

static bool canRead(IOAVFunctions functions) {
    return functions.createService != NULL && functions.copyEDID != NULL;
}

static HostHopDDCResult resultWithStatus(int32_t status, IOReturn ioReturn) {
    HostHopDDCResult result = {
        .status = status,
        .ioReturn = (int32_t)ioReturn,
        .attemptsMade = 0,
        .acceptedWrites = 0,
        .chipAddress = 0,
    };
    return result;
}

uint32_t HostHopDDCResolveChipAddress(const char *registryPath, uint8_t configuredChipAddress) {
    if (configuredChipAddress != 0) return configuredChipAddress;
    if (registryPath != NULL && strstr(registryPath, "/AppleT600xIO/") != NULL) return 0xB7;
    return 0x37;
}

static bool isExternal(io_service_t entry) {
    CFTypeRef location = IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), kCFAllocatorDefault, 0);
    bool external = location != NULL
        && CFGetTypeID(location) == CFStringGetTypeID()
        && CFEqual(location, CFSTR("External"));
    if (location != NULL) CFRelease(location);
    return external;
}

static bool validEDIDBytes(const UInt8 *bytes, uint32_t length) {
    static const UInt8 header[8] = {0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00};
    if (bytes == NULL || length < 128) return false;
    if (memcmp(bytes, header, sizeof(header)) != 0) return false;
    uint8_t checksum = 0;
    for (size_t index = 0; index < 128; index++) checksum = (uint8_t)(checksum + bytes[index]);
    return checksum == 0;
}

static void parseEDIDBytes(const UInt8 *bytes, HostHopDDCDisplayInfo *info) {
    info->manufacturerID = ((uint16_t)bytes[8] << 8) | bytes[9];
    info->productID = (uint16_t)bytes[10] | ((uint16_t)bytes[11] << 8);
    info->serialNumber = (uint32_t)bytes[12]
        | ((uint32_t)bytes[13] << 8)
        | ((uint32_t)bytes[14] << 16)
        | ((uint32_t)bytes[15] << 24);
}

static bool validEDID(CFDataRef edid) {
    return edid != NULL
        && CFDataGetLength(edid) <= UINT32_MAX
        && validEDIDBytes(CFDataGetBytePtr(edid), (uint32_t)CFDataGetLength(edid));
}

int32_t HostHopDDCValidateEDID(
    const uint8_t *bytes,
    uint32_t length,
    uint16_t manufacturerID,
    uint16_t productID,
    uint32_t serialNumber
) {
    if (!validEDIDBytes(bytes, length)) return 0;
    HostHopDDCDisplayInfo candidate = {0};
    parseEDIDBytes(bytes, &candidate);
    return candidate.manufacturerID == manufacturerID
        && candidate.productID == productID
        && candidate.serialNumber == serialNumber;
}

static bool edidMatches(CFDataRef edid, uint16_t manufacturerID, uint16_t productID, uint32_t serialNumber) {
    if (!validEDID(edid)) return false;
    return HostHopDDCValidateEDID(
        CFDataGetBytePtr(edid),
        (uint32_t)CFDataGetLength(edid),
        manufacturerID,
        productID,
        serialNumber
    ) != 0;
}

static IOAVServiceRef createMatchingService(
    IOAVFunctions functions,
    uint16_t manufacturerID,
    uint16_t productID,
    uint32_t serialNumber,
    uint8_t configuredChipAddress,
    HostHopDDCResult *result
) {
    if (!canRead(functions)) {
        *result = resultWithStatus(HostHopDDCStatusUnavailable, kIOReturnUnsupported);
        return NULL;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn ioResult = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceNameMatching("DCPAVServiceProxy"),
        &iterator
    );
    if (ioResult != kIOReturnSuccess) {
        *result = resultWithStatus(HostHopDDCStatusNoProxy, ioResult);
        return NULL;
    }

    bool sawExternal = false;
    IOReturn lastResult = kIOReturnNotFound;
    io_service_t entry = IO_OBJECT_NULL;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (!isExternal(entry)) {
            IOObjectRelease(entry);
            continue;
        }
        sawExternal = true;
        io_string_t registryPath = {0};
        const char *path = NULL;
        if (IORegistryEntryGetPath(entry, kIOServicePlane, registryPath) == kIOReturnSuccess) path = registryPath;
        uint32_t chipAddress = HostHopDDCResolveChipAddress(path, configuredChipAddress);
        IOAVServiceRef service = functions.createService(kCFAllocatorDefault, entry);
        IOObjectRelease(entry);
        if (service == NULL) continue;

        CFDataRef edid = NULL;
        lastResult = functions.copyEDID(service, &edid);
        bool matches = lastResult == kIOReturnSuccess
            && edidMatches(edid, manufacturerID, productID, serialNumber);
        if (edid != NULL) CFRelease(edid);
        if (matches) {
            IOObjectRelease(iterator);
            *result = resultWithStatus(HostHopDDCStatusOK, kIOReturnSuccess);
            result->chipAddress = chipAddress;
            return service;
        }
        CFRelease(service);
    }
    IOObjectRelease(iterator);
    *result = resultWithStatus(
        sawExternal ? HostHopDDCStatusDisplayNotFound : HostHopDDCStatusNoProxy,
        lastResult
    );
    return NULL;
}

uint32_t HostHopDDCDiscoverDisplays(
    uint16_t manufacturerID,
    uint16_t productID,
    HostHopDDCDisplayInfo *buffer,
    uint32_t capacity,
    int32_t *ioReturn
) {
    if (ioReturn != NULL) *ioReturn = (int32_t)kIOReturnNotFound;
    if (capacity > 0 && buffer == NULL) {
        if (ioReturn != NULL) *ioReturn = (int32_t)kIOReturnBadArgument;
        return 0;
    }
    IOAVFunctions functions = resolveFunctions();
    if (!canRead(functions)) {
        if (ioReturn != NULL) *ioReturn = (int32_t)kIOReturnUnsupported;
        return 0;
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn result = IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceNameMatching("DCPAVServiceProxy"),
        &iterator
    );
    if (result != kIOReturnSuccess) {
        if (ioReturn != NULL) *ioReturn = (int32_t)result;
        return 0;
    }
    uint32_t count = 0;
    io_service_t entry = IO_OBJECT_NULL;
    while ((entry = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (!isExternal(entry)) {
            IOObjectRelease(entry);
            continue;
        }
        io_string_t registryPath = {0};
        const char *path = NULL;
        if (IORegistryEntryGetPath(entry, kIOServicePlane, registryPath) == kIOReturnSuccess) path = registryPath;
        IOAVServiceRef service = functions.createService(kCFAllocatorDefault, entry);
        IOObjectRelease(entry);
        if (service == NULL) continue;
        CFDataRef edid = NULL;
        result = functions.copyEDID(service, &edid);
        if (result == kIOReturnSuccess && validEDID(edid)) {
            HostHopDDCDisplayInfo info = {0};
            parseEDIDBytes(CFDataGetBytePtr(edid), &info);
            if (info.manufacturerID == manufacturerID && info.productID == productID && info.serialNumber != 0) {
                info.chipAddress = HostHopDDCResolveChipAddress(path, 0);
                if (count < capacity) buffer[count] = info;
                count += 1;
            }
        }
        if (edid != NULL) CFRelease(edid);
        CFRelease(service);
    }
    IOObjectRelease(iterator);
    if (ioReturn != NULL) *ioReturn = (int32_t)(count > 0 ? kIOReturnSuccess : result);
    return count;
}

void HostHopDDCBuildLGPacket(uint8_t inputValue, uint8_t packet[6]) {
    packet[0] = 0x84;
    packet[1] = 0x03;
    packet[2] = 0xF4;
    packet[3] = 0x00;
    packet[4] = inputValue;
    uint8_t checksum = 0x6E ^ 0x50;
    for (size_t index = 0; index < 5; index++) checksum ^= packet[index];
    packet[5] = checksum;
}

HostHopDDCResult HostHopDDCProbeDisplay(
    uint16_t manufacturerID,
    uint16_t productID,
    uint32_t serialNumber,
    uint8_t configuredChipAddress
) {
    HostHopDDCResult result = resultWithStatus(HostHopDDCStatusDisplayNotFound, kIOReturnNotFound);
    IOAVFunctions functions = resolveFunctions();
    IOAVServiceRef service = createMatchingService(
        functions,
        manufacturerID,
        productID,
        serialNumber,
        configuredChipAddress,
        &result
    );
    if (service != NULL) CFRelease(service);
    return result;
}

HostHopDDCResult HostHopDDCSwitchLGInput(
    uint16_t manufacturerID,
    uint16_t productID,
    uint32_t serialNumber,
    uint8_t inputValue,
    uint8_t configuredChipAddress,
    uint8_t writeCount,
    uint32_t spacingMilliseconds
) {
    bool validInput = inputValue == 0x90 || inputValue == 0x91;
    bool validChipAddress = configuredChipAddress == 0x37 || configuredChipAddress == 0xB7;
    if (!validInput || !validChipAddress || writeCount != 2 || spacingMilliseconds != 20) {
        return resultWithStatus(HostHopDDCStatusInvalidArgument, kIOReturnBadArgument);
    }
    IOAVFunctions functions = resolveFunctions();
    if (!canRead(functions) || functions.writeI2C == NULL) {
        return resultWithStatus(HostHopDDCStatusUnavailable, kIOReturnUnsupported);
    }
    HostHopDDCResult result = resultWithStatus(HostHopDDCStatusDisplayNotFound, kIOReturnNotFound);
    IOAVServiceRef service = createMatchingService(
        functions,
        manufacturerID,
        productID,
        serialNumber,
        configuredChipAddress,
        &result
    );
    if (service == NULL) return result;

    uint8_t packet[6] = {0};
    HostHopDDCBuildLGPacket(inputValue, packet);
    IOReturn writeResult = kIOReturnError;
    for (uint8_t attempt = 0; attempt < writeCount; attempt++) {
        usleep(attempt == 0 ? 1000 : spacingMilliseconds * 1000);
        writeResult = functions.writeI2C(service, result.chipAddress, 0x50, packet, sizeof(packet));
        result.attemptsMade += 1;
        if (writeResult == kIOReturnSuccess) result.acceptedWrites += 1;
    }
    CFRelease(service);
    result.ioReturn = (int32_t)writeResult;
    result.status = result.acceptedWrites > 0 ? HostHopDDCStatusOK : HostHopDDCStatusWriteFailed;
    return result;
}
