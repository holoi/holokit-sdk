#ifndef HOLOKIT_SDK_SENSORS_DEVICE_ACCELEROMETER_SENSOR_H_
#define HOLOKIT_SDK_SENSORS_DEVICE_ACCELEROMETER_SENSOR_H_

#include <memory>
#include <vector>

#include "sensors/accelerometer_data.h"
#include "utils/vector.h"

namespace holokit {

// Wrapper class that reads accelerometer sensor data from the native sensor
// framework.
class DeviceAccelerometerSensor {
 public:
  DeviceAccelerometerSensor();

  ~DeviceAccelerometerSensor();

  // Starts the sensor capture process.
  // This must be called successfully before calling PollForSensorData().
  //
  // @return false if the requested sensor is not supported.
  bool Start();

  // Actively waits up to timeout_ms and polls for sensor data. If
  // timeout_ms < 0, it waits indefinitely until sensor data is
  // available.
  // This must only be called after a successful call to Start() was made.
  //
  // @param timeout_ms timeout period in milliseconds.
  // @param results list of events emitted by the sensor.
  void PollForSensorData(int timeout_ms,
                         std::vector<AccelerometerData>* results) const;

  // Stops the sensor capture process.
  void Stop();

  // The implementation of device sensors differs between iOS and Android.
  struct SensorInfo;

 private:
  const std::unique_ptr<SensorInfo> sensor_info_;
};

}  // namespace holokit

#endif  // HOLOKIT_SDK_SENSORS_DEVICE_ACCELEROMETER_SENSOR_H_
