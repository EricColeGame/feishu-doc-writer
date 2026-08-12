#!/usr/bin/env python3
"""把生财 getChapterContent API 的 chapter JSON 解析成 markdown 正文 + 下载图片。

Usage: chapter_parse.py <chapter.json> <out_md> <img_dir>

- 遍历 data.content blocks，按 block_type 转成 markdown 行
- image (27) 用 file_url 下载到 img_dir（retry 3 次规避 OSS QPS 限流），转 PNG，正文放 [[img-NN]] 占位符
- quote_container (34) 递归处理 children_blocks
"""
import json, os, sys, time, urllib.request

PREFIX = {
    3: "## ", 4: "## ", 5: "### ",
    6: "#### ", 7: "#### ", 8: "#### ", 9: "- ",
}
TEXT_KEYS = ("heading1","heading2","heading3","heading4","heading5",
             "heading6","heading7","heading8","heading9",
             "text","bullet","ordered","code")

def get_text(b):
    for k in TEXT_KEYS:
        v = b.get(k)
        if isinstance(v, dict):
            els = v.get("elements", [])
            return "".join(e.get("text_run", {}).get("content", "")
                           for e in els if isinstance(e, dict))
    return None

def detect_ext(data):
    if data[:4] == b"RIFF":
        return "webp"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    if data[:3] == b"\xff\xd8\xff":
        return "jpg"
    return "png"

def main():
    json_path, out_md, img_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(img_dir, exist_ok=True)
    data = json.load(open(json_path, encoding="utf-8"))

    state = {"img_idx": 0}
    lines = []

    def process(b, indent=""):
        bt = b.get("block_type")
        if bt == 27:  # image
            url = b.get("file_url", "")
            if not (url and url.startswith("http")):
                return
            state["img_idx"] += 1
            n = state["img_idx"]
            content = None
            for attempt in range(3):  # retry 规避 OSS QPS 限流返回空 body
                try:
                    req = urllib.request.Request(url, headers={
                        "Referer": "https://scys.com/",
                        "User-Agent": "Mozilla/5.0",
                    })
                    with urllib.request.urlopen(req, timeout=30) as r:
                        body = r.read()
                    if len(body) > 100:  # 有效图 >100 字节
                        content = body
                        break
                except Exception:
                    pass
                time.sleep(1 + attempt)
            if content is None:
                lines.append(f"{indent}[图片下载失败 img-{n:02d}]")
                return
            ext = detect_ext(content)
            if ext == "webp":  # 飞书 docx 渲染 VP8X WebP 下半空白，转 PNG
                from PIL import Image
                import io
                img = Image.open(io.BytesIO(content))
                buf = io.BytesIO()
                img.save(buf, format="PNG")
                content = buf.getvalue()
                ext = "png"
            fname = f"img-{n:02d}.{ext}"
            open(os.path.join(img_dir, fname), "wb").write(content)
            lines.append(f"{indent}[[img-{n:02d}]]")
            return
        if bt == 34 and isinstance(b.get("children_blocks"), list):  # quote container
            for child in b["children_blocks"]:
                process(child, indent)
            return
        text = get_text(b)
        if text is None:
            return
        text = text.rstrip()
        if not text.strip():
            return
        prefix = PREFIX.get(bt, "")
        if bt == 12:  # bullet
            prefix = "- "
        elif bt == 13:  # ordered
            prefix = ""
        lines.append(indent + prefix + text)

    for b in data.get("content", []):
        process(b)

    with open(out_md, "w", encoding="utf-8") as f:
        f.write("\n\n".join(lines))
    print(f"图片: {state['img_idx']} 张, 正文行: {len(lines)}")

if __name__ == "__main__":
    main()
