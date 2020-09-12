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

// MARK: Definitions
let shioServiceCBUUID = CBUUID(string: "47ea1400-a0e4-554e-5282-0afcd3246970")
let micDataCharacteristicCBUUID = CBUUID(string: "47ea1402-a0e4-554e-5282-0afcd3246970")
let tsmDataCharacteristicCBUUID = CBUUID(string: "47ea1403-a0e4-554e-5282-0afcd3246970")
let dfDataCharacteristicCBUUID = CBUUID(string: "47ea1404-a0e4-554e-5282-0afcd3246970")

let masterValue: UInt8 = 0x6D
let slaveValue: UInt8 = 0x73
let masterData = Data(_: [masterValue])
let slaveData = Data(_: [slaveValue])

let maxDataPoints = 400         /// Max samples on plotter view
let maxBufferCount = 200        /// Samples to update plotter
let masterIdentifier = "master-graph" as (NSCoding & NSCopying & NSObjectProtocol)

let desiredChannels = 2         /// Do not change unless ML model matches

// MARK: UI View Controller
/// Main View Controller Class
///
/// - Type: UIViewController
class ViewController: UIViewController {
    
    @IBOutlet weak var channelPicker: UIPickerView!
    @IBOutlet weak var masterPlotView: CPTGraphHostingView!
    @IBOutlet weak var slavePlotView: CPTGraphHostingView!
    
    var centralManager:     CBCentralManager!                                           /// Central BLE Manager
    var myDevices:          [myDevice]          = []                                    /// Shio Devices
    var myService:          CBService!                                                  /// BLE Service
    var model:              ClearVoice1pt5!                                             /// ML Model instance
    var appState:           AppState            = .idle                                 /// Current app state
    var packetCount:        UInt32              = 0                                     /// Current received packet count (debug only)
    
    var logFileURLs:        [URL]               = []                                    /// File URLs for logging app state
    var mlFileURL:          URL!                                                        /// File URL for ML prediction app state
    
    var channelPickerData:  [String]            = [String]()                            /// Data for channel picker (ie: shio channel 1, 2, ...)
    var channel:            Int!                                                        /// Current selected shio channel from picker
    var masterChannel:      Int!                                                        /// Current master shio channel
    
    var masterPlotBufferIndex: Int! = 0
    var masterPlotBuffer = [Int16](repeating: 0, count: maxBufferCount)                 /// Filler buffer for master plotter
    var masterPlotData = [Int16](repeating: 0, count: maxDataPoints)                    /// Data for master plotter
    var masterPlot: CPTScatterPlot!                                                     /// Scatter plot master instance
    var masterPlotIndex: Int!                                                           /// Current master plot buffer index
    var slavePlotBufferIndex: Int! = 0
    var slavePlotBuffer = [Int16](repeating: 0, count: maxBufferCount)                  /// Filler buffer for slave plotter
    var slavePlotData = [Int16](repeating: 0, count: maxDataPoints)                     /// Data for slave plotter
    var slavePlot: CPTScatterPlot!                                                      /// Scatter plot slave instance
    var slavePlotIndex: Int!                                                            /// Current slave plot buffer index
    
    var mlBufferStates = [BufferState](repeating: .empty, count: desiredChannels)       /// States of ML buffers
    var mlCurrSamples = [Int](repeating: 0, count: desiredChannels)                     /// Counters for ML buffers
    
    /// Shio Device Class
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
    
    /// App state
    enum AppState {
        case idle
        case logging
        case predicting
        case plotting
    }
    
    /// Buffer state
    enum BufferState {
        case empty
        case filling
        case full
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        packetCount = 0;
        channelPicker.isHidden = false;
        channelPickerData = [];
        self.channelPicker.delegate = self
        self.channelPicker.dataSource = self
        
        initPlot()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        /// Dispose of any resources that can be recreated.
    }
}

// MARK: CoreBluetooth Delegate
extension ViewController: CBCentralManagerDelegate, CBPeripheralDelegate {
    
