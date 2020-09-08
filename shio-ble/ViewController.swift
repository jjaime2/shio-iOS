//
//  ViewController.swift
//  shio-ble
//
//  Created by Jose Jaime on 8/1/20.
//  Copyright © 2020 UW-X. All rights reserved.
//

import UIKit
import CoreBluetooth
import CoreML
import Foundation

let shioServiceCBUUID = CBUUID(string: "47ea1400-a0e4-554e-5282-0afcd3246970")
let micDataCharacteristicCBUUID = CBUUID(string: "47ea1402-a0e4-554e-5282-0afcd3246970")
let tsmDataCharacteristicCBUUID = CBUUID(string: "47ea1403-a0e4-554e-5282-0afcd3246970")
let dfDataCharacteristicCBUUID = CBUUID(string: "47ea1404-a0e4-554e-5282-0afcd3246970")

let master_value: UInt8 = 0x6D
let slave_value: UInt8 = 0x73
let master_data = Data(_: [master_value])
let slave_data = Data(_: [slave_value])

extension String {
   func appendLineToURL(fileURL: URL) throws {
        try (self + "\n").appendToURL(fileURL: fileURL)
    }

    func appendToURL(fileURL: URL) throws {
        let data = self.data(using: String.Encoding.utf8)!
        try data.append(fileURL: fileURL)
    }
}

extension Data {
    func append(fileURL: URL) throws {
        if let fileHandle = FileHandle(forWritingAtPath: fileURL.path) {
            defer {
                fileHandle.closeFile()
            }
            fileHandle.seekToEndOfFile()
            fileHandle.write(self)
        }
        else {
            try write(to: fileURL, options: .atomic)
        }
    }
}

class ViewController: UIViewController, CBCentralManagerDelegate, CBPeripheralDelegate, UIPickerViewDelegate, UIPickerViewDataSource {
    @IBOutlet weak var channelPicker: UIPickerView!
    
    var centralManager:     CBCentralManager!
    var myDevices:          [myDevice]          = []
    var myService:          CBService!
    var model:              ClearVoice1pt5!
//    var micMLMultiArray:    MLMultiArray        = try! MLMultiArray(shape:[1, 2, 18000], dataType:MLMultiArrayDataType.int32)
    var appstate:           AppState            = .idle
    var bufferstates:       [BufferState]       = [.empty, .empty]
    var packetCount:        UInt32              = 0
    var curr_sample:        [Int]               = [0, 0]
    var logFileURLs:        [URL]               = []
    var mlFileURL:          URL!
    var desiredChannels:    Int                 = 2
    var channelPickerData:  [String]            = [String]()
    var channel:            Int!
    
    open class myDevice : NSObject {
        open var channel:            Int
        open var peripheral:         CBPeripheral
        open var uuid:               UUID
        open var characteristics:    [CBCharacteristic]?

        init(channel: Int, peripheral: CBPeripheral, uuid: UUID, characteristics: [CBCharacteristic]? = []) {
            self.channel = channel
            self.peripheral = peripheral
            self.uuid = uuid
            self.characteristics = characteristics
        }
    }
    
    enum AppState {
        case idle
        case logging
        case predicting
    }
    
