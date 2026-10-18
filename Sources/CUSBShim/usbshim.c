/*
 *  File:    usbshim.c
 *  Project: SyncHarmonyOS
 *  Author:  David Zhang
 *  Version: 1.0.0
 *  Date:    2026-10-18
 *  License: MIT
 */

#include "usbshim.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USBSpec.h>
#include <pthread.h>
#include <time.h>
#include <mach/mach_port.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    IOUSBInterfaceInterface300 **intf;
    uint8_t bulkOutPipe;
    uint8_t bulkInPipe;
    uint16_t outMaxPacket;
    uint16_t inMaxPacket;
    /* Async completion plumbing: one dedicated run-loop thread services the
     * user client's async event source so reads/writes can time out. */
    mach_port_t asyncPort;
    CFRunLoopSourceRef asyncSource;
    CFRunLoopRef ioLoop;
    pthread_t ioThread;
    pthread_mutex_t lock;
    pthread_cond_t cond;
    uint64_t generation;
    uint64_t completedGeneration;
    bool done;
    bool loopReady;
    bool stopLoop;
    IOReturn result;
    UInt32 transferred;
} ShimContext;

static void ioCallback(void *refCon, IOReturn result, void *arg0, void *arg1) {
    ShimContext *ctx = (ShimContext *)refCon;
    (void)arg1;
    pthread_mutex_lock(&ctx->lock);
    if (!ctx->done) {
        ctx->result = result;
        ctx->transferred = (UInt32)(uintptr_t)arg0;
        ctx->completedGeneration = ctx->generation;
        ctx->done = true;
        pthread_cond_signal(&ctx->cond);
    }
    pthread_mutex_unlock(&ctx->lock);
}

static void *ioThreadMain(void *arg) {
    ShimContext *ctx = (ShimContext *)arg;
    ctx->ioLoop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(ctx->ioLoop, ctx->asyncSource, kCFRunLoopDefaultMode);
    pthread_mutex_lock(&ctx->lock);
    ctx->loopReady = true;
    pthread_cond_signal(&ctx->cond);
    pthread_mutex_unlock(&ctx->lock);
    while (!ctx->stopLoop) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.5, true);
    }
    return NULL;
}

static bool startIoThread(ShimContext *ctx) {
    IOReturn kr = (*ctx->intf)->CreateInterfaceAsyncPort(ctx->intf, &ctx->asyncPort);
    if (kr != kIOReturnSuccess) return false;
    kr = (*ctx->intf)->CreateInterfaceAsyncEventSource(ctx->intf, &ctx->asyncSource);
    if (kr != kIOReturnSuccess) return false;
    pthread_mutex_init(&ctx->lock, NULL);
    pthread_cond_init(&ctx->cond, NULL);
    if (pthread_create(&ctx->ioThread, NULL, ioThreadMain, ctx) != 0) return false;
    /* Wait until the run loop is actually serving the source. */
    struct timespec readyDeadline;
    clock_gettime(CLOCK_REALTIME, &readyDeadline);
    readyDeadline.tv_sec += 2;
    pthread_mutex_lock(&ctx->lock);
    while (!ctx->loopReady) {
        if (pthread_cond_timedwait(&ctx->cond, &ctx->lock, &readyDeadline) == ETIMEDOUT) break;
    }
    pthread_mutex_unlock(&ctx->lock);
    return ctx->loopReady;
}

/* Wait for the in-flight async transfer. Timeouts are handled by the family
 * itself (…AsyncTO): the kernel aborts the request and fires the completion
 * with kIOReturnTimeout, so the host never touches the endpoint state here —
 * manually clearing a non-halted pipe would resync the data toggle without
 * the device knowing and silently drop every following packet. */
static int awaitCompletion(ShimContext *ctx, uint32_t timeoutMs, UInt32 *transferred) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeoutMs / 1000;
    deadline.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec += 1;
        deadline.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&ctx->lock);
    int rc = 0;
    while (!ctx->done && rc != ETIMEDOUT) {
        rc = pthread_cond_timedwait(&ctx->cond, &ctx->lock, &deadline);
    }
    bool done = ctx->done;
    IOReturn result = ctx->result;
    *transferred = ctx->transferred;
    pthread_mutex_unlock(&ctx->lock);

    if (!done) {
        /* Completion missed its deadline even once — surface a timeout but
         * leave endpoint state untouched. */
        return kIOReturnTimeout;
    }
    if (result != kIOReturnSuccess) return result;
    return kIOReturnSuccess;
}

