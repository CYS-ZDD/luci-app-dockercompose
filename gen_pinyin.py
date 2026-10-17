# -*- coding: utf-8 -*-
"""生成 常用汉字→拼音 的 JS 映射表（GB2312 一级字 3755 个）"""
from pypinyin import pinyin, Style
import json, os

chars = []
# GB2312 一级汉字区：0xB0A1 - 0xD7F9（3755 个常用字）
for b1 in range(0xB0, 0xD8):
    for b2 in range(0xA1, 0xFF):
        try:
            c = bytes([b1, b2]).decode('gb2312')
            chars.append(c)
        except Exception:
            pass

m = {}
miss = 0
for c in chars:
    try:
        py = pinyin(c, style=Style.NORMAL, heteronym=False)[0][0]
        if py: m[c] = py
        else: miss += 1
    except Exception:
        miss += 1

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "pinyin_map.js")
with open(out, "w", encoding="utf-8") as f:
    f.write("// 常用汉字拼音映射（GB2312 一级字，pypinyin 生成）\n")
    f.write("var PINYIN_MAP=" + json.dumps(m, ensure_ascii=False, separators=(',', ':')) + ";\n")
print("chars:", len(chars), "mapped:", len(m), "miss:", miss)
print("OUT:", out, "SIZE:", os.path.getsize(out), "bytes")
