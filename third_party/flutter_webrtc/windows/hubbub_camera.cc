// Hubbub patch (Windows only): see hubbub_camera.h.
#include "hubbub_camera.h"

#include <windows.h>
#include <dshow.h>
#include <initguid.h>
#include <ks.h>
#include <ksmedia.h>
#include <ksproxy.h>

#include <map>
#include <mutex>
#include <string>

namespace hubbub {
namespace {

const wchar_t kRegKey[] = L"Software\\Hubbub\\CameraExposureRestore";

struct Active {
  LONG original = 1;
  int users = 0;
  std::wstring valueName;
};

std::mutex g_mu;
bool g_enabled = true;
bool g_recovered = false;
std::map<std::string, Active> g_active;           // device key -> state
std::map<std::string, std::string> g_track_key;   // track id -> device key

std::string ToUtf8(const wchar_t* w) {
  if (!w) return "";
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
  if (n <= 1) return "";
  std::string s(n - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
  return s;
}

std::wstring ToWide(const std::string& s) {
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (n <= 1) return L"";
  std::wstring w(n - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}

// COM for the calling thread, kept only for the length of one call.
struct ComScope {
  bool uninit = false;
  ComScope() {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    uninit = SUCCEEDED(hr);  // RPC_E_CHANGED_MODE: usable as it is, not ours
  }
  ~ComScope() {
    if (uninit) CoUninitialize();
  }
};

// The IKsPropertySet of the video input device whose DirectShow DevicePath is
// `id` (the id libwebrtc lists a device by), opened only for the get or set, as
// the caller releases it at once. A device without a DevicePath is matched by
// its FriendlyName, as libwebrtc then uses that for the id.
IKsPropertySet* OpenDevice(const std::string& id) {
  ICreateDevEnum* dev = nullptr;
  if (FAILED(CoCreateInstance(CLSID_SystemDeviceEnum, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dev)))) {
    return nullptr;
  }
  IKsPropertySet* result = nullptr;
  IEnumMoniker* en = nullptr;
  if (dev->CreateClassEnumerator(CLSID_VideoInputDeviceCategory, &en, 0) ==
      S_OK) {
    IMoniker* mk = nullptr;
    while (!result && en->Next(1, &mk, nullptr) == S_OK) {
      IPropertyBag* bag = nullptr;
      if (SUCCEEDED(mk->BindToStorage(nullptr, nullptr, IID_PPV_ARGS(&bag)))) {
        std::string path, friendly;
        VARIANT v;
        VariantInit(&v);
        if (SUCCEEDED(bag->Read(L"DevicePath", &v, nullptr)) &&
            v.vt == VT_BSTR) {
          path = ToUtf8(v.bstrVal);
        }
        VariantClear(&v);
        VariantInit(&v);
        if (SUCCEEDED(bag->Read(L"FriendlyName", &v, nullptr)) &&
            v.vt == VT_BSTR) {
          friendly = ToUtf8(v.bstrVal);
        }
        VariantClear(&v);
        if (path == id || (path.empty() && friendly == id)) {
          IBaseFilter* f = nullptr;
          if (SUCCEEDED(mk->BindToObject(nullptr, nullptr,
                                         IID_PPV_ARGS(&f)))) {
            f->QueryInterface(IID_PPV_ARGS(&result));
            f->Release();
          }
        }
        bag->Release();
      }
      mk->Release();
    }
    en->Release();
  }
  dev->Release();
  return result;
}

bool GetPriority(IKsPropertySet* ps, LONG* value, ULONG* flags) {
  KSPROPERTY_CAMERACONTROL_S p = {};
  ULONG ret = 0;
  if (FAILED(ps->Get(PROPSETID_VIDCAP_CAMERACONTROL,
                     KSPROPERTY_CAMERACONTROL_AUTO_EXPOSURE_PRIORITY, nullptr,
                     0, &p, sizeof(p), &ret))) {
    return false;
  }
  *value = p.Value;
  *flags = p.Flags;
  return true;
}

bool SetPriority(IKsPropertySet* ps, LONG value, ULONG flags) {
  KSPROPERTY_CAMERACONTROL_S p = {};
  p.Value = value;
  p.Flags = flags;
  return SUCCEEDED(ps->Set(PROPSETID_VIDCAP_CAMERACONTROL,
                           KSPROPERTY_CAMERACONTROL_AUTO_EXPOSURE_PRIORITY,
                           nullptr, 0, &p, sizeof(p)));
}

// The process creation time as a 64-bit FILETIME; 0 when unknown.
unsigned long long CreationTime(HANDLE h) {
  FILETIME c, e, k, u;
  if (!GetProcessTimes(h, &c, &e, &k, &u)) return 0;
  return (static_cast<unsigned long long>(c.dwHighDateTime) << 32) |
         c.dwLowDateTime;
}

// The crash record: value name = device id, data "<original>;<pid>;<created>".
// The creation time tells a reused pid from the Hubbub that wrote the record.
void RecordWrite(const std::wstring& valueName, LONG original) {
  HKEY k;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKey, 0, nullptr, 0, KEY_SET_VALUE,
                      nullptr, &k, nullptr) != ERROR_SUCCESS) {
    return;
  }
  std::wstring data = std::to_wstring(original) + L";" +
                      std::to_wstring(GetCurrentProcessId()) + L";" +
                      std::to_wstring(CreationTime(GetCurrentProcess()));
  RegSetValueExW(k, valueName.c_str(), 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(data.c_str()),
                 static_cast<DWORD>((data.size() + 1) * sizeof(wchar_t)));
  RegCloseKey(k);
}

bool RecordWritable() {
  HKEY k;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKey, 0, nullptr, 0, KEY_SET_VALUE,
                      nullptr, &k, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  RegCloseKey(k);
  return true;
}

void RecordDelete(const std::wstring& valueName) {
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegKey, 0, KEY_SET_VALUE, &k) ==
      ERROR_SUCCESS) {
    RegDeleteValueW(k, valueName.c_str());
    RegCloseKey(k);
  }
}

