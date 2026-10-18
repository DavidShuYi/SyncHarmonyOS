//
//  File:    MTPConstants.swift
//  Project: SyncHarmonyOS
//  Author:  David Zhang
//  Version: 1.0.0
//  Date:    2026-10-18
//  License: AGPL-3.0-or-later
//

// MTPConstants.swift — public PTP/MTP protocol constants (ISO 15740, USB SI-1, MTP 1.x).
// Values come from the published specifications.

/// PTP/MTP container types.
public enum ContainerType {
    public static let operationRequest: UInt16 = 0x0001
    public static let data: UInt16 = 0x0002
    public static let response: UInt16 = 0x0003
    public static let event: UInt16 = 0x0004
}

/// Fixed size of a PTP container header (length + type + code + transaction ID).
public let containerHeaderLength = 12

/// PTP standard operation codes used by SyncHarmonyOS.
public enum Operation {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getStorageIDs: UInt16 = 0x1004
    public static let getStorageInfo: UInt16 = 0x1005
    public static let getObjectHandles: UInt16 = 0x1007
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let deleteObject: UInt16 = 0x100B
    public static let sendObjectInfo: UInt16 = 0x100C
    public static let sendObject: UInt16 = 0x100D
    public static let getThumbnail: UInt16 = 0x100A
    // MTP extensions
    public static let getObjectPropValue: UInt16 = 0x9803
}

/// Response codes shared by PTP and MTP, with human-readable names.
public enum ResponseCode {
    public static let ok: UInt16 = 0x2001
    public static let generalError: UInt16 = 0x2002
    public static let sessionNotOpen: UInt16 = 0x2003
    public static let invalidTransactionID: UInt16 = 0x2004
    public static let operationNotSupported: UInt16 = 0x2005
    public static let parameterNotSupported: UInt16 = 0x2006
    public static let incompleteTransfer: UInt16 = 0x2007
    public static let invalidStorageID: UInt16 = 0x2008
    public static let storeFull: UInt16 = 0x2009
    public static let objectWriteProtected: UInt16 = 0x200A
    public static let storeReadOnly: UInt16 = 0x200B
    public static let accessDenied: UInt16 = 0x200C
    public static let noThumbnailInsideObject: UInt16 = 0x200D
    public static let selfTestFailed: UInt16 = 0x200E
    public static let partialDeletion: UInt16 = 0x200F
    public static let storeNotAvailable: UInt16 = 0x2010
    public static let specificationByFormatUnsupported: UInt16 = 0x2011
    public static let noFileInsideObject: UInt16 = 0x2012
    public static let invalidObjectHandle: UInt16 = 0x2013
    public static let invalidParameter: UInt16 = 0x2014
    public static let deviceBusy: UInt16 = 0x2019
    public static let invalidParentObject: UInt16 = 0x201A
    public static let sessionAlreadyOpened: UInt16 = 0x201E
    public static let transactionCanceled: UInt16 = 0x201F
    public static let invalidObjectPropCode: UInt16 = 0xA802

    /// Human-readable name for diagnostics and UI messages.
    public static func name(_ code: UInt16) -> String {
        switch code {
        case ok: return "OK"
        case generalError: return "GeneralError"
        case sessionNotOpen: return "SessionNotOpen"
        case invalidTransactionID: return "InvalidTransactionID"
        case operationNotSupported: return "OperationNotSupported"
        case parameterNotSupported: return "ParameterNotSupported"
        case incompleteTransfer: return "IncompleteTransfer"
        case invalidStorageID: return "InvalidStorageID"
        case storeFull: return "StoreFull (device storage full)"
        case objectWriteProtected: return "ObjectWriteProtected"
        case storeReadOnly: return "StoreReadOnly"
        case accessDenied: return "AccessDenied"
        case noThumbnailInsideObject: return "NoThumbnailInsideObject"
        case selfTestFailed: return "SelfTestFailed"
        case partialDeletion: return "PartialDeletion"
        case storeNotAvailable: return "StoreNotAvailable"
        case specificationByFormatUnsupported: return "SpecificationByFormatUnsupported"
        case noFileInsideObject: return "NoFileInsideObject"
        case invalidObjectHandle: return "InvalidObjectHandle"
        case invalidParameter: return "InvalidParameter"
        case deviceBusy: return "DeviceBusy"
        case invalidParentObject: return "InvalidParentObject"
        case sessionAlreadyOpened: return "SessionAlreadyOpened"
        case transactionCanceled: return "TransactionCanceled"
        case invalidObjectPropCode: return "InvalidObjectPropCode"
        default: return String(format: "0x%04X", code)
        }
    }
}