    /// Event handler when central manager updates states
    /// - Function: Alerts user if manager initializes properly
    /// - Parameter: CBCentralManager
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
    
    /// Event handler when central manager discovers a peripheral device
    /// - Function: If not yet discovered, adds peripheral device to list of devices
    /// - Parameter: CBCentralManager central, CBPeripheral peripheral, [String] advertisementData, NSNumber RSSI
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if !self.myDevices.contains(where: {$0.uuid == peripheral.identifier}) {
            let curr_peripheral = myDevice(channel: self.myDevices.endIndex + 1, peripheral: peripheral, uuid: peripheral.identifier)
            self.myDevices.append(curr_peripheral)
            self.myDevices.last!.peripheral.delegate = self
            print("discovered \(self.myDevices.last!.peripheral.name!) no. \(self.myDevices.last!.channel)")
        }
    }
    
    /// Event handler when central manager connects to a peripheral device
    /// - Function: Upon connecting, discovers services provided by connected device
    /// - Parameter: CBCentralManager central, CBPeripheral peripheral
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let currShioIndex = self.myDevices.firstIndex(where: { $0.uuid == peripheral.identifier }) else { return }
        let currShioNo = self.myDevices[currShioIndex].channel
        peripheral.discoverServices([shioServiceCBUUID])
        print("connected to shio no. \(currShioNo)")
    }
    
    /// Event handler when central manager disconnects from a peripheral device
    /// - Parameter: CBCentralManager central, CBPeripheral peripheral
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let currShioIndex = self.myDevices.firstIndex(where: { $0.uuid == peripheral.identifier }) else { return }
        let currShioNo = self.myDevices[currShioIndex].channel
        print("disconnected from shio no. \(currShioNo)")
    }
    
    /// Event handler when central manager discovers services for a peripheral device
    /// - Function: Upon discovering services, begins discovering unique characteristics provided by the service
    /// - Parameter: CBPeripheral peripheral
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {return}
        
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    /// Event handler when central manager discovers characteristics for a service
    /// - Function: Upon discovering characteristics, and if not yet discovered, adds characteristic to device's list of characteristics
    /// - Parameter: CBPeripheral peripheral, CBService service
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else {return}
        guard let currShioIndex = self.myDevices.firstIndex(where: { $0.uuid == peripheral.identifier }) else { return }
        let currShioNo = self.myDevices[currShioIndex].channel
        
        for characteristic in characteristics {
            if characteristic.properties.contains(.read) {
                print("shio no. \(currShioNo) contains read characteristic")
            }
            
            if characteristic.properties.contains(.write) {
                print("shio no. \(currShioNo) contains write characteristic")
            }
            
            if characteristic.properties.contains(.writeWithoutResponse) {
                print("shio no. \(currShioNo) contains write w/o response characteristic")
            }
            
            if characteristic.properties.contains(.notify) {
                print("shio no. \(currShioNo) contains notify characteristic")
            }
            
            if (!(self.myDevices[currShioIndex].characteristics!.contains(characteristic))) {
                self.myDevices[currShioIndex].characteristics!.append(characteristic)
            }
        }
    }
    
    /// Event handler when characteristic updates value
    /// - Function: Upon receiving a characteristic update, handles data according to characteristic UUID and current app state
    /// - Parameter: CBPeripheral peripheral, CBCharacteristic characteristic
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let currShioIndex = self.myDevices.firstIndex(where: { $0.uuid == peripheral.identifier }) else { return }
        let currShioNo = self.myDevices[currShioIndex].channel
        
        switch characteristic.uuid {
        case micDataCharacteristicCBUUID:
            let micData = ([UInt8](characteristic.value!))
            
            switch appState {
                // MARK: Idle State Handler
                case .idle:
                    break
                    
                // MARK: Plotting State Handler
                case .plotting:
                    for i in stride(from: 0, to: micData.count - 1, by: 2) {
                        let result = Int16((Int16(micData[i+1]) << 8) + Int16(micData[i]))
                        
                        if (currShioNo == masterChannel) {
                            if (masterPlotBufferIndex < maxBufferCount) {
                                masterPlotBuffer[masterPlotBufferIndex] = result
                                masterPlotBufferIndex += 1
                            } else {
                                masterPlotBufferIndex = 0
                                onPDMDataReceived(data: masterPlotBuffer, isMaster: true)
                            }
                        } else {
                            if (slavePlotBufferIndex < maxBufferCount) {
                                slavePlotBuffer[slavePlotBufferIndex] = result
                                slavePlotBufferIndex += 1
                            } else {
                                slavePlotBufferIndex = 0
                                onPDMDataReceived(data: slavePlotBuffer, isMaster: false)
                            }
                        }
                    }
                    
                    break
                    
                // MARK: Logging State Handler
                // TODO: Reduce CPU usage by appending to URL less frequently (fill buffer of n packets first)
                case .logging:
                    for i in stride(from: 0, to: micData.count - 1, by: 2) {
                        let result = String(Int16((Int16(micData[i+1]) << 8) + Int16(micData[i])))
                        
                        do {
                            try result.appendLineToURL(fileURL: logFileURLs[currShioNo - 1] as URL)
                        }
                        catch { }
                    }
                    packetCount+=1
                    print("received packet from shio no. \(currShioNo): \(packetCount)")
                    break
                    
                // MARK: Predicting State Handler
                // TODO: Solve memory leak issue having to do with micMLMultiArray when streaming data to ml model
                case .predicting:
                    guard let micMLMultiArray = try? MLMultiArray(shape:[1, 2, 18000], dataType:MLMultiArrayDataType.int32) else {
                        fatalError("Unexpected runtime error. MLMultiArray")
                    }
                    
                    for i in stride(from: 0, to: micData.count - 1, by: 2) {
                        autoreleasepool {
                            let result = Int16((Int16(micData[i+1]) << 8) + Int16(micData[i]))

                            if (mlCurrSamples[currShioIndex] < ((micMLMultiArray.count / 2) - 1) && mlBufferStates[currShioIndex] != .full) {
                                micMLMultiArray[[0, currShioIndex, mlCurrSamples[currShioIndex]] as [NSNumber]] = NSNumber(value: result)
                                mlCurrSamples[currShioIndex] += 1
                                mlBufferStates[currShioIndex] = .filling
                            } else {
                                mlBufferStates[currShioIndex] = .full
                            }
                        }
                    }
                    
                    if (mlBufferStates.allSatisfy {$0 == .full}) {
                        print("all machine learning buffers filled")
                        print("running machine learning model")
                        
                        let input = ClearVoice1pt5Input(input_name: micMLMultiArray)

                        model = ClearVoice1pt5()

                        /// Actual forward pass
                        guard let predictionOutput = try? model.prediction(input: input) else {
                                fatalError("Unexpected runtime error. model.prediction")
                        }

                        /// Output MLMultiArray
                        let output = predictionOutput._4209

                        /// Convert to array of int32s
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
                                mlCurrSamples[buffer] = 0
                                mlBufferStates[buffer] = .empty
                            }
                        }
                        
                        // TODO: Remove when memory leak is fixed, should remain in .predicting state until indicated by user otherwise
                        appState = .idle
                    }
                    break
            }
            break
            
        default:
            print("unhandled characteristic uuid: \(characteristic.uuid)")
        }
    }
}

