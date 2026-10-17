#ifndef USBSHIM_H
#define USBSHIM_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t    registryEntryID;
    uint16_t    vendorID;
    uint16_t    productID;
    uint8_t     interfaceClass;
    uint8_t     interfaceSubClass;
    uint8_t     interfaceProtocol;
    char        productName[256];
    char        manufacturer[256];
    char        serialNumber[256];
} ShimMTPDeviceInfo;

int shimListMTPDevices(ShimMTPDeviceInfo **outList, int *outCount);
/* Copy a string field out of a list entry.
 * field: 0 = productName, 1 = manufacturer, 2 = serialNumber. */
void shimCopyStringField(const ShimMTPDeviceInfo *info, int field, char *out, size_t len);
int shimOpenByEntryID(uint64_t registryEntryID, void **outContext, char *errBuf, size_t errLen);
int shimGetPipes(void *ctx, uint8_t *bulkOutPipe, uint16_t *outMaxPacket,
                 uint8_t *bulkInPipe, uint16_t *inMaxPacket);
/* Bulk transfers with a watchdog. *size is in/out for reads. On timeout the
 * pipe is aborted and a non-zero kern result (kIOReturnTimeout) is returned. */
int shimWrite(void *ctx, const void *buffer, uint32_t *size, uint32_t timeoutMs);
int shimRead(void *ctx, void *buffer, uint32_t *size, uint32_t timeoutMs);
/* Clear HALT on both bulk pipes; used to recover from endpoint stalls. */
int shimClearStall(void *ctx);
void shimClose(void *ctx);
void shimFreeList(ShimMTPDeviceInfo *list);

#ifdef __cplusplus
}
#endif
#endif