/// Object format codes used for upload mapping and folder detection.
public enum ObjectFormat {
    public static let undefined: UInt16 = 0x3000
    public static let association: UInt16 = 0x3001
    public static let text: UInt16 = 0x3004
    public static let html: UInt16 = 0x3005
    public static let aiff: UInt16 = 0x300A
    public static let wav: UInt16 = 0x300B
    public static let mp3: UInt16 = 0x300C
    public static let avi: UInt16 = 0x300D
    public static let mpeg: UInt16 = 0x300E
    public static let jpeg: UInt16 = 0x3801
    public static let bmp: UInt16 = 0x3804
    public static let gif: UInt16 = 0x3806
    public static let png: UInt16 = 0x3809
    public static let tiff: UInt16 = 0x380A
    public static let heif: UInt16 = 0x3811
    // MTP extension formats
    public static let m4a: UInt16 = 0xB981
    public static let flac: UInt16 = 0xB906
    public static let ogg: UInt16 = 0xB908
    public static let threeGP: UInt16 = 0xB982
    public static let mp4: UInt16 = 0xB984
    public static let windowsMediaVideo: UInt16 = 0xB986
    public static let pdf: UInt16 = 0xB007
    public static let doc: UInt16 = 0xB101
    public static let zip: UInt16 = 0xB902

    /// Map a file extension to the closest MTP format code. Unknown types
    /// upload fine as `undefined` on HarmonyOS/Android devices.
    public static func forFileExtension(_ ext: String) -> UInt16 {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": return jpeg
        case "png": return png
        case "gif": return gif
        case "bmp": return bmp
        case "tif", "tiff": return tiff
        case "heic", "heif": return heif
        case "mp3": return mp3
        case "m4a": return m4a
        case "wav": return wav
        case "aif", "aiff": return aiff
        case "flac": return flac
        case "ogg", "oga": return ogg
        case "mp4", "m4v": return mp4
        case "3gp", "3g2": return threeGP
        case "avi": return avi
        case "mpg", "mpeg", "mov": return mpeg
        case "wmv": return windowsMediaVideo
        case "pdf": return pdf
        case "doc", "docx": return doc
        case "zip": return zip
        case "txt", "md", "log", "csv": return text
        case "html", "htm": return html
        default: return undefined
        }
    }
}

/// Special object handles defined by the protocol.
public enum Handle {
    /// Parent handle meaning "root of a storage".
    public static let root: UInt32 = 0xFFFFFFFF
    public static let invalid: UInt32 = 0x00000000
}

public extension ObjectFormat {
    /// 是否为可出缩略图的图片格式（预览模式用）。
    static func isImage(_ code: UInt16) -> Bool {
        switch code {
        case jpeg, bmp, gif, png, tiff, heif:
            return true
        default:
            return false
        }
    }

    /// 常见视频格式的对象格式码。
    static func isVideo(_ code: UInt16) -> Bool {
        switch code {
        case avi, mpeg, threeGP, mp4, windowsMediaVideo:
            return true
        default:
            return false
        }
    }
}

/// MTP object property codes (subset used by SyncHarmonyOS).
public enum ObjectProperty {
    /// 64-bit object size (UINT64). Preferred over the 32-bit ObjectInfo field.
    public static let objectSize: UInt16 = 0xDC04
    /// MTP datatype code for UINT64.
    public static let datatypeUINT64: UInt16 = 0x0008
    /// MTP datatype code for UINT32.
    public static let datatypeUINT32: UInt16 = 0x0004
}