// MARK: UI Picker View Delegate
extension ViewController: UIPickerViewDelegate, UIPickerViewDataSource {
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
}

// MARK: Core Plot Delegate
// TODO: Add second plot view for slave device
extension ViewController: CPTScatterPlotDelegate, CPTScatterPlotDataSource {
    
    func numberOfRecords(for plot: CPTPlot) -> UInt {
        guard let identifier = plot.identifier else { return 0 }
        
        if (identifier.isEqual(masterIdentifier)) {
            return UInt(self.masterPlotData.count)
        } else {
            return UInt(self.slavePlotData.count)
        }
    }

    func scatterPlot(_ plot: CPTScatterPlot, plotSymbolWasSelectedAtRecord idx: UInt, with event: UIEvent) {
    }

    func number(for plot: CPTPlot, field: UInt, record: UInt) -> Any? {
        guard let identifier = plot.identifier else { return 0 }
        
        switch CPTScatterPlotField(rawValue: Int(field))! {
            case .X:
                if (identifier.isEqual(masterIdentifier)) {
                    return NSNumber(value: Int(record) + self.masterPlotIndex-self.masterPlotData.count)
                } else {
                    return NSNumber(value: Int(record) + self.slavePlotIndex-self.slavePlotData.count)
                }

            case .Y:
                if (identifier.isEqual(masterIdentifier)) {
                    return self.masterPlotData[Int(record)] as NSNumber
                } else {
                    return self.slavePlotData[Int(record)] as NSNumber
                }
            
            default:
                return 0
        }
    }
    
