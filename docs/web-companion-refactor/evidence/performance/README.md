# 10k 图库性能证据

## 固定环境

- 构建：Vite production build，Chrome 151.0.7922.174。
- 主机：Apple M4 Mac mini，16 GB；视口 1440×960。
- fixture：10,000 条确定性合成资产，契约 SHA-256
  `0db043e9e228ff18deaa183a280c69b6ed05257bdbc1c388608e27042f8c34cc`。
- 命令：`npx playwright test tests/e2e/performance.spec.ts --project=chromium-desktop`。

## 2026-08-31 结果

| 指标 | 实测 | 门槛 |
| --- | ---: | ---: |
| route 可选择首卡 | 1,131 ms | < 1,500 ms |
| DOM 节点 | 512 | < 2,500 |
| asset card DOM | 24 | < 300 |
| 选择反馈 p95 | 28.8 ms | < 100 ms |
| viewer 打开 p95 | 153.1 ms | < 250 ms |
| >50 ms 长任务 | 0 | ≤ 3 |
| 返回 anchor 偏差 | 0 px | < 一行 |

缩略图加载器另有单元回归证明最大并发 6、相同 URL 合并、离屏释放后取消未完成请求，完成项在
5 秒短暂复用后释放 object URL。viewer 只预取相邻两项；关闭后由浏览器管理的普通媒体请求不写入
Cache Storage。

## 声明边界

这是同机本地合成 Host 响应的交互基准，不代表真实网络、真实磁盘解码速度或 10,000 张真实照片的
视觉正确性。自动化没有读取、遍历或写入 HDD2 受保护路径。
