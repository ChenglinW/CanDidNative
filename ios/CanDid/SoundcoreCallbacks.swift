import Foundation
import module_spplinkKit

// Required callbacks match the supplied v1.3.01 binary header. Unused SDK features stay inactive.
final class SoundcoreCallbacks: NSObject, SoundcoreBusinessCallback, OnAuthResultListener, OnReceiveScanResult, SoundcoreConnectionCallback, LogInterface {
    var event: ((SoundcoreEvent) -> Void)?
    func onAuthResult(result: AuthResult) { event?(.auth(result.success, result.error?.code ?? 0)) }
    func onScanError(result: Int32) { event?(.scanError(result)) }
    func onScanSuccess(device: BlueDeviceModel) {
        guard let mac = device.macAddress, !mac.isEmpty else {
            event?(.scanPayloadMissing(device.productCode ?? "", device.macAddress != nil, device.uuid != nil)); return
        }
        // The official iOS Demo routes D3200 commands by service UUID, not peripheral.identifier.
        event?(.scan(SoundcoreDevice(name: device.deviceName ?? "安克录音豆", mac: mac,
            uuid: SoundcoreDevice.serviceUUID, advertisedUUID: device.uuid, productCode: device.productCode ?? "",
            bound: device.bindingStatus == "1", signal: Int(device.rssi?.int32Value ?? -100))))
    }
    func onConnected(macAddress: String?, deviceName: String?) { event?(.connected(macAddress)) }
    func onDisconnected(macAddress: String?, systemCode: KotlinInt?, systemMsg: String?) { event?(.disconnected(macAddress)) }
    func onError(macAddress: String?, exception: SdkException) { event?(.connectionError) }
    // Avoid forwarding SDK logs that can contain identifiers or authentication data.
    func d(tag: String?, message: String?) { }
    func e(tag: String?, message: String?) { }
    func i(tag: String?, message: String?) { }
    func v(tag: String?, message: String?) { }
    func w(tag: String?, message: String?) { }
    func onAudioRecordDuration(macAddress: String, uuid: String, durationMs: Int64) { event?(.duration(macAddress, uuid, durationMs)) }
    func onAudioRecordStatusChanged(macAddress: String, uuid: String, status: Int32, recordingDuration: Int32, fileID: Int32) { event?(.record(macAddress, uuid, status, recordingDuration, fileID)) }
    func onBatteryInfoChanged(macAddress: String, uuid: String, deviceBattery: Int32, chargingBoxBattery: Int32) { event?(.battery(macAddress, uuid, deviceBattery)) }
    func onBindingDeviceError(macAddress: String, uuid: String, errorCode: Int32) { event?(.bindingError(macAddress, uuid, errorCode)) }
    func onCloseSyncFileByWIFI(macAddress: String, uuid: String) {  }
    func onConnectSPPLinkStatusChanged(macAddress: String, uuid: String, isConnect: Bool) {  }
    func onConnectWIFIError(macAddress: String, uuid: String, errorCode: Int32) {  }
    func onConnectWIFIStatusChanged(macAddress: String, uuid: String, status: WifiState) {  }
    func onDecodeFileCompleted(macAddress: String, uuid: String, fileID: Int32, filePath: String) { event?(.completed(macAddress, uuid, fileID, filePath)) }
    func onDecodeFileMarkers(macAddress:String,uuid:String,fileID:Int32,markerTimes:KotlinIntArray) {event?(.markers(macAddress,uuid,fileID,(0..<markerTimes.size).map{Int(markerTimes.get(index:$0))}))}
    func onDeleteFileResult(macAddress: String, uuid: String, fileID: Int32, isSuccess: Bool) {  }
    func onDeviceBindConfirm(macAddress: String, uuid: String) { event?(.bindingConfirmed(macAddress, uuid)) }
    func onDeviceChargingStatusChanged(macAddress: String, uuid: String, deviceChargingStatus: Int32, chargingBoxChargingStatus: Int32) {  }
    func onDeviceLogDeleteResult(macAddress: String, uuid: String, success: Bool) {  }
    func onDeviceLogDumping(macAddress: String, uuid: String, success: Bool, packetSequence: Int32, fileTimestamp: Int32, transferStatus: Int32, progress: Int32, fragmentData: KotlinByteArray) {  }
    func onDeviceLogEnableCollectionResult(macAddress: String, uuid: String, success: Bool) {  }
    func onDeviceLogRequestListResult(macAddress: String, uuid: String, success: Bool, fileCount: Int32, fileList: [DeviceLogFileInfo], logCollectionStatus: Bool) {  }
    func onDeviceLogTransferResult(macAddress: String, uuid: String, success: Bool, code: Int32) {  }
    func onDeviceTransferStateChanged(macAddress: String, uuid: String, state: DeviceTransferState) {  }
    func onFindMyEnableResult(macAddress: String, uuid: String, success: Bool) {  }
    func onGetDeviceInfo(macAddress: String, uuid: String, info: DeviceInfo) { event?(.info(macAddress, uuid, info.recording?.int32Value ?? 0, info.recodingOriginalTime, info.serialNumber, info.firmwareVersion, info.deviceBattery)) }
    func onGetDeviceInfoError(macAddress: String, uuid: String, errorCode: Int32) { event?(.infoError(macAddress, uuid)) }
    func onOtaError(macAddress: String, uuid: String, errorCode: Int32) {  }
    func onRealtimeTransferSwitch(macAddress: String, uuid: String, fileID: Int32, filePath: String?) { event?(.realtimeReady(macAddress,uuid,fileID)) }
    func onReceiveAudioFragment(macAddress: String, uuid: String, fileID: Int32, audioData: KotlinByteArray, isAppendPreAudio: Bool, sequenceNumber: Int32, isMark: Bool) {
        let bytes=(0..<audioData.size).map { UInt8(bitPattern:audioData.get(index:$0)) }
        event?(.liveAudio(macAddress,uuid,fileID,Data(bytes),sequenceNumber))
        if isMark {event?(.markedFragment(macAddress,uuid,fileID,sequenceNumber,isAppendPreAudio))}
    }
    func onReceiveOfflineFile(macAddress: String, uuid: String, offlineFileData: OfflineFileData, isAllAudioFiles: Bool) { event?(.files(macAddress, uuid, offlineFileData.fileInfoList)) }
    func onReceiveOfflineFileError(macAddress: String, uuid: String, errorCode: Int32) { event?(.fileError(macAddress, uuid, errorCode)) }
    func onReceiveWaitingDeviceOpenWIFI(macAddress: String, uuid: String) {  }
    func onResetDeviceResult(macAddress: String, uuid: String, result: Bool) {  }
    func onSendBindingDeviceCMDSuccess(macAddress: String, uuid: String) { event?(.bindingSent(macAddress, uuid)) }
    func onSendUnbindingDeviceCMDSuccess(macAddress: String, uuid: String) {  }
    func onSyncTimeResult(macAddress: String, uuid: String, result: Bool) { event?(.synced(macAddress, uuid, result)) }
    func onTransferFileError(macAddress: String, uuid: String, fileID: Int32, errorType: FileTransferError) { event?(.transferError(macAddress, uuid, fileID)) }
    func onTransferFileProgress(macAddress: String, uuid: String, fileID: Int32, total: Int32, current: Int32, sequenceNumber: Int32, isMark: Bool) { event?(.progress(macAddress, uuid, fileID, total, current));if isMark {event?(.markedFragment(macAddress,uuid,fileID,sequenceNumber,true))} }
    func onTransferFileStatusChanged(macAddress:String,uuid:String,fileID:Int32,status:Int32,markTimeStampList:NSMutableArray) {event?(.markers(macAddress,uuid,fileID,markTimeStampList.compactMap{($0 as? NSNumber)?.intValue}))}
    func onTransferFileSupplementProgress(macAddress: String, uuid: String, fileID: Int32, total: Int32, current: Int32) {  }
    func onTransferFileTransmitting(macAddress: String, uuid: String, fileID: Int32) {  }
    func onWifiScanned(macAddress: String, uuid: String) {  }
}