// True when the process `pid` that was created at `created` still runs. An
// access-denied open (an elevated Hubbub) counts as alive. A record without a
// creation time (0) falls back to the pid alone.
bool ProcessAlive(DWORD pid, unsigned long long created) {
  HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE,
                         pid);
  if (!h) return GetLastError() == ERROR_ACCESS_DENIED;
  bool alive = WaitForSingleObject(h, 0) == WAIT_TIMEOUT;
  if (alive && created != 0) {
    unsigned long long now = CreationTime(h);
    if (now != 0 && now != created) alive = false;  // the pid was reused
  }
  CloseHandle(h);
  return alive;
}

// Puts `original` back when the priority is still the 0 we set.
// Returns false only when the device could not be opened (unplugged).
bool RestoreDevice(const std::string& id, LONG original) {
  IKsPropertySet* ps = OpenDevice(id);
  if (!ps) return false;
  LONG v = 0;
  ULONG fl = 0;
  if (GetPriority(ps, &v, &fl) && v == 0) SetPriority(ps, original, fl);
  ps->Release();
  return true;
}

// Restores what a Hubbub that died left changed. A record of a process that is
// still running (another Hubbub) is left alone. No lock is held here.
void Recover() {
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegKey, 0,
                    KEY_QUERY_VALUE | KEY_SET_VALUE, &k) != ERROR_SUCCESS) {
    return;
  }
  std::map<std::wstring, std::wstring> records;
  for (DWORD i = 0;; i++) {
    wchar_t name[1024];
    DWORD nameLen = 1024;
    wchar_t data[64];  // wchar_t, so the buffer is aligned
    DWORD dataLen = sizeof(data) - sizeof(wchar_t);
    DWORD type = 0;
    LONG rc = RegEnumValueW(k, i, name, &nameLen, nullptr, &type,
                            reinterpret_cast<BYTE*>(data), &dataLen);
    if (rc == ERROR_NO_MORE_ITEMS) break;
    if (rc != ERROR_SUCCESS || type != REG_SZ) continue;
    data[dataLen / sizeof(wchar_t)] = 0;
    records[name] = data;
  }
  RegCloseKey(k);
  if (records.empty()) return;
  ComScope com;
  for (auto& r : records) {
    size_t semi = r.second.find(L';');
    if (semi == std::wstring::npos) {
      RecordDelete(r.first);
      continue;
    }
    LONG original = _wtol(r.second.c_str());
    DWORD pid = static_cast<DWORD>(_wtol(r.second.c_str() + semi + 1));
    unsigned long long created = 0;
    size_t semi2 = r.second.find(L';', semi + 1);
    if (semi2 != std::wstring::npos) {
      created = _wcstoui64(r.second.c_str() + semi2 + 1, nullptr, 10);
    }
    if (pid != GetCurrentProcessId() && ProcessAlive(pid, created)) continue;
    if (RestoreDevice(ToUtf8(r.first.c_str()), original)) RecordDelete(r.first);
  }
}