static void copyStringProperty(io_registry_entry_t entry, CFStringRef key, char *out, size_t len) {
    out[0] = '\0';
    CFTypeRef v = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key,
        kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (v && CFGetTypeID(v) == CFStringGetTypeID())
        CFStringGetCString((CFStringRef)v, out, (CFIndex)len, kCFStringEncodingUTF8);
    if (v) CFRelease(v);
}

static bool uint8Property(io_registry_entry_t entry, CFStringRef key, uint8_t *out,
                          IOOptionBits options) {
    CFTypeRef v = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key,
        kCFAllocatorDefault, options);
    if (!v) return false;
    bool ok = false;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int32_t n = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &n)) { *out = (uint8_t)n; ok = true; }
    } else if (CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)v) >= 1) {
        *out = CFDataGetBytePtr((CFDataRef)v)[0];
        ok = true;
    }
    CFRelease(v);
    return ok;
}

static bool uint16Property(io_registry_entry_t entry, CFStringRef key, uint16_t *out,
                           IOOptionBits options) {
    CFTypeRef v = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key,
        kCFAllocatorDefault, options);
    if (!v) return false;
    bool ok = false;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) {
        int32_t n = 0;
        if (CFNumberGetValue((CFNumberRef)v, kCFNumberSInt32Type, &n)) { *out = (uint16_t)n; ok = true; }
    } else if (CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength((CFDataRef)v) >= 2) {
        const uint8_t *b = CFDataGetBytePtr((CFDataRef)v);
        *out = (uint16_t)(b[0] | (b[1] << 8));
        ok = true;
    }
    CFRelease(v);
    return ok;
}

/* Standard still-image (PTP/MTP) class code, or Android/HarmonyOS vendor-specific MTP. */
static bool isMTPClassCode(uint8_t cls, uint8_t sub, uint8_t proto) {
    if (cls == 6 && sub == 1 && proto == 1) return true;
    if (cls == 0xFF && sub != 0x42) return true;   /* 0x42 = ADB, never MTP */
    return false;
}

int shimListMTPDevices(ShimMTPDeviceInfo **outList, int *outCount) {
    *outList = NULL;
    *outCount = 0;
    io_iterator_t iterator = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
        IOServiceMatching(kIOUSBInterfaceClassName), &iterator);
    if (kr != KERN_SUCCESS) return (int)kr;

    ShimMTPDeviceInfo *list = NULL;
    int count = 0, capacity = 0;

    io_service_t iface;
    while ((iface = IOIteratorNext(iterator)) != 0) {
        uint8_t cls = 0, sub = 0, proto = 0;
        bool haveClass = uint8Property(iface, CFSTR("bInterfaceClass"), &cls, 0);
        bool haveSub   = uint8Property(iface, CFSTR("bInterfaceSubClass"), &sub, 0);
        bool haveProto = uint8Property(iface, CFSTR("bInterfaceProtocol"), &proto, 0);
        if (haveClass && haveSub && haveProto && isMTPClassCode(cls, sub, proto)) {
            if (count == capacity) {
                capacity = capacity ? capacity * 2 : 8;
                list = (ShimMTPDeviceInfo *)realloc(list, (size_t)capacity * sizeof(ShimMTPDeviceInfo));
            }
            ShimMTPDeviceInfo *info = &list[count];
            memset(info, 0, sizeof(*info));
            IORegistryEntryGetRegistryEntryID(iface, &info->registryEntryID);
            info->interfaceClass = cls;
            info->interfaceSubClass = sub;
            info->interfaceProtocol = proto;
            uint16Property(iface, CFSTR("idVendor"), &info->vendorID,
                           kIORegistryIterateRecursively | kIORegistryIterateParents);
            uint16Property(iface, CFSTR("idProduct"), &info->productID,
                           kIORegistryIterateRecursively | kIORegistryIterateParents);
            copyStringProperty(iface, CFSTR("USB Product Name"), info->productName, sizeof(info->productName));
            copyStringProperty(iface, CFSTR("USB Vendor Name"), info->manufacturer, sizeof(info->manufacturer));
            copyStringProperty(iface, CFSTR("kUSBSerialNumberString"), info->serialNumber, sizeof(info->serialNumber));
            if (info->serialNumber[0] == '\0')
                copyStringProperty(iface, CFSTR("USB Serial Number"), info->serialNumber, sizeof(info->serialNumber));
            count++;
        }
        IOObjectRelease(iface);
    }
    IOObjectRelease(iterator);
    *outList = list;
    *outCount = count;
    return kIOReturnSuccess;
}

