#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成工作台图标 workbench.ico（零依赖，只用标准库）。

设计：蓝色圆角方块 + 白色显示器 + 右下角绿色「在线」圆点。
所有图形用「超采样 + 盒式降采样」得到抗锯齿，不依赖 Pillow。

    python workbench/make-icon.py                 # 生成 workbench/workbench.ico
    python workbench/make-icon.py --png out.png   # 额外导出一张预览 PNG
"""
from __future__ import annotations

import argparse
import os
import struct
import zlib

# ---- 调色板 ---------------------------------------------------------------
BG_TOP = (47, 129, 247)     # #2f81f7
BG_BOT = (13, 65, 157)      # #0d419d
SCREEN = (13, 17, 23)       # #0d1117 显示器内部（深色）
GLYPH = (255, 255, 255)     # 显示器外框 / 支架
DOT = (63, 185, 80)         # #3fb950 在线绿点

SIZES = [16, 24, 32, 48, 64, 128, 256]


class Canvas(object):
    """RGBA（直通 alpha）画布，硬边绘制 + 超采样降采样做抗锯齿。"""

    def __init__(self, w, h):
        self.w, self.h = w, h
        self.buf = bytearray(w * h * 4)

    def blend(self, x, y, color, alpha=1.0):
        if alpha <= 0:
            return
        i = (y * self.w + x) * 4
        b = self.buf
        a = min(1.0, max(0.0, alpha))
        if a >= 0.999:
            b[i], b[i + 1], b[i + 2], b[i + 3] = color[0], color[1], color[2], 255
            return
        ia = 1.0 - a
        b[i] = int(color[0] * a + b[i] * ia + 0.5)
        b[i + 1] = int(color[1] * a + b[i + 1] * ia + 0.5)
        b[i + 2] = int(color[2] * a + b[i + 2] * ia + 0.5)
        b[i + 3] = int(255 * a + b[i + 3] * ia + 0.5)


def _in_round_rect(px, py, x0, y0, x1, y1, r):
    if px < x0 or px > x1 or py < y0 or py > y1:
        return False
    cx = min(max(px, x0 + r), x1 - r)
    cy = min(max(py, y0 + r), y1 - r)
    dx, dy = px - cx, py - cy
    return dx * dx + dy * dy <= r * r


def fill_round_rect(c, x0, y0, x1, y1, r, color, grad=None):
    """grad=(top_color, bottom_color) 时按 y 做竖直渐变。"""
    y0i, y1i = max(0, int(y0)), min(c.h - 1, int(y1) + 1)
    x0i, x1i = max(0, int(x0)), min(c.w - 1, int(x1) + 1)
    span = max(1.0, y1 - y0)
    for y in range(y0i, y1i + 1):
        py = y + 0.5
        col = color
        if grad:
            t = min(1.0, max(0.0, (py - y0) / span))
            col = tuple(int(grad[0][k] * (1 - t) + grad[1][k] * t + 0.5) for k in range(3))
        for x in range(x0i, x1i + 1):
            if _in_round_rect(x + 0.5, py, x0, y0, x1, y1, r):
                c.blend(x, y, col)


def fill_circle(c, cx, cy, r, color):
    x0, x1 = max(0, int(cx - r) - 1), min(c.w - 1, int(cx + r) + 1)
    y0, y1 = max(0, int(cy - r) - 1), min(c.h - 1, int(cy + r) + 1)
    rr = r * r
    for y in range(y0, y1 + 1):
        dy = y + 0.5 - cy
        for x in range(x0, x1 + 1):
            dx = x + 0.5 - cx
            if dx * dx + dy * dy <= rr:
                c.blend(x, y, color)


def draw_icon(N):
    """在 N×N 画布上绘制（坐标用 0..1 归一化）。"""
    c = Canvas(N, N)

    def u(v):
        return v * N

    # 背景圆角方块（竖直渐变）
    fill_round_rect(c, u(0.02), u(0.02), u(0.98), u(0.98), u(0.21), BG_BOT,
                    grad=(BG_TOP, BG_BOT))

    # 显示器：白色外框 = 白圆角矩形 + 内部深色圆角矩形
    mx0, my0, mx1, my1 = u(0.16), u(0.17), u(0.73), u(0.56)
    fill_round_rect(c, mx0, my0, mx1, my1, u(0.055), GLYPH)
    t = u(0.055)                      # 边框厚度
    fill_round_rect(c, mx0 + t, my0 + t, mx1 - t, my1 - t, u(0.012), SCREEN)

    # 支架 + 底座
    fill_round_rect(c, u(0.405), u(0.56), u(0.485), u(0.71), u(0.012), GLYPH)
    fill_round_rect(c, u(0.29), u(0.71), u(0.60), u(0.775), u(0.028), GLYPH)

    # 右下角「在线」绿点（先画一圈背景色做分离环，再画绿点）
    dcx, dcy, dr = u(0.745), u(0.755), u(0.165)
    fill_circle(c, dcx, dcy, dr + u(0.052), BG_BOT)
    fill_circle(c, dcx, dcy, dr, DOT)
    return c


def downsample(c, factor):
    """盒式降采样（在预乘 alpha 空间平均，避免边缘串色）。"""
    w, h = c.w // factor, c.h // factor
    out = Canvas(w, h)
    src, dst = c.buf, out.buf
    n = factor * factor
    for y in range(h):
        for x in range(w):
            r = g = b = a = 0
            for dy in range(factor):
                row = ((y * factor + dy) * c.w + x * factor) * 4
                for dx in range(factor):
                    i = row + dx * 4
                    al = src[i + 3]
                    r += src[i] * al
                    g += src[i + 1] * al
                    b += src[i + 2] * al
                    a += al
            j = (y * w + x) * 4
            if a > 0:
                dst[j] = min(255, int(r / a + 0.5))
                dst[j + 1] = min(255, int(g / a + 0.5))
                dst[j + 2] = min(255, int(b / a + 0.5))
            dst[j + 3] = min(255, int(a / n + 0.5))
    return out


def render(size):
    factor = max(4, min(32, 1024 // size))
    return downsample(draw_icon(size * factor), factor)


def ico_image(canvas):
    """单张 32bpp BMP（BITMAPINFOHEADER + BGRA 自下而上 + 全零 AND 掩码）。"""
    w, h = canvas.w, canvas.h
    header = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, w * h * 4, 0, 0, 0, 0)
    xor = bytearray()
    src = canvas.buf
    for y in range(h - 1, -1, -1):          # 自下而上
        row = y * w * 4
        for x in range(w):
            i = row + x * 4
            xor += bytes((src[i + 2], src[i + 1], src[i], src[i + 3]))   # BGRA
    row_bytes = ((w + 31) // 32) * 4
    and_mask = bytes(row_bytes * h)
    return header + bytes(xor) + and_mask


def build_ico(path, sizes=None):
    sizes = sizes or SIZES
    images = [(s, ico_image(render(s))) for s in sizes]
    dir_entries, blobs, offset = b"", b"", 6 + 16 * len(images)
    for s, data in images:
        dir_entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    with open(path, "wb") as f:
        f.write(struct.pack("<HHH", 0, 1, len(images)) + dir_entries + blobs)
    return path


def write_png(path, canvas):
    """把画布导出成 RGBA PNG（预览用）。"""
    w, h = canvas.w, canvas.h
    raw = bytearray()
    for y in range(h):
        raw.append(0)                        # filter: none
        raw += canvas.buf[y * w * 4:(y + 1) * w * 4]

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    return path


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="生成工作台图标（零依赖）")
    ap.add_argument("--out", default=os.path.join(here, "workbench.ico"))
    ap.add_argument("--png", default="", help="额外导出预览 PNG 的路径")
    a = ap.parse_args()
    print("ICO ->", build_ico(a.out))
    if a.png:
        print("PNG ->", write_png(a.png, render(256)))


if __name__ == "__main__":
    main()
