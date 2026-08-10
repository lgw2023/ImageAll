#!/usr/bin/env python3
import asyncio
import json
from urllib.parse import parse_qs, urlparse

from playwright.async_api import async_playwright


BASE_URL = "http://127.0.0.1:8808"
JOB_ID = "44444444-4444-4444-4444-444444444444"
PLAN_ID = "77777777-4444-4444-4444-444444444444"
REQUEST_ID = "88888888-4444-4444-4444-444444444444"


async def main():
    plan_requests = []
    old_host_mode = False
    cleanup_request = None
    page_errors = []
    console_errors = []
    resource_errors = []

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        context = await browser.new_context(
            viewport={"width": 1440, "height": 960},
            service_workers="block",
        )
        await context.add_init_script(
            """
            class QuietWebSocket extends EventTarget { send() {} close() {} }
            Object.defineProperty(globalThis, "WebSocket", { value: QuietWebSocket });
            """
        )
        page = await context.new_page()
        page.on(
            "console",
            lambda message: console_errors.append(message.text)
            if message.type == "error" else None,
        )
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        page.on(
            "response",
            lambda response: resource_errors.append((response.status, response.url))
            if response.status >= 400 else None,
        )

        async def fulfill_json(route, payload, status=200):
            await route.fulfill(
                status=status,
                content_type="application/json; charset=utf-8",
                body=json.dumps(payload, ensure_ascii=False),
            )

        async def route_api(route):
            nonlocal old_host_mode
            path = urlparse(route.request.url).path
            if path == "/v1/capabilities":
                await fulfill_json(route, {
                    "protocolVersion": 2,
                    "hostAppVersion": "test",
                    "capabilities": ["librarySlimming"],
                })
                return
            if path in {"/v1/sources", "/v1/tags", "/v1/tag-groups", "/v1/jobs"}:
                await fulfill_json(route, [])
                return
            if path == "/v1/assets":
                await fulfill_json(route, {"items": [], "nextCursor": None})
                return
            if path == "/v1/embedding-preparation":
                await fulfill_json(route, {
                    "mediaKind": "image", "isAvailable": False, "activities": [],
                })
                return
            if path == "/v1/sample-suggestions":
                await fulfill_json(route, {
                    "mediaKind": "image",
                    "isAvailable": False,
                    "maximumSampleCount": 500,
                    "activities": [],
                })
                return
            if path == "/v1/tag-library-suggestions":
                await fulfill_json(route, {
                    "mediaKind": "image",
                    "maximumPendingCount": 500,
                    "personalCentroidAvailable": False,
                    "personalAdamWAvailable": False,
                    "tags": [],
                    "activities": [],
                })
                return
            if path == "/v1/library-slimming/identical-cleanup/plans":
                payload = route.request.post_data_json
                plan_requests.append(payload)
                plan = {
                    "id": PLAN_ID,
                    "jobID": payload["jobID"],
                    "mediaKind": payload["mediaKind"],
                    "groupCount": 4,
                    "verifiedAssetCount": 12,
                    "retainedAssetCount": 4,
                    "removalAssetCount": 8,
                    "skippedGroupCount": 2,
                    "photosAssetCount": 5,
                    "fileAssetCount": 3,
                    "groupSizeHistogram": {"2": 2, "3": 1, "7": 1},
                    "preparedAtMs": 1_700_000_040_000,
                }
                if not old_host_mode:
                    plan.update({
                        "favoriteRetainedAssetCount": 2,
                        "ordinaryRetainedAssetCount": 2,
                        "protectedSkippedAssetCount": 3,
                    })
                await fulfill_json(route, plan)
                return
            if (path == "/v1/library-slimming/identical-cleanup/requests"
                    and route.request.method == "GET"):
                media_kind = parse_qs(urlparse(route.request.url).query).get(
                    "mediaKind", ["image"]
                )[0]
                requests = []
                if cleanup_request and cleanup_request["mediaKind"] == media_kind:
                    requests.append(cleanup_request)
                await fulfill_json(route, {
                    "mediaKind": media_kind,
                    "requests": requests,
                })
                return
            await fulfill_json(route, {"code": "notFound", "message": path}, status=404)

        await page.route("**/favicon.ico", lambda route: route.fulfill(status=204, body=""))
        await page.route(
            "**/world-map/index.html",
            lambda route: route.fulfill(
                status=200,
                content_type="text/html; charset=utf-8",
                body="<!doctype html><title>合成照片世界</title>",
            ),
        )
        await page.route(
            "**/web/session",
            lambda route: fulfill_json(route, {
                "authenticated": True,
                "authMode": "pairedDevice",
                "deviceName": "合成浏览器",
            }),
        )
        await page.route("**/v1/**", route_api)
        await page.goto(BASE_URL, wait_until="networkidle")

        await page.evaluate(
            """jobID => {
              state.slimming.selectedJobID = jobID;
              state.slimming.mediaKind = "image";
            }""",
            JOB_ID,
        )
        await page.evaluate("() => openSlimmingIdenticalCleanupDialog()")
        await page.locator("#slimmingIdenticalCleanupContent:not(.hidden)").wait_for()
        assert plan_requests[-1] == {"jobID": JOB_ID, "mediaKind": "image"}

        metrics = page.locator(
            "#slimmingIdenticalCleanupMetrics > .identical-cleanup-metric"
        )
        assert await metrics.count() == 5
        assert (await metrics.nth(0).inner_text()).splitlines()[-1] == "12"
        assert (await metrics.nth(2).inner_text()).splitlines()[-1] == "2"
        assert (await metrics.nth(2).get_attribute("class")).endswith("red")
        assert (await metrics.nth(3).inner_text()).splitlines()[-1] == "8"
        assert (
            await page.locator("#slimmingIdenticalCleanupRetentionSummary").inner_text()
            == "普通保留 2 项；全组红心而安全跳过 3 项。红心资产不会进入自动删除计划。"
        )
        assert (
            await page.locator("#slimmingIdenticalCleanupDispositionChart").get_attribute(
                "aria-label"
            )
            == "去留比例：已核验 12 张，保留 4 张，清理 8 张"
        )
        histogram = page.locator("#slimmingIdenticalCleanupGroupHistogram")
        assert await histogram.locator(".identical-cleanup-histogram-column").count() == 3
        assert "每组 5+ 项有 1 组" in await histogram.get_attribute("aria-label")
        sources = page.locator("#slimmingIdenticalCleanupSources")
        assert await sources.locator(".identical-cleanup-source-row").count() == 2
        assert "Apple Photos 5 张" in await sources.get_attribute("aria-label")
        assert await page.locator("#slimmingIdenticalCleanupNotice > p").count() == 3
        assert "永久删除 3 个文件夹媒体" in await page.locator(
            "#slimmingIdenticalCleanupNotice"
        ).inner_text()
        await page.screenshot(
            path="/tmp/imageall-identical-cleanup-mac-parity.png",
            full_page=True,
        )
        await page.locator("#cancelSlimmingIdenticalCleanupButton").click()

        old_host_mode = True
        await page.set_viewport_size({"width": 390, "height": 844})
        await page.evaluate("() => openSlimmingIdenticalCleanupDialog()")
        await page.locator("#slimmingIdenticalCleanupContent:not(.hidden)").wait_for()
        assert "当前 Mac Host 未提供红心保护拆分" in await page.locator(
            "#slimmingIdenticalCleanupRetentionSummary"
        ).inner_text()
        assert (await metrics.nth(2).inner_text()).splitlines()[-1] == "—"
        assert await page.evaluate(
            "() => document.documentElement.scrollWidth <= document.documentElement.clientWidth"
        )
        dialog_bounds = await page.locator("#slimmingIdenticalCleanupDialog").bounding_box()
        assert dialog_bounds is not None
        assert dialog_bounds["x"] >= 0 and dialog_bounds["x"] + dialog_bounds["width"] <= 390
        for selector in [
            "#cancelSlimmingIdenticalCleanupButton",
            "#recoverableSlimmingIdenticalCleanupButton",
            "#fastSlimmingIdenticalCleanupButton",
        ]:
            bounds = await page.locator(selector).bounding_box()
            assert bounds is not None
            assert bounds["x"] >= 0 and bounds["x"] + bounds["width"] <= 390
            assert bounds["y"] >= 0 and bounds["y"] + bounds["height"] <= 844
        await page.screenshot(
            path="/tmp/imageall-identical-cleanup-mac-parity-390.png",
            full_page=True,
        )
        await page.locator("#cancelSlimmingIdenticalCleanupButton").click()

        await page.set_viewport_size({"width": 1440, "height": 960})
        await page.locator("#searchInput").focus()
        cleanup_request = {
            "id": REQUEST_ID,
            "operationID": "99999999-4444-4444-4444-444444444444",
            "planID": PLAN_ID,
            "jobID": JOB_ID,
            "mediaKind": "image",
            "mode": "recoverableRecycle",
            "phase": "awaitingMac",
            "executionStage": None,
            "progress": None,
            "audit": None,
            "verification": None,
            "message": "请回到 Mac 核对并确认一键清理方案",
            "updatedAtMs": 1_700_000_050_000,
        }
        await page.evaluate(
            "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
        )
        assert not await page.locator("#identicalCleanupBlockingDialog").evaluate(
            "dialog => dialog.open"
        )

        cleanup_request.update({
            "phase": "running",
            "executionStage": "validatingPlan",
            "message": "正在重新核验冻结方案…",
            "updatedAtMs": 1_700_000_050_100,
        })
        await page.evaluate(
            "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
        )
        await page.locator("#identicalCleanupBlockingDialog[open]").wait_for()
        assert await page.locator("#identicalCleanupBlockingTitle").inner_text() == "正在复核清理方案"
        await page.keyboard.press("Meta+k")
        assert not await page.locator("#commandPalette").evaluate("dialog => dialog.open")

        cleanup_request.update({
            "executionStage": "recyclingAssets",
            "progress": {
                "phase": "copying",
                "completedAssetCount": 3,
                "totalAssetCount": 8,
                "copiedBytes": 1024,
                "totalFileBytes": 4096,
            },
            "message": "正在逐组保留一项并移入可恢复回收站…",
            "updatedAtMs": 1_700_000_050_200,
        })
        await page.evaluate(
            "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
        )
        assert await page.locator("#identicalCleanupBlockingTitle").inner_text() == "正在移入回收站"
        assert await page.locator("#identicalCleanupBlockingProgressLabel").inner_text() == "已处理 3 / 8 张"
        assert await page.locator("#identicalCleanupBlockingProgressBar").get_attribute("value") == "3"
        await page.screenshot(
            path="/tmp/imageall-identical-cleanup-blocking.png",
            full_page=True,
        )

        expected_stages = [
            ("requestingAuthorization", "正在等待系统授权"),
            ("refreshingState", "正在刷新删除状态"),
            ("verifyingResult", "正在进行删除后核验"),
        ]
        for index, (stage, title) in enumerate(expected_stages, start=3):
            cleanup_request.update({
                "executionStage": stage,
                "progress": None,
                "updatedAtMs": 1_700_000_050_000 + index * 100,
            })
            await page.evaluate(
                "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
            )
            assert await page.locator("#identicalCleanupBlockingTitle").inner_text() == title

        await page.set_viewport_size({"width": 390, "height": 844})
        bounds = await page.locator("#identicalCleanupBlockingCard").bounding_box()
        assert bounds is not None
        assert bounds["x"] >= 8 and bounds["x"] + bounds["width"] <= 382
        assert bounds["y"] >= 8 and bounds["y"] + bounds["height"] <= 836
        assert await page.evaluate(
            "() => document.documentElement.scrollWidth <= document.documentElement.clientWidth"
        )
        await page.screenshot(
            path="/tmp/imageall-identical-cleanup-blocking-390.png",
            full_page=True,
        )

        cleanup_request.update({
            "phase": "cancelled",
            "message": "已在 Mac 上取消一键清理",
            "updatedAtMs": 1_700_000_051_000,
        })
        await page.evaluate(
            "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
        )
        assert not await page.locator("#identicalCleanupBlockingDialog").evaluate(
            "dialog => dialog.open"
        )
        assert await page.evaluate("() => document.activeElement?.id") == "searchInput"

        assert len(plan_requests) == 2
        assert page_errors == [], page_errors
        assert resource_errors == [], resource_errors
        assert console_errors == [], console_errors
        await browser.close()

    print("identical cleanup Mac-parity browser regression passed")


if __name__ == "__main__":
    asyncio.run(main())