    func initPlot() {
        configureGraphView()
        configureGraphAxis()
        configurePlot()
    }
    
    func onPDMDataReceived(data: [Int16], isMaster: Bool)
    {
        // TODO: Replace if/else? Identify master/slave plots differently
        if (isMaster) {
            guard let masterGraph = self.masterPlotView.hostedGraph else { return }
            guard let masterPlotSpace = masterGraph.defaultPlotSpace as? CPTXYPlotSpace else { return }

            let masterPlot = masterGraph.plot(withIdentifier: "master-graph" as NSCopying)
            if ((masterPlot) != nil) {
                if (self.masterPlotData.count >= maxDataPoints) {
                    self.masterPlotData.removeFirst(_: data.count)
                    masterPlot?.deleteData(inIndexRange:NSRange(location: 0, length: data.count))
                }
            }

            let location: NSInteger
            if (self.masterPlotIndex >= maxDataPoints) {
                location = self.masterPlotIndex - maxDataPoints + 2
            } else {
                location = 0
            }

            let range: NSInteger
            if (location > 0) {
                range = location - data.count
            } else {
                range = 0
            }

            let oldRange =  CPTPlotRange(locationDecimal: CPTDecimalFromDouble(Double(range)), lengthDecimal: CPTDecimalFromDouble(Double(maxDataPoints-2)))
            let newRange =  CPTPlotRange(locationDecimal: CPTDecimalFromDouble(Double(location)), lengthDecimal: CPTDecimalFromDouble(Double(maxDataPoints-2)))

            CPTAnimation.animate(masterPlotSpace, property: "xRange", from: oldRange, to: newRange, duration:0.01)

            self.masterPlotIndex += data.count;
            self.masterPlotData.append(contentsOf: data)

            masterPlot?.insertData(at: UInt(self.masterPlotData.count - data.count), numberOfRecords: UInt(data.count))
        } else {
            guard let slaveGraph = self.slavePlotView.hostedGraph else { return }
            guard let slavePlotSpace = slaveGraph.defaultPlotSpace as? CPTXYPlotSpace else { return }

            let slavePlot = slaveGraph.plot(withIdentifier: "slave-graph" as NSCopying)
            if ((slavePlot) != nil) {
                if (self.slavePlotData.count >= maxDataPoints) {
                    self.slavePlotData.removeFirst(_: data.count)
                    slavePlot?.deleteData(inIndexRange:NSRange(location: 0, length: data.count))
                }
            }

            let location: NSInteger
            if (self.slavePlotIndex >= maxDataPoints) {
                location = self.slavePlotIndex - maxDataPoints + 2
            } else {
                location = 0
            }

            let range: NSInteger
            if (location > 0) {
                range = location - data.count
            } else {
                range = 0
            }

            let oldRange =  CPTPlotRange(locationDecimal: CPTDecimalFromDouble(Double(range)), lengthDecimal: CPTDecimalFromDouble(Double(maxDataPoints-2)))
            let newRange =  CPTPlotRange(locationDecimal: CPTDecimalFromDouble(Double(location)), lengthDecimal: CPTDecimalFromDouble(Double(maxDataPoints-2)))

            CPTAnimation.animate(slavePlotSpace, property: "xRange", from: oldRange, to: newRange, duration:0.01)

            self.slavePlotIndex += data.count;
            self.slavePlotData.append(contentsOf: data)

            slavePlot?.insertData(at: UInt(self.slavePlotData.count - data.count), numberOfRecords: UInt(data.count))
        }
    }
       