void shimFreeList(ShimMTPDeviceInfo *list) { free(list); }

void shimCopyStringField(const ShimMTPDeviceInfo *info, int field, char *out, size_t len) {
    const char *src = field == 0 ? info->productName
                    : field == 1 ? info->manufacturer
                    : info->serialNumber;
    snprintf(out, len, "%s", src);
}

int shimOpenByEntryID(uint64_t entryID, void **outContext, char *errBuf, size_t errLen) {
    *outContext = NULL;
    if (errBuf && errLen > 0) errBuf[0] = '\0';

    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching(kIOUSBInterfaceClassName), &iterator) != KERN_SUCCESS) {
        if (errBuf) snprintf(errBuf, errLen, "IOServiceGetMatchingServices failed");
        return kIOReturnError;
    }
    io_service_t found = 0, s;
    while ((s = IOIteratorNext(iterator)) != 0) {
        uint64_t id = 0;
        IORegistryEntryGetRegistryEntryID(s, &id);
        if (id == entryID) { found = s; break; }
        IOObjectRelease(s);
    }
    IOObjectRelease(iterator);
    if (!found) {
        if (errBuf) snprintf(errBuf, errLen, "USB interface not found (device may have been unplugged)");
        return kIOReturnNotFound;
    }

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(found,
        kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(found);
    if (kr != kIOReturnSuccess || !plug) {
        if (errBuf) snprintf(errBuf, errLen, "IOCreatePlugInInterfaceForService: 0x%08x", kr);
        return kr;
    }
    IOUSBInterfaceInterface300 **intf = NULL;
    kr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (void **)&intf);
    IODestroyPlugInInterface(plug);
    if (kr != kIOReturnSuccess || !intf) {
    kr = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300), (void **)&intf);
        return kr;
    }

    kr = (*intf)->USBInterfaceOpen(intf);
    if (kr != kIOReturnSuccess) {
        if (errBuf) {
            if (kr == kIOReturnExclusiveAccess)
                snprintf(errBuf, errLen, "device busy: another app (e.g. Harmonica/Android File Transfer) owns this device");
            else
                snprintf(errBuf, errLen, "USBInterfaceOpen: 0x%08x", kr);
        }
        (*intf)->Release(intf);
        return kr;
    }

    UInt8 numEndpoints = 0;
    kr = (*intf)->GetNumEndpoints(intf, &numEndpoints);
    if (kr != kIOReturnSuccess || numEndpoints < 2) {
        if (errBuf) snprintf(errBuf, errLen, "no endpoints on interface (not an MTP configuration?)");
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        return kIOReturnUnsupported;
    }

    ShimContext *ctx = (ShimContext *)calloc(1, sizeof(ShimContext));
    ctx->intf = intf;
    for (UInt8 i = 1; i <= numEndpoints; i++) {
        UInt8 direction = 0, number = 0, transferType = 0, interval = 0;
        UInt16 maxPacket = 0;
        kr = (*intf)->GetPipeProperties(intf, i, &direction, &number, &transferType, &maxPacket, &interval);
        if (kr != kIOReturnSuccess) continue;
        if (transferType == kUSBBulk) {
            if (direction == kUSBOut) { ctx->bulkOutPipe = i; ctx->outMaxPacket = maxPacket; }
            else if (direction == kUSBIn) { ctx->bulkInPipe = i; ctx->inMaxPacket = maxPacket; }
        }
    }
    if (ctx->bulkOutPipe == 0 || ctx->bulkInPipe == 0) {
        if (errBuf) snprintf(errBuf, errLen, "interface lacks bulk IN/OUT pair (not MTP)");
        free(ctx);
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        return kIOReturnUnsupported;
    }
    if (!startIoThread(ctx)) {
        if (errBuf) snprintf(errBuf, errLen, "failed to start async IO thread");
        free(ctx);
        (*intf)->USBInterfaceClose(intf);
        (*intf)->Release(intf);
        return kIOReturnError;
    }
    *outContext = ctx;
    return kIOReturnSuccess;
}

