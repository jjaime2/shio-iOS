# shio-iOS
iOS app to be paired with the Shio platform developed by Maruchi Kim and Jose Jaime

## Usage
### Connecting to Shio Devices
- Scan for devices
- Connect to devices, Shio will turn on a green LED to indicate that a central devices has connected

### Enable the PDM Microphone Stream
- Press the "Start Mic Stream" button, each connected Shio devices will begin streaming PDM microphone data to the iPhone

### Managing Time Sync
- Once connected, press "Refresh Channels" next to the Shio Channel Selector
- The selector will populate with numbers representing the Shio channels present
- Select the desired channel and press "Make Master" to promote this device to time sync master and all others to time sync slave

### Logging
- Once connected and the data stream is enabled, press "Start Record" to log received PDM data to a text file
- To access this data after pressing "Stop Record", connect iPhone to Mac device with XCode
- With devices selected, navigate to Window -> Devices and Simulators
- Select "shio-ble" from the Installed Apps section and click the gear icon followed by Download Container

### Source Separation (WIP)
- Once connected and the data stream is enabled, press "Start Predicting" to enable the CoreML Model which will stream received PDM data into model for source separation and localization

### Plotting
- Once connected and the data stream is enabled, press "Start Plotting" to enable a real-time plot of incoming PDM data

## Demo
<img src="https://github.com/jjaime2/shio-iOS/blob/master/shio_iOS.PNG" height="600">