    enum BufferState {
        case empty
        case filling
        case full
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if (central.state == CBManagerState.poweredOn) {
            print("shio-ble powered on")
            // Turned on
        } else {
            print("shio-ble did not power on, something went wrong")
            guard centralManager.isScanning else { return }
            centralManager.stopScan()
            // Not turned on
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if !self.myDevices.contains(where: {$0.uuid == peripheral.identifier}) {
            let curr_peripheral = myDevice(channel: self.myDevices.endIndex + 1, peripheral: peripheral, uuid: peripheral.identifier)
            self.myDevices.append(curr_peripheral)
            self.myDevices.last!.peripheral.delegate = self
            print("discovered " + self.myDevices.last!.peripheral.name! + " no. " + String(self.myDevices.last!.channel))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let curr_shio_idx = self.myDevices.firstIndex(where: { $0.uuid == peripheral.identifier }) else { return }
        let curr_shio_no = self.myDevices[curr_shio_idx].channel
        peripheral.discoverServices([shioServiceCBUUID])
        print("connected to shio no. " + String(curr_shio_no))
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let curr_shio_idx = self.myDevices.firstIndex(where: { $0.uuid == peripheral.identifier }) else { return }
        let curr_shio_no = self.myDevices[curr_shio_idx].channel
        print("disconnected from shio no. " + String(curr_shio_no))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {return}
        
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else {return}
        guard let curr_shio_idx = self.myDevices.firstIndex(where: { $0.uuid == peripheral.identifier }) else { return }
        let curr_shio_no = self.myDevices[curr_shio_idx].channel
        
        for characteristic in characteristics {
            if characteristic.properties.contains(.read) {
                print("shio no. " + String(curr_shio_no) + " contains read characteristic")
            }
            
            if characteristic.properties.contains(.write) {
                print("shio no. " + String(curr_shio_no) + " contains write characteristic")
            }
            
            if characteristic.properties.contains(.writeWithoutResponse) {
                print("shio no. " + String(curr_shio_no) + " contains write w/o response characteristic")
            }
            
            if characteristic.properties.contains(.notify) {
                print("shio no. " + String(curr_shio_no) + " contains notify characteristic")
            }
            
            if (!(self.myDevices[curr_shio_idx].characteristics!.contains(characteristic))) {
                self.myDevices[curr_shio_idx].characteristics!.append(characteristic)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let curr_shio_idx = self.myDevices.firstIndex(where: { $0.uuid == peripheral.identifier }) else { return }
        let curr_shio_no = self.myDevices[curr_shio_idx].channel
        
        guard let micMLMultiArray = try? MLMultiArray(shape:[1, 2, 18000], dataType:MLMultiArrayDataType.int32) else {
            fatalError("Unexpected runtime error. MLMultiArray")
        }
        
        switch characteristic.uuid {
        case micDataCharacteristicCBUUID:
            let micData = ([UInt8](characteristic.value!))
            
            switch appstate {
            case .idle:
                break
                
            case .logging:
                for i in stride(from: 0, to: micData.count - 1, by: 2) {
                    let result = String(Int16((Int16(micData[i+1]) << 8) + Int16(micData[i])))
                    
                    do {
                        try result.appendLineToURL(fileURL: logFileURLs[curr_shio_no - 1] as URL)
                    }
                    catch { }
                }
                packetCount+=1
                print("received packet from shio no. " + String(curr_shio_no) + ": " + String(packetCount))
                
            case .predicting:
                for i in stride(from: 0, to: micData.count - 1, by: 2) {
                    autoreleasepool {
                        let result = Int16((Int16(micData[i+1]) << 8) + Int16(micData[i]))

                        if (curr_sample[curr_shio_idx] < ((micMLMultiArray.count / 2) - 1) && bufferstates[curr_shio_idx] != .full) {
                            micMLMultiArray[[0, curr_shio_idx, curr_sample[curr_shio_idx]] as [NSNumber]] = NSNumber(value: result)
                            curr_sample[curr_shio_idx] += 1
                            bufferstates[curr_shio_idx] = .filling
                        } else {
                            bufferstates[curr_shio_idx] = .full
                        }
                    }
                }
                
                if (bufferstates.allSatisfy {$0 == .full}) {
                    print("all machine learning buffers filled")
                    print("running machine learning model")
                    
                    let input = ClearVoice1pt5Input(input_name: micMLMultiArray)

                    model = ClearVoice1pt5()

                    // Actual forward pass
                    guard let predictionOutput = try? model.prediction(input: input) else {
                            fatalError("Unexpected runtime error. model.prediction")
                    }

                    // Output MLMultiArray
                    let output = predictionOutput._4209

                    // Convert to array of int32s
                    if let int32Buffer = try? UnsafeBufferPointer<Int32>(output) {
                        let micMLData = Array(int32Buffer)

                        for i in stride(from: 0, to: micMLData.count - 1, by: 1) {
                            autoreleasepool {
                                let result = String(micMLData[i])
                                do {
                                    try result.appendLineToURL(fileURL: mlFileURL as URL)
                                }
                                catch { }
                            }
                        }
                    }

                    print("machine learning result output to shio_ml_output.txt")

                    for buffer in 0..<(Int(truncating: micMLMultiArray.shape[1])) {
                        autoreleasepool {
                            curr_sample[buffer] = 0
                            bufferstates[buffer] = .empty
                        }
                    }
                    
                    // Remove when mem leak fixed
                    appstate = .idle
                }
            }
            
        default:
            print("unhandled characteristic uuid: \(characteristic.uuid)")
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        packetCount = 0;
        channelPicker.isHidden = false;
        channelPickerData = [];
        self.channelPicker.delegate = self
        self.channelPicker.dataSource = self
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return channelPickerData.count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return channelPickerData[row]
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        channel = row + 1
    }
    
    @IBAction func scanButton(_ sender: UIButton) {
        self.centralManager.scanForPeripherals(withServices: [shioServiceCBUUID], options: nil)
    }
    
    @IBAction func connectButton(_ sender: UIButton) {
        for device in self.myDevices {
            self.centralManager.connect(device.peripheral, options: nil)
        }
        self.centralManager.stopScan()
    }
    
    @IBAction func disconnectButton(_ sender: UIButton) {
        for device in self.myDevices {
            self.centralManager.cancelPeripheralConnection(device.peripheral)
        }
    }
    
    @IBAction func streamButton(_ sender: UIButton) {
        for device in self.myDevices {
            for characteristic in device.characteristics! {
                if (characteristic.uuid == micDataCharacteristicCBUUID) {
                    device.peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
        print("enabled notifications for mic streams")
    }
    
    @IBAction func stopStreamButton(_ sender: UIButton) {
        for device in self.myDevices {
            for characteristic in device.characteristics! {
                device.peripheral.setNotifyValue(false, for: characteristic)
            }
        }
        print("disabled notifications for mic streams")
    }
    
    @IBAction func recordButton(_ sender: UIButton) {
        let shio_no_size = (self.myDevices).count
        
        for shio_no in 1..<(shio_no_size+1) {
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let path = dir.appendingPathComponent("shio_log_ch" + String(shio_no) + ".txt")
                if (!logFileURLs.contains(path)) {
                    logFileURLs.append(path)
                }
                
                do {
                    try FileManager.default.removeItem(at: logFileURLs[shio_no - 1])
                } catch let error as NSError {
                    print("Error: \(error.domain)")
                    print("fileURL does not exist, creating...")
                }
                print("created shio_log_ch" + String(shio_no) + ".txt")
            }
        }
        
        appstate = .logging
        print("start logging")
    }
    
    @IBAction func stopRecordButton(_ sender: UIButton) {
        if (appstate == .logging) {
            appstate = .idle
        }
        print("stop logging")
    }
    
    @IBAction func predictButton(_ sender: UIButton) {
        appstate = .predicting
        
        for buffer in 0..<desiredChannels {
            autoreleasepool {
                curr_sample[buffer] = 0
                bufferstates[buffer] = .empty
            }
        }
        
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let path = dir.appendingPathComponent("shio_ml_output.txt")
            mlFileURL = path
            do {
                try FileManager.default.removeItem(at: mlFileURL)
            } catch let error as NSError {
                print("Error: \(error.domain)")
                print("fileURL does not exist, creating...")
            }
            print("created shio_ml_output.txt")
        }
        
        print("start predicting")
    }
    
    @IBAction func stopPredictButton(_ sender: UIButton) {
        if (appstate == .predicting) {
            appstate = .idle
        }
        print("stop predicting")
    }
    
    @IBAction func makeMasterButton(_ sender: UIButton) {
        for device in self.myDevices {
            guard let write_char_idx = device.characteristics!.firstIndex(where: { $0.uuid == tsmDataCharacteristicCBUUID }) else { return }
            if (channel == device.channel) {
                device.peripheral.writeValue(master_data, for: device.characteristics![write_char_idx], type: .withoutResponse)
            } else {
                device.peripheral.writeValue(slave_data, for: device.characteristics![write_char_idx], type: .withoutResponse)
            }
        }
    }
    
    @IBAction func refreshChannelsButton(_ sender: UIButton) {
        channelPickerData = [];
        for channel in 1..<self.myDevices.count+1 {
            channelPickerData.append(String(channel))
        }
        channelPicker.reloadAllComponents()
    }
}
