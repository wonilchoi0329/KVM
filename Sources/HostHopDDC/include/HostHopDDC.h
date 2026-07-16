#ifndef HOSTHOP_DDC_H
#define HOSTHOP_DDC_H

#include <stdint.h>

typedef struct HostHopDDCResult {
    int32_t status;
    int32_t ioReturn;
    uint32_t attemptsMade;
    uint32_t acceptedWrites;
    uint32_t chipAddress;
} HostHopDDCResult;

typedef struct HostHopDDCDisplayInfo {
    uint16_t manufacturerID;
    uint16_t productID;
    uint32_t serialNumber;
    uint32_t chipAddress;
} HostHopDDCDisplayInfo;

enum {
    HostHopDDCStatusOK = 0,
    HostHopDDCStatusNoProxy = 1,
    HostHopDDCStatusDisplayNotFound = 2,
    HostHopDDCStatusWriteFailed = 3,
    HostHopDDCStatusInvalidArgument = 4,
    HostHopDDCStatusUnavailable = 5,
};

HostHopDDCResult HostHopDDCProbeDisplay(
    uint16_t manufacturerID,
    uint16_t productID,
    uint32_t serialNumber,
    uint8_t configuredChipAddress
);

HostHopDDCResult HostHopDDCSwitchLGInput(
    uint16_t manufacturerID,
    uint16_t productID,
    uint32_t serialNumber,
    uint8_t inputValue,
    uint8_t configuredChipAddress,
    uint8_t writeCount,
    uint32_t spacingMilliseconds
);

uint32_t HostHopDDCDiscoverDisplays(
    uint16_t manufacturerID,
    uint16_t productID,
    HostHopDDCDisplayInfo *buffer,
    uint32_t capacity,
    int32_t *ioReturn
);

int32_t HostHopDDCValidateEDID(
    const uint8_t *bytes,
    uint32_t length,
    uint16_t manufacturerID,
    uint16_t productID,
    uint32_t serialNumber
);

void HostHopDDCBuildLGPacket(uint8_t inputValue, uint8_t packet[6]);
uint32_t HostHopDDCResolveChipAddress(
    const char *registryPath,
    uint8_t configuredChipAddress
);

#endif
