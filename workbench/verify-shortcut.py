#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 .lnk：① 原始解析 UTF-16 字符串；② 用 COM IShellLinkW 的 Get* 读回。

    python verify-shortcut.py "C:\\Users\\aigc\\Desktop\\GitHub虚拟机管理工作台.lnk"
"""
from __future__ import annotations
import ctypes, os, sys, uuid
from ctypes import (POINTER, Structure, byref, c_int, c_int32, c_uint,
                    c_ulong, c_ushort, c_ubyte, c_void_p, c_wchar_p, create_unicode_buffer)

LNK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.expanduser("~"), "Desktop", "GitHub虚拟机管理工作台.lnk")

print("== 文件 ==")
st = os.stat(LNK)
print(f"path   = {LNK}")
print(f"size   = {st.st_size} bytes")

# ---------- ① 原始解析：抽出所有 UTF-16LE 可打印串 ----------
raw = open(LNK, "rb").read()
print("\n== 原始 UTF-16LE 字符串（去重、>=4 字符）==")
seen, cur = [], []
for i in range(0, len(raw) - 1, 2):
    lo, hi = raw[i], raw[i + 1]
    if hi == 0 and 0x20 <= lo < 0x7f:
        cur.append(chr(lo))
    else:
        if len(cur) >= 4:
            s = "".join(cur)
            if s not in seen:
                seen.append(s)
        cur = []
if len(cur) >= 4:
    seen.append("".join(cur))
for s in seen:
    print("   ", s)

# ---------- ② COM 读回 ----------
class GUID(Structure):
    _fields_ = [("Data1", c_ulong), ("Data2", c_ushort), ("Data3", c_ushort),
                ("Data4", c_ubyte * 8)]

def _guid(s):
    u = uuid.UUID(s)
    return GUID(u.time_low, u.time_mid, u.time_hi_version, (c_ubyte * 8)(*u.bytes[8:16]))

CLSID_ShellLink = _guid("00021401-0000-0000-C000-000000000046")
IID_IShellLinkW = _guid("000214F9-0000-0000-C000-000000000046")
IID_IPersistFile = _guid("0000010B-0000-0000-C000-000000000046")

ole32 = ctypes.windll.ole32
HRESULT = c_int32
LPVOID = c_void_p
GetStr_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, c_wchar_p, c_int)
GetIcon_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, c_wchar_p, c_int, POINTER(c_int))
GetPath_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, c_wchar_p, c_int, c_void_p)
QI_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, POINTER(GUID), POINTER(LPVOID))
Release_t = ctypes.CFUNCTYPE(c_uint, c_void_p)
Load_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, c_wchar_p, c_uint)
GetInt_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, POINTER(c_int))

ole32.CoInitializeEx.argtypes = [LPVOID, c_ulong]
ole32.CoCreateInstance.argtypes = [POINTER(GUID), LPVOID, c_ulong, POINTER(GUID), POINTER(LPVOID)]

def hr(x): return x & 0xFFFFFFFF

print("\n== COM IShellLinkW 读回 ==")
ole32.CoInitializeEx(None, 2)
ppv = LPVOID()
r = ole32.CoCreateInstance(byref(CLSID_ShellLink), None, 1, byref(IID_IShellLinkW), byref(ppv))
print("CoCreateInstance hr =", hex(hr(r)))
psl = ppv
vt = ctypes.cast(psl, POINTER(POINTER(c_void_p)))[0]
qi, release = QI_t(vt[0]), Release_t(vt[2])
get_path, get_desc, get_work = GetPath_t(vt[3]), GetStr_t(vt[6]), GetStr_t(vt[8])
get_icon = GetIcon_t(vt[16])
get_show = GetInt_t(vt[14])

ppf = LPVOID()
r = qi(psl, byref(IID_IPersistFile), byref(ppf))
print("QI IPersistFile hr =", hex(hr(r)))
vt2 = ctypes.cast(ppf, POINTER(POINTER(c_void_p)))[0]
load = Load_t(vt2[5])
r = load(ppf, LNK, 0)  # STGM_READ
print("Load hr =", hex(hr(r)))

b = create_unicode_buffer(1024)
find_data = ctypes.create_string_buffer(1024)
get_path(psl, b, 1024, ctypes.cast(find_data, c_void_p)); print("TargetPath   =", b.value)
get_desc(psl, b, 1024); print("Description  =", b.value)
get_work(psl, b, 1024); print("WorkingDir   =", b.value)
bi = create_unicode_buffer(1024); idx = c_int()
get_icon(psl, bi, 1024, byref(idx)); print(f"IconLocation = {bi.value},{idx.value}")
si = c_int(); get_show(psl, byref(si)); print("ShowCmd      =", si.value)

release(ppf); release(psl); ole32.CoUninitialize()
