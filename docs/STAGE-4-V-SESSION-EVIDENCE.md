# Stage 4-V 隔离沙盒合成文件夹会话证据

> 日期：2026-07-17
>
> 验收基线：`40a6d9ee4c7bd6657006d90c42a97a08bf326400`
>
> 结果：Passed；验证切片，无可执行实现改动

## 1. 范围与隔离

本记录只覆盖使用合成临时文件夹的真实 ImageAll App、`NSOpenPanel`、SwiftUI 网格与可移植导出会话。
测试未读取 `user/`，未访问或遍历 `/Volumes/HDD2`，未点击 Apple Photos 入口，未请求 Photos 权限，
未使用真实照片。

测试根为 `/tmp/ImageAll-Stage4V-20260717-1200`。构建使用独立 DerivedData 和独立 Bundle ID；启动前
`~/Library/Containers/com.gwlee.ImageAll.Stage4V.20260717` 不存在，启动后目录库只出现在该独立容器。
构建按正常流程读取实时 Xcode 工程，但本 Slice 未审阅既有 `project.pbxproj` 差异，未读取 App Icon、
`design/`、`scripts/` 或 `user/` 的内容，也未编辑、暂存或提交这些既有改动。因此本记录只宣称运行数据
和容器隔离，不宣称构建产物不受实时工程配置影响。

## 2. 构建与签名

```sh
ROOT=/tmp/ImageAll-Stage4V-20260717-1200
mkdir -p "$ROOT/source" "$ROOT/export-disjoint" "$ROOT/derived-data" "$ROOT/evidence"

xcodebuild -project ImageAll.xcodeproj -scheme ImageAll -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ROOT/derived-data" \
  PRODUCT_BUNDLE_IDENTIFIER=com.gwlee.ImageAll.Stage4V.20260717 \
  build

APP="$ROOT/derived-data/Build/Products/Debug/ImageAll.app"
codesign --verify --deep --strict "$APP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"
codesign -d --entitlements :- "$APP"
codesign -dv --verbose=4 "$APP"
```

关键结果：

- `** BUILD SUCCEEDED **`；
- Bundle ID：`com.gwlee.ImageAll.Stage4V.20260717`；
- 签名：`Apple Development: 17621223203@163.com (CB9KZMUNYJ)`；
- Team ID：`962554J6D3`；
- App Sandbox、app-scope bookmark、user-selected read-write entitlement 均存在；
- `codesign --verify --deep --strict` 退出码为 0。

## 3. 合成来源与源树基线

使用 AppKit 在 `source/` 当场生成 100 张有效 PNG。序号决定尺寸、色相和图片中的
`Stage 4-V <序号>` 文本；图片不来自任何用户目录。生成和建立逐文件哈希基线的命令为：

```sh
xcrun swift -e 'import AppKit; import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for index in 1...100 {
    let width = 640 + (index % 5) * 80
    let height = 480 + (index % 7) * 60
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor(
        calibratedHue: CGFloat(index % 100) / 100.0,
        saturation: 0.68,
        brightness: 0.86,
        alpha: 1
    ).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    let text = String(format: "Stage 4-V %03d", index) as NSString
    text.draw(
        at: NSPoint(x: 32, y: 32),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: 42, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
    )
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { fatalError("png") }
    let name = String(format: "synthetic-%03d.png", index)
    try png.write(to: root.appendingPathComponent(name), options: .atomic)
}' "$ROOT/source"

rg --files "$ROOT/source" | sort | xargs shasum -a 256 \
  > "$ROOT/evidence/source-before.sha256"
wc -l "$ROOT/evidence/source-before.sha256"
shasum -a 256 "$ROOT/evidence/source-before.sha256"
```

结果为 100 行，清单摘要为
`4e50ee0e5f582d89346a0d1af32f46e33d67b0008d5140fa196e37f5ac4e5ae4`。

## 4. 真实 UI 会话

通过 Computer Use 操作独立 App，实际执行并观察到：

1. 空库点击“连接照片文件夹…”，在真实 `NSOpenPanel` 中选择 `source/`；
2. 主窗口出现 active `source`，隔离目录库查询为 1 个 Source、100 个 Asset；
3. 网格顶部可见 `synthetic-092.png` 等项目；执行 `AXScrollToBottom` 后滚动值为 `1`，底部可见
   `synthetic-001.png`、`synthetic-037.png`、`synthetic-077.png` 等不同项目；
