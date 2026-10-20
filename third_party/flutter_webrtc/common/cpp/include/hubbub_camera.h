// Hubbub patch (Windows only): "Keep full frame rate in low light".
//
// Many webcams (the Logitech C920 for one) default to a DirectShow
// auto-exposure priority of 1, which lets the camera halve its frame rate in dim
// light. While a Hubbub camera capture runs with the setting on, the priority is
// 0; the camera's own value comes back when the capture stops.
#pragma once

#include <string>

namespace hubbub {

// The setting. On by default. The first call also restores any change a crashed
// Hubbub left behind (recorded in HKCU\Software\Hubbub\CameraExposureRestore).
void CameraExposureSetEnabled(bool enabled);

// Before a capturer is created for the DirectShow device `id` (UTF-8, the
// device guid libwebrtc lists, which is the DevicePath moniker property).
// Returns a key for the device when its priority was changed from 1 to 0, else
// "" (setting off, no such control, already 0).
std::string CameraExposureBegin(const std::string& id);

// Ties the key to the video track whose capturer was created.
void CameraExposureBind(const std::string& track_id, const std::string& key);

// The capture of a track stopped: restore the device when it was the last user.
void CameraExposureEndTrack(const std::string& track_id);

// A capturer could not be created: undo CameraExposureBegin.
void CameraExposureEnd(const std::string& key);

// Plugin teardown and app quit: restore everything, whatever the use counts.
void CameraExposureRestoreAll();

}  // namespace hubbub
