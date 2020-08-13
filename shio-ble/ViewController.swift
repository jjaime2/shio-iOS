//
//  ViewController.swift
//  shio-ble
//
//  Created by Jose Jaime on 8/1/20.
//  Copyright © 2020 UW-X. All rights reserved.
//

import UIKit
import CoreBluetooth

let shioServiceCBUUID = CBUUID(string: "47ea1400-a0e4-554e-5282-0afcd3246970")
let micDataCharacteristicCBUUID = CBUUID(string: "47ea1402-a0e4-554e-5282-0afcd3246970")
var recording = false
var fileURLs:[URL] = []

extension StringProtocol {
    var hexa: [UInt8] {
        var startIndex = self.startIndex
        return (0..<count/2).compactMap { _ in
            let endIndex = index(after: startIndex)
            defer { startIndex = index(after: endIndex) }
            return UInt8(self[startIndex...endIndex], radix: 16)
        }
    }
}

extension Sequence where Element == UInt8 {
    var data: Data { .init(self) }
    var hexa: String { map { .init(format: "%02x ", $0) }.joined() }
}

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

class ViewController: UIViewController, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    var centralManager: CBCentralManager!
    var myPeripheral: CBPeripheral!
    var myPeripherals:[CBPeripheral] = []
    var myPeripheralUUIDs:[UUID] = []
    var myService: CBService!
    var packetCount: UInt32 = 0
    var curr_shio_no: Int!
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if (central.state == CBManagerState.poweredOn) {
            print("shio-ble powered on")
            // Turned on
        } else {
            print("shio-ble did not power on, something went wrong")
            guard centralManager.isScanning else {
                return
            }
            centralManager.stopScan()
            // Not turned on
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if (!self.myPeripheralUUIDs.contains(peripheral.identifier)) {
            self.myPeripheralUUIDs.append(peripheral.identifier)
            self.myPeripherals.append(peripheral)
            self.myPeripherals.last!.delegate = self
            print("discovered " + self.myPeripherals.last!.name! + " no. " + String(self.myPeripherals.endIndex))
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        curr_shio_no = self.myPeripherals.firstIndex(of: peripheral)! + 1
        peripheral.discoverServices([shioServiceCBUUID])
        print("connected to shio no. " + String(curr_shio_no))
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        curr_shio_no = self.myPeripherals.firstIndex(of: peripheral)! + 1
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
        curr_shio_no = self.myPeripherals.firstIndex(of: peripheral)! + 1
        
        for characteristic in characteristics {
            if characteristic.properties.contains(.read) {
                print("shio no. " + String(curr_shio_no) + " contains read characteristic")
                /* Do something */
            }
            
            if characteristic.properties.contains(.notify) {
                print("shio no. " + String(curr_shio_no) + " contains notify characteristic")
                peripheral.setNotifyValue(true, for: characteristic)
                print("set notifications for mic stream no. " + String(curr_shio_no))
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        curr_shio_no = self.myPeripherals.firstIndex(of: peripheral)! + 1
        
        switch characteristic.uuid {
        case micDataCharacteristicCBUUID:
            if (recording) {
                let micData = ([UInt8](characteristic.value!))
                
                for i in stride(from: 0, to: micData.count - 1, by: 2) {
                    let result = String(Int16((Int16(micData[i+1]) << 8) + Int16(micData[i])))
                    //writing
                    do {
                        try result.appendLineToURL(fileURL: fileURLs[curr_shio_no - 1] as URL)
                    }
                    catch {/* error handling here */}
                }
//                packetCount+=1
//                print("received packet from shio no. " + String(curr_shio_no) + ": " + String(packetCount))
            }
            
        default:
            print("unhandled characteristic uuid: \(characteristic.uuid)")
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        packetCount = 0;
    }
    
    @IBAction func scanButton(_ sender: UIButton) {
        self.centralManager.scanForPeripherals(withServices: [shioServiceCBUUID], options: nil)
    }
    
    @IBAction func connectButton(_ sender: UIButton) {
        for peripheral in self.myPeripherals {
            self.centralManager.connect(peripheral, options: nil)
        }
        self.centralManager.stopScan()
    }
    
    @IBAction func disconnectButton(_ sender: UIButton) {
        for peripheral in self.myPeripherals {
            self.centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    @IBAction func recordButton(_ sender: UIButton) {
        let shio_no_size = (self.myPeripherals).count
        
        for shio_no in 1..<(shio_no_size+1) {
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let path = dir.appendingPathComponent("shio_log_ch" + String(shio_no) + ".txt")
                if (!fileURLs.contains(path)) {
                    fileURLs.append(path)
                }
                
                do {
                    try FileManager.default.removeItem(at: fileURLs[shio_no - 1])
                } catch let error as NSError {
                    print("Error: \(error.domain)")
                    print("fileURL does not exist, creating...")
                }
                print("created shio_log_ch" + String(shio_no) + ".txt")
            }
        }
        
        recording = true
        print("start recording")
    }
    
    @IBAction func stopRecordButton(_ sender: UIButton) {
        recording = false
        print("stop recording")
    }
}