// Recovery once per process. Only the first caller does the work, outside the
// lock; a concurrent caller does not wait for it.
void RecoverOnce() {
  {
    std::lock_guard<std::mutex> lock(g_mu);
    if (g_recovered) return;
    g_recovered = true;
  }
  Recover();
}

// Drops one user of `key`; the last one restores the device (outside the lock).
void End(const std::string& key) {
  Active gone;
  {
    std::lock_guard<std::mutex> lock(g_mu);
    auto it = g_active.find(key);
    if (it == g_active.end()) return;
    if (--it->second.users > 0) return;
    gone = it->second;
    g_active.erase(it);
  }
  ComScope com;
  if (RestoreDevice(key, gone.original)) RecordDelete(gone.valueName);
}

}  // namespace

void CameraExposureSetEnabled(bool enabled) {
  {
    std::lock_guard<std::mutex> lock(g_mu);
    g_enabled = enabled;
  }
  RecoverOnce();
}

std::string CameraExposureBegin(const std::string& id) {
  RecoverOnce();
  {
    std::lock_guard<std::mutex> lock(g_mu);
    if (!g_enabled || id.empty()) return "";
    auto it = g_active.find(id);
    if (it != g_active.end()) {
      it->second.users++;
      return id;
    }
  }
  // The COM work runs without the lock.
  ComScope com;
  IKsPropertySet* ps = OpenDevice(id);
  if (!ps) return "";
  bool changed = false;
  LONG v = 0;
  ULONG fl = 0;
  const std::wstring valueName = ToWide(id);
  // Only a camera that reports the control, and has the default 1, is touched.
  if (GetPriority(ps, &v, &fl) && v == 1 && RecordWritable()) {
    RecordWrite(valueName, v);  // before the change, so a crash can undo it
    if (SetPriority(ps, 0, fl)) {
      changed = true;
    } else {
      RecordDelete(valueName);
    }
  }
  ps->Release();
  if (!changed) return "";
  std::lock_guard<std::mutex> lock(g_mu);
  auto it = g_active.find(id);
  if (it != g_active.end()) {
    it->second.users++;  // another capture of the same camera got there first
    return id;
  }
  Active a;
  a.original = v;
  a.users = 1;
  a.valueName = valueName;
  g_active[id] = a;
  return id;
}

void CameraExposureBind(const std::string& track_id, const std::string& key) {
  if (key.empty()) return;
  std::lock_guard<std::mutex> lock(g_mu);
  g_track_key[track_id] = key;
}

void CameraExposureEndTrack(const std::string& track_id) {
  std::string key;
  {
    std::lock_guard<std::mutex> lock(g_mu);
    auto it = g_track_key.find(track_id);
    if (it == g_track_key.end()) return;
    key = it->second;
    g_track_key.erase(it);
  }
  End(key);
}

void CameraExposureEnd(const std::string& key) {
  if (key.empty()) return;
  End(key);
}

void CameraExposureRestoreAll() {
  std::map<std::string, Active> all;
  {
    std::lock_guard<std::mutex> lock(g_mu);
    g_track_key.clear();
    all.swap(g_active);
  }
  ComScope com;
  for (auto& a : all) {
    if (RestoreDevice(a.first, a.second.original)) RecordDelete(a.second.valueName);
  }
}

}  // namespace hubbub