    func configureGraphView() {
        masterPlotView.allowPinchScaling = false
        self.masterPlotData.removeAll()
        self.masterPlotIndex = 0
        
        slavePlotView.allowPinchScaling = false
        self.slavePlotData.removeAll()
        self.slavePlotIndex = 0
    }
    
    func configureGraphAxis() {
        let masterGraph = CPTXYGraph(frame: masterPlotView.bounds)
        let slaveGraph = CPTXYGraph(frame: slavePlotView.bounds)
        
        masterGraph.plotAreaFrame?.masksToBorder = false
        masterPlotView.hostedGraph = masterGraph
        masterGraph.paddingBottom = 40.0
        masterGraph.paddingLeft = 40.0
        masterGraph.paddingTop = 30.0
        masterGraph.paddingRight = 15.0
        
        slaveGraph.plotAreaFrame?.masksToBorder = false
        slavePlotView.hostedGraph = slaveGraph
        slaveGraph.paddingBottom = 40.0
        slaveGraph.paddingLeft = 40.0
        slaveGraph.paddingTop = 30.0
        slaveGraph.paddingRight = 15.0
        
        let masterAxisSet = masterGraph.axisSet as! CPTXYAxisSet
        let slaveAxisSet = slaveGraph.axisSet as! CPTXYAxisSet
        
        let axisTextStyle = CPTMutableTextStyle()
        axisTextStyle.color = CPTColor.white()
        axisTextStyle.fontName = "HelveticaNeue-Bold"
        axisTextStyle.fontSize = 10.0
        axisTextStyle.textAlignment = .center
       
        if let x = masterAxisSet.xAxis {
            x.majorIntervalLength = 5000
            x.axisLineStyle = nil
            x.axisConstraints = CPTConstraints(lowerOffset: 0.0)
            x.delegate = self
        }

        if let y = masterAxisSet.yAxis {
            y.majorIntervalLength   = 2000
            y.labelTextStyle = axisTextStyle
            y.axisLineStyle = nil
            y.axisConstraints = CPTConstraints(lowerOffset: 80.0)
            y.delegate = self
        }
        
        if let x = slaveAxisSet.xAxis {
            x.majorIntervalLength = 5000
            x.axisLineStyle = nil
            x.axisConstraints = CPTConstraints(lowerOffset: 0.0)
            x.delegate = self
        }

        if let y = slaveAxisSet.yAxis {
            y.majorIntervalLength   = 2000
            y.labelTextStyle = axisTextStyle
            y.axisLineStyle = nil
            y.axisConstraints = CPTConstraints(lowerOffset: 80.0)
            y.delegate = self
        }

        // Set plot space
        let xMin = 0.0
        let xMax = Double(maxDataPoints)
        let yMin = -2000.0
        let yMax = 2000.0
        
        guard let masterPlotSpace = masterGraph.defaultPlotSpace as? CPTXYPlotSpace else { return }
        guard let slavePlotSpace = slaveGraph.defaultPlotSpace as? CPTXYPlotSpace else { return }
        
        masterPlotSpace.xRange = CPTPlotRange(locationDecimal: CPTDecimalFromDouble(xMin), lengthDecimal: CPTDecimalFromDouble(xMax - xMin))
        masterPlotSpace.yRange = CPTPlotRange(locationDecimal: CPTDecimalFromDouble(yMin), lengthDecimal: CPTDecimalFromDouble(yMax - yMin))
        
        slavePlotSpace.xRange = CPTPlotRange(locationDecimal: CPTDecimalFromDouble(xMin), lengthDecimal: CPTDecimalFromDouble(xMax - xMin))
        slavePlotSpace.yRange = CPTPlotRange(locationDecimal: CPTDecimalFromDouble(yMin), lengthDecimal: CPTDecimalFromDouble(yMax - yMin))
    }
    