int shimGetPipes(void *context, uint8_t *bulkOutPipe, uint16_t *outMaxPacket,
                 uint8_t *bulkInPipe, uint16_t *inMaxPacket) {
    ShimContext *ctx = (ShimContext *)context;
    if (!ctx) return kIOReturnBadArgument;
    *bulkOutPipe = ctx->bulkOutPipe;
    *outMaxPacket = ctx->outMaxPacket;
    *bulkInPipe = ctx->bulkInPipe;
    *inMaxPacket = ctx->inMaxPacket;
    return kIOReturnSuccess;
}

int shimWrite(void *context, const void *buffer, uint32_t *size, uint32_t timeoutMs) {
    ShimContext *ctx = (ShimContext *)context;
    if (!ctx || !ctx->intf || !size) return kIOReturnBadArgument;

    pthread_mutex_lock(&ctx->lock);
    ctx->done = false;
    ctx->generation += 1;
    pthread_mutex_unlock(&ctx->lock);

    /* The TO variants abort cleanly inside the family on timeout. */
    IOReturn kr = (*ctx->intf)->WritePipeAsyncTO(ctx->intf, ctx->bulkOutPipe,
                                                 (void *)buffer, *size,
                                                 timeoutMs, timeoutMs,
                                                 (IOAsyncCallback1)ioCallback, ctx);
    if (kr != kIOReturnSuccess) return kr;

    UInt32 transferred = 0;
    kr = (IOReturn)awaitCompletion(ctx, timeoutMs + 2000, &transferred);
    if (kr != kIOReturnSuccess) return kr;
    *size = transferred;
    return kIOReturnSuccess;
}

int shimRead(void *context, void *buffer, uint32_t *size, uint32_t timeoutMs) {
    ShimContext *ctx = (ShimContext *)context;
    if (!ctx || !ctx->intf || !size) return kIOReturnBadArgument;

    pthread_mutex_lock(&ctx->lock);
    ctx->done = false;
    ctx->generation += 1;
    pthread_mutex_unlock(&ctx->lock);

    UInt32 want = *size;
    IOReturn kr = (*ctx->intf)->ReadPipeAsyncTO(ctx->intf, ctx->bulkInPipe,
                                                buffer, want,
                                                timeoutMs, timeoutMs,
                                                (IOAsyncCallback1)ioCallback, ctx);
    if (kr != kIOReturnSuccess) return kr;

    UInt32 transferred = 0;
    kr = (IOReturn)awaitCompletion(ctx, timeoutMs + 2000, &transferred);
    if (kr != kIOReturnSuccess) return kr;
    *size = transferred;
    return kIOReturnSuccess;
}

int shimClearStall(void *context) {
    ShimContext *ctx = (ShimContext *)context;
    if (!ctx || !ctx->intf) return kIOReturnBadArgument;
    /* BothEnds issues the USB CLEAR_FEATURE control request so the device
     * resets its data toggle too; plain ClearPipeStall only touches the host
     * side and silently desyncs the toggle. */
    (*ctx->intf)->ClearPipeStallBothEnds(ctx->intf, ctx->bulkInPipe);
    (*ctx->intf)->ClearPipeStallBothEnds(ctx->intf, ctx->bulkOutPipe);
    return kIOReturnSuccess;
}

void shimClose(void *context) {
    ShimContext *ctx = (ShimContext *)context;
    if (!ctx) return;
    ctx->stopLoop = true;
    if (ctx->ioThread) {
        pthread_join(ctx->ioThread, NULL);
    }
    if (ctx->intf) {
        (*ctx->intf)->USBInterfaceClose(ctx->intf);
        (*ctx->intf)->Release(ctx->intf);
    }
    if (ctx->asyncSource) CFRelease(ctx->asyncSource);
    if (ctx->asyncPort) mach_port_deallocate(mach_task_self(), ctx->asyncPort);
    pthread_mutex_destroy(&ctx->lock);
    pthread_cond_destroy(&ctx->cond);
    free(ctx);
}
