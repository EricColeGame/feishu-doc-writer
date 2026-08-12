---
name: Feishu Doc Writer
description: 稳定的飞书文档写入工具，支持大量关键词和图片的两阶段提交、checkpoint 恢复和完整性校验
read_when:
  - 需要将 trends-valid 结果写入飞书文档
  - 需要批量写入大量内容到飞书
metadata: {"clawdbot":{"emoji":"📝"}}
---

# Feishu Doc Writer - 飞书文档稳定写入

## 功能特性

- ✅ 两阶段提交：先写正文，再插图片
- ✅ Checkpoint 机制：支持中断恢复
- ✅ 完整性校验：确保所有内容写入成功
- ✅ 降级重试：2词→1词→段落级
- ✅ 幂等性保证：已写入的不重复写

## 使用方法

```bash
# 基本用法
./write-valid-doc.sh <result_file>

# 从 checkpoint 恢复
./write-valid-doc.sh <result_file> <checkpoint_file>

# 示例
./write-valid-doc.sh /path/to/trends-valid-result.json
```

## 输出格式

```json
{
  "status": "success",
  "doc_token": "...",
  "doc_url": "https://your-tenant.feishu.cn/docx/...",
  "summary": {
    "total_keywords": 36,
    "written_keywords": 36,
    "total_images": 108,
    "replaced_images": 108,
    "remaining_placeholders": 0
  },
  "checkpoint_file": "./output/checkpoints/20260317_052944.json"
}
```

## 执行流程

1. **阶段 1：正文写入**
   - 创建飞书文档
   - 分批写入关键词块（每批 2 个，7000 字符限制）
   - 失败时降级重试（2词→1词→段落级）
   - 每批写入后更新 checkpoint

2. **阶段 1.5：完整性校验**
   - 验证 36 个关键词标题全部存在
   - 验证 108 个占位符全部存在
   - 若有缺失，补写后重新校验

3. **阶段 2：图片替换**
   - 遍历 108 个占位符
   - 上传图片并替换占位符
   - 失败时重试 3 次
   - 每次成功后更新 checkpoint

4. **最终验证**
   - 确认无残留占位符
   - 输出完整性报告