    func configurePlot() {
        masterPlot = CPTScatterPlot()
        slavePlot = CPTScatterPlot()
        
        let plotLineStyle = CPTMutableLineStyle()
        plotLineStyle.lineJoin = .round
        plotLineStyle.lineCap = .round
        plotLineStyle.lineWidth = 2
        plotLineStyle.lineColor = CPTColor.white()
        
        masterPlot.dataLineStyle = plotLineStyle
        masterPlot.curvedInterpolationOption = .catmullCustomAlpha
        masterPlot.interpolation = .curved
        masterPlot.identifier = "master-graph" as NSCoding & NSCopying & NSObjectProtocol
        
        slavePlot.dataLineStyle = plotLineStyle
        slavePlot.curvedInterpolationOption = .catmullCustomAlpha
        slavePlot.interpolation = .curved
        slavePlot.identifier = "slave-graph" as NSCoding & NSCopying & NSObjectProtocol
        
        guard let masterGraph = masterPlotView.hostedGraph else { return }
        masterPlot.dataSource = (self as CPTPlotDataSource)
        masterPlot.delegate = (self as CALayerDelegate)
        
        guard let slaveGraph = slavePlotView.hostedGraph else { return }
        slavePlot.dataSource = (self as CPTPlotDataSource)
        slavePlot.delegate = (self as CALayerDelegate)
        
        masterGraph.add(masterPlot, to: masterGraph.defaultPlotSpace)
        slaveGraph.add(slavePlot, to: slaveGraph.defaultPlotSpace)
    }
}

// MARK: Storyboard IBAction Handlers (Buttons, Views, etc...)
extension ViewController {
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
        let shioNoSize = (self.myDevices).count
        
        for shioNo in 1..<(shioNoSize+1) {
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let path = dir.appendingPathComponent("shio_log_ch" + String(shioNo) + ".txt")
                if (!logFileURLs.contains(path)) {
                    logFileURLs.append(path)
                }
                
                do {
                    try FileManager.default.removeItem(at: logFileURLs[shioNo - 1])
                } catch let error as NSError {
                    print("Error: \(error.domain)")
                    print("fileURL does not exist, creating...")
                }
                print("created shio_log_ch" + String(shioNo) + ".txt")
            }
        }
        
        appState = .logging
        print("start logging")
    }
    
    @IBAction func stopRecordButton(_ sender: UIButton) {
        if (appState == .logging) {
            appState = .idle
        }
        print("stop logging")
    }
    
    @IBAction func predictButton(_ sender: UIButton) {
        appState = .predicting
        
        for buffer in 0..<desiredChannels {
            autoreleasepool {
                mlCurrSamples[buffer] = 0
                mlBufferStates[buffer] = .empty
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
        if (appState == .predicting) {
            appState = .idle
        }
        print("stop predicting")
    }
    
    @IBAction func makeMasterButton(_ sender: UIButton) {
        for device in self.myDevices {
            guard let write_char_idx = device.characteristics!.firstIndex(where: { $0.uuid == tsmDataCharacteristicCBUUID }) else { return }
            if (channel == device.channel) {
                device.peripheral.writeValue(masterData, for: device.characteristics![write_char_idx], type: .withoutResponse)
                masterChannel = channel
            } else {
                device.peripheral.writeValue(slaveData, for: device.characteristics![write_char_idx], type: .withoutResponse)
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
    
    @IBAction func startPlotButton(_ sender: UIButton) {
        appState = .plotting
    }
    
    @IBAction func stopPlotButton(_ sender: UIButton) {
        appState = .idle
    }
}
