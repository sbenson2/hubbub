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

// The IKsPropertySet of the ordinal-th video input device called `name`, opened
// only for the get or set, as the caller releases it at once.
IKsPropertySet* OpenDevice(const std::string& name, int ordinal) {
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
    int seen = 0;
    while (!result && en->Next(1, &mk, nullptr) == S_OK) {
      IPropertyBag* bag = nullptr;
      if (SUCCEEDED(mk->BindToStorage(nullptr, nullptr, IID_PPV_ARGS(&bag)))) {
        VARIANT v;
        VariantInit(&v);
        if (SUCCEEDED(bag->Read(L"FriendlyName", &v, nullptr)) &&
            v.vt == VT_BSTR && ToUtf8(v.bstrVal) == name) {
          if (seen++ == ordinal) {
            IBaseFilter* f = nullptr;
            if (SUCCEEDED(mk->BindToObject(nullptr, nullptr,
                                           IID_PPV_ARGS(&f)))) {
              f->QueryInterface(IID_PPV_ARGS(&result));
              f->Release();
            }
          }
        }
        VariantClear(&v);
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

// The crash record: value name "<device>#<ordinal>", data "<original>;<pid>".
void RecordWrite(const std::wstring& valueName, LONG original) {
  HKEY k;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRegKey, 0, nullptr, 0, KEY_SET_VALUE,
                      nullptr, &k, nullptr) != ERROR_SUCCESS) {
    return;
  }
  std::wstring data = std::to_wstring(original) + L";" +
                      std::to_wstring(GetCurrentProcessId());
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

bool ProcessAlive(DWORD pid) {
  HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, pid);
  if (!h) return false;
  bool alive = WaitForSingleObject(h, 0) == WAIT_TIMEOUT;
  CloseHandle(h);
  return alive;
}

// "device#ordinal" -> name, ordinal.
bool SplitKey(const std::string& key, std::string* name, int* ordinal) {
  size_t at = key.rfind('#');
  if (at == std::string::npos) return false;
  *name = key.substr(0, at);
  *ordinal = atoi(key.c_str() + at + 1);
  return true;
}

// Puts `original` back when the priority is still the 0 we set.
// Returns false only when the device could not be opened (unplugged).
bool RestoreDevice(const std::string& key, LONG original) {
  std::string name;
  int ordinal = 0;
  if (!SplitKey(key, &name, &ordinal)) return true;
  IKsPropertySet* ps = OpenDevice(name, ordinal);
  if (!ps) return false;
  LONG v = 0;
  ULONG fl = 0;
  if (GetPriority(ps, &v, &fl) && v == 0) SetPriority(ps, original, fl);
  ps->Release();
  return true;
}

// Restores what a Hubbub that died left changed. A record of a process that is
// still running (another Hubbub) is left alone.
void RecoverLocked() {
  if (g_recovered) return;
  g_recovered = true;
  HKEY k;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRegKey, 0,
                    KEY_QUERY_VALUE | KEY_SET_VALUE, &k) != ERROR_SUCCESS) {
    return;
  }
  std::map<std::wstring, std::wstring> records;
  for (DWORD i = 0;; i++) {
    wchar_t name[512];
    DWORD nameLen = 512;
    BYTE data[128];
    DWORD dataLen = sizeof(data) - sizeof(wchar_t);
    DWORD type = 0;
    LONG rc = RegEnumValueW(k, i, name, &nameLen, nullptr, &type, data,
                            &dataLen);
    if (rc == ERROR_NO_MORE_ITEMS) break;
    if (rc != ERROR_SUCCESS || type != REG_SZ) continue;
    reinterpret_cast<wchar_t*>(data)[dataLen / sizeof(wchar_t)] = 0;
    records[name] = reinterpret_cast<wchar_t*>(data);
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
    if (pid != GetCurrentProcessId() && ProcessAlive(pid)) continue;
    if (RestoreDevice(ToUtf8(r.first.c_str()), original)) RecordDelete(r.first);
  }
}

void EndLocked(const std::string& key) {
  auto it = g_active.find(key);
  if (it == g_active.end()) return;
  if (--it->second.users > 0) return;
  ComScope com;
  if (RestoreDevice(key, it->second.original)) RecordDelete(it->second.valueName);
  g_active.erase(it);
}

}  // namespace

void CameraExposureSetEnabled(bool enabled) {
  std::lock_guard<std::mutex> lock(g_mu);
  g_enabled = enabled;
  RecoverLocked();
}

std::string CameraExposureBegin(const std::string& name, int ordinal) {
  std::lock_guard<std::mutex> lock(g_mu);
  RecoverLocked();
  if (!g_enabled) return "";
  const std::string key = name + "#" + std::to_string(ordinal);
  auto it = g_active.find(key);
  if (it != g_active.end()) {
    it->second.users++;
    return key;
  }
  ComScope com;
  IKsPropertySet* ps = OpenDevice(name, ordinal);
  if (!ps) return "";
  std::string result;
  LONG v = 0;
  ULONG fl = 0;
  // Only a camera that reports the control, and has the default 1, is touched.
  if (GetPriority(ps, &v, &fl) && v == 1 && RecordWritable()) {
    const std::wstring valueName = ToWide(key);
    RecordWrite(valueName, v);  // before the change, so a crash can undo it
    if (SetPriority(ps, 0, fl)) {
      Active a;
      a.original = v;
      a.users = 1;
      a.valueName = valueName;
      g_active[key] = a;
      result = key;
    } else {
      RecordDelete(valueName);
    }
  }
  ps->Release();
  return result;
}

void CameraExposureBind(const std::string& track_id, const std::string& key) {
  if (key.empty()) return;
  std::lock_guard<std::mutex> lock(g_mu);
  g_track_key[track_id] = key;
}

void CameraExposureEndTrack(const std::string& track_id) {
  std::lock_guard<std::mutex> lock(g_mu);
  auto it = g_track_key.find(track_id);
  if (it == g_track_key.end()) return;
  const std::string key = it->second;
  g_track_key.erase(it);
  EndLocked(key);
}

void CameraExposureEnd(const std::string& key) {
  if (key.empty()) return;
  std::lock_guard<std::mutex> lock(g_mu);
  EndLocked(key);
}

void CameraExposureRestoreAll() {
  std::lock_guard<std::mutex> lock(g_mu);
  g_track_key.clear();
  ComScope com;
  for (auto& a : g_active) {
    if (RestoreDevice(a.first, a.second.original)) RecordDelete(a.second.valueName);
  }
  g_active.clear();
}

}  // namespace hubbub
