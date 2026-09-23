#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在桌面创建「GitHub虚拟机管理工作台」快捷方式（零依赖）。

参考 9router 的 make_lnk.py：用 ctypes 直接调 COM 的 IShellLinkW，
不依赖 pywin32。快捷方式指向同目录的 open-workbench.vbs（静默启动 + 开浏览器）。

    python workbench/make-shortcut.py
    python workbench/make-shortcut.py --name "我的工作台"
"""
from __future__ import annotations

import argparse
import ctypes
import os
import sys
import uuid
from ctypes import (POINTER, Structure, byref, c_bool, c_int, c_int32, c_ubyte,
                    c_ulong, c_ushort, c_void_p, c_wchar_p)

if os.name != "nt":
    print("仅支持 Windows")
    sys.exit(1)

ole32 = ctypes.windll.ole32


class GUID(Structure):
    _fields_ = [("Data1", c_ulong), ("Data2", c_ushort), ("Data3", c_ushort),
                ("Data4", c_ubyte * 8)]


def _guid(s):
    u = uuid.UUID(s)
    return GUID(u.time_low, u.time_mid, u.time_hi_version, (c_ubyte * 8)(*u.bytes[8:16]))


CLSID_ShellLink = _guid("00021401-0000-0000-C000-000000000046")
# 注意：000214EE 是 IShellLink**A**（ANSI），000214F9 才是 IShellLinkW。
# 用错 IID 或错 vtable 下标 → 调到的不是想调的方法，会直接 access violation。
IID_IShellLinkW = _guid("000214F9-0000-0000-C000-000000000046")
IID_IPersistFile = _guid("0000010B-0000-0000-C000-000000000046")

# IShellLinkW vtable（IUnknown 占 0/1/2）：
#   3 GetPath  4 GetIDList  5 SetIDList  6 GetDescription  7 SetDescription
#   8 GetWorkingDirectory  9 SetWorkingDirectory  10 GetArguments  11 SetArguments
#   12 GetHotkey  13 SetHotkey  14 GetShowCmd  15 SetShowCmd
#   16 GetIconLocation  17 SetIconLocation  18 SetRelativePath  19 Resolve  20 SetPath
VT_SETPATH, VT_SETDESC, VT_SETWORK, VT_SETSHOW, VT_SETICON = 20, 7, 9, 15, 17
# IPersistFile vtable：3 GetClassID  4 IsDirty  5 Load  6 Save  7 SaveCompleted
VT_SAVE = 6

HRESULT = c_int32
LPVOID = c_void_p
CLSCTX_INPROC_SERVER = 1
COINIT_APARTMENTTHREADED = 2

SetStr_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, c_wchar_p)
SetIcon_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, c_wchar_p, c_int)
SetShow_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, c_int)
QI_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, POINTER(GUID), POINTER(LPVOID))
Release_t = ctypes.CFUNCTYPE(c_int, c_void_p)
Save_t = ctypes.CFUNCTYPE(HRESULT, c_void_p, c_wchar_p, c_bool)

ole32.CoInitializeEx.argtypes = [LPVOID, c_ulong]
ole32.CoInitializeEx.restype = HRESULT
ole32.CoCreateInstance.argtypes = [POINTER(GUID), LPVOID, c_ulong,
                                   POINTER(GUID), POINTER(LPVOID)]
ole32.CoCreateInstance.restype = HRESULT
ole32.CoUninitialize.argtypes = []


def _chk(name, hr):
    if hr < 0:
        print("FAIL", name, hex(hr & 0xFFFFFFFF))
        sys.exit(1)


def create_shortcut(lnk_path, target, workdir, icon, desc, show=1):
    ole32.CoInitializeEx(None, COINIT_APARTMENTTHREADED)
    ppv = LPVOID()
    _chk("CoCreateInstance",
         ole32.CoCreateInstance(byref(CLSID_ShellLink), None, CLSCTX_INPROC_SERVER,
                                byref(IID_IShellLinkW), byref(ppv)))
    psl = ppv
    vt = ctypes.cast(psl, POINTER(POINTER(c_void_p)))[0]
    qi, release = QI_t(vt[0]), Release_t(vt[2])
    set_path = SetStr_t(vt[VT_SETPATH])      # 20
    set_desc = SetStr_t(vt[VT_SETDESC])      # 7
    set_work = SetStr_t(vt[VT_SETWORK])      # 9
    set_show = SetShow_t(vt[VT_SETSHOW])     # 15
    set_icon = SetIcon_t(vt[VT_SETICON])     # 17

    _chk("SetPath", set_path(psl, target))
    _chk("SetDescription", set_desc(psl, desc))
    _chk("SetWorkingDirectory", set_work(psl, workdir))
    _chk("SetShowCmd", set_show(psl, show))
    if icon:
        _chk("SetIconLocation", set_icon(psl, icon, 0))

    ppf = LPVOID()
    _chk("QI IPersistFile", qi(psl, byref(IID_IPersistFile), byref(ppf)))
    vt2 = ctypes.cast(ppf, POINTER(POINTER(c_void_p)))[0]
    save = Save_t(vt2[VT_SAVE])              # 6
    _chk("Save", save(ppf, lnk_path, True))
    release(ppf)
    release(psl)
    ole32.CoUninitialize()
    return lnk_path


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="创建桌面快捷方式")
    ap.add_argument("--name", default="GitHub虚拟机管理工作台")
    ap.add_argument("--dir", default="", help="快捷方式放哪（默认桌面）")
    a = ap.parse_args()

    target = os.path.join(here, "open-workbench.vbs")
    icon = os.path.join(here, "workbench.ico")
    for p in (target, icon):
        if not os.path.isfile(p):
            print("缺少文件：", p)
            sys.exit(1)

    out_dir = a.dir or os.path.join(os.path.expanduser("~"), "Desktop")
    lnk = os.path.join(out_dir, a.name + ".lnk")
    create_shortcut(lnk, target, here, icon,
                    "GitHub虚拟机管理工作台 (http://127.0.0.1:8899)")
    print("OK created", lnk)


if __name__ == "__main__":
    main()