4. 选择 `synthetic-001.png` 后按 Space，`singlePhotoView` 显示图片；Inspector 显示 `public.png`、
   `720 × 540` 和可用状态；Escape 返回网格；
5. 在真实导出面板选择 `export-disjoint/`，界面显示“已导出 201 条记录到
   `ImageAll-Export-20260717-045550Z`”；
6. 再次导出并选择 `source/` 的祖先测试根，界面显示“导出位置不能与已添加的文件夹来源重叠，请选择
   其他文件夹。”，测试根没有生成 `ImageAll-Export-*`；
7. 退出 App 后，以同一独立 App 再次启动；未重新打开 `NSOpenPanel`，侧栏自动恢复 active `source`，
   随后点击“立即重扫”。`scan_generation` 从 1 变为 2，completed `folder.reconcile.v1` Job 从 1 个变为
   2 个，目录库仍为 1 个 active folder Source、100 个 Asset；源树复算不变后再次退出。这个重扫必须
   重新解析持久 bookmark、开启安全作用域并枚举来源，不能只依赖数据库投影或既有缩略图缓存。

会话截图保留在可丢弃测试根，未提交二进制文件。文件名与 SHA-256 索引为：

```text
8295b7dd880145a4e7b79efc0e002cb8cf6b864ca3e986cc057c9a4bae6f0b4c  grid-bottom.png
78e666f493926829f250a7b1df73f25f884197a897362c4dd54ec8228a98e5d0  single-photo-preview.png
dbe5e416131b4d13f53c99a3b354bc4514d4a33ab3e01ff304383b973a540621  export-success.png
5acc842db5138fe71c798ae3158390cf43305d72d4b848e55e78ede7e0532f26  export-overlap-rejected.png
9623cef47afea2d4f4788784712e9ecc52d0ce7594518e529e844a038d1d2e28  restart-bookmark-restored.png
035eff2766439185bbbe96edccbbe998f79b564c5457d6c58bdbd57eb4243843  restart-rescan-completed.png
```

## 5. 导出与只读校验

```sh
BUNDLE=$(find "$ROOT/export-disjoint" -mindepth 1 -maxdepth 1 \
  -type d -name 'ImageAll-Export-*' -print -quit)
jq '[.files[].record_count] | add' "$BUNDLE/manifest.json"
jq -r '.files[] | "\(.sha256)  \(.filename)"' "$BUNDLE/manifest.json" \
  > "$ROOT/evidence/export-expected.sha256"
(cd "$BUNDLE" && shasum -a 256 -c "$ROOT/evidence/export-expected.sha256")

CONTAINER="$HOME/Library/Containers/com.gwlee.ImageAll.Stage4V.20260717"
DB="$CONTAINER/Data/Library/Application Support/ImageAll/Catalog/ImageAll.sqlite"
sqlite3 -readonly "$DB" \
  'select scan_generation,dirty_epoch,state from source;
   select kind,state,count(*) from job group by kind,state order by kind,state;
   select count(*) from asset;'

rg --files "$ROOT/source" | sort | xargs shasum -a 256 \
  > "$ROOT/evidence/source-after-restart-rescan.sha256"
cmp "$ROOT/evidence/source-before.sha256" \
  "$ROOT/evidence/source-after-restart-rescan.sha256"

find "$ROOT" -mindepth 1 -maxdepth 1 -type d \
  -name 'ImageAll-Export-*' -print
```

结果：manifest 记录合计 201；`assets.jsonl` 100、`file_fingerprints.jsonl` 100、`sources.jsonl` 1，
其余五个 JSONL 为 0。八个 JSONL 的 SHA-256 全部为 `OK`。源树最终清单与基线 `cmp` 退出码为 0；
测试根顶层的重叠导出包查询无输出。跨重启重扫使 `scan_generation` 从 1 增至 2，并新增一个 completed
`folder.reconcile.v1` Job；Asset 计数保持 100。

## 6. 结论与停止位置

本证据关闭的是：独立 Bundle ID 沙盒中，合成临时文件夹的真实 `NSOpenPanel` 授权、app-scope bookmark
创建与跨进程重启后的无面板重扫、100 项网格滚动、单图标准预览、不相交导出，以及来源祖先目标的写前
拒绝提示。

本证据不关闭 Apple Photos 权限、`destinationIsolationIndeterminate` 的真实窗口路径、三个真实标签校准、
真实摄影内容/格式分布、全部 SwiftUI 交互、端到端大容量图片 I/O 或发布包验收。
