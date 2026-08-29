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
    submitted_cleanup_requests = []
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
            nonlocal old_host_mode, cleanup_request
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
            if (path == "/v1/library-slimming/removals"
                    and route.request.method == "GET"):
                media_kind = parse_qs(urlparse(route.request.url).query).get(
                    "mediaKind", ["image"]
                )[0]
                await fulfill_json(route, {
                    "mediaKind": media_kind,
                    "requests": [],
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
                        "byteIdenticalGroupCount": 2,
                        "perfectVisualGroupCount": 2,
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
            if (path == "/v1/library-slimming/identical-cleanup/requests"
                    and route.request.method == "POST"):
                payload = route.request.post_data_json
                submitted_cleanup_requests.append(payload)
                cleanup_request = {
                    "id": REQUEST_ID,
                    "operationID": payload["operationID"],
                    "planID": payload["planID"],
                    "jobID": JOB_ID,
                    "mediaKind": "image",
                    "mode": payload["mode"],
                    "phase": "awaitingMac",
                    "executionStage": None,
                    "progress": None,
                    "audit": None,
                    "verification": None,
                    "message": "请回到 Mac 核对并确认一键清理方案",
                    "updatedAtMs": 1_700_000_050_000,
                }
                await fulfill_json(route, cleanup_request, status=202)
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
        await page.locator("#searchInput").focus()
        await page.evaluate("() => openSlimmingIdenticalCleanupDialog()")
        await page.locator("#slimmingIdenticalCleanupContent:not(.hidden)").wait_for()
        assert plan_requests[-1] == {"jobID": JOB_ID, "mediaKind": "image"}
        assert await page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "slimmingIdenticalCleanup"
        cleanup_history = await page.evaluate("() => JSON.stringify(history.state)")
        assert PLAN_ID not in cleanup_history
        assert "Apple Photos" not in cleanup_history

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
            == "普通保留 2 项；全组红心而安全跳过 3 项。红心资产不会进入自动删除计划。 原文件完全相同 2 组；视觉匹配 100% 2 组。"
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
        assert await page.locator("#slimmingIdenticalCleanupNotice > p").count() == 4
        assert "原文件字节并不完全相同" in await page.locator(
            "#slimmingIdenticalCleanupNotice"
        ).inner_text()
        assert "永久删除 3 个文件夹媒体" in await page.locator(
            "#slimmingIdenticalCleanupNotice"
        ).inner_text()
        await page.screenshot(
            path="/tmp/imageall-identical-cleanup-mac-parity.png",
            full_page=True,
        )
        await metrics.nth(0).hover()
        await page.locator("#cancelSlimmingIdenticalCleanupButton").focus()
        await page.evaluate(
            """() => {
              const dialog = document.querySelector("#slimmingIdenticalCleanupDialog");
              const label = dialog.querySelector(
                "[data-identical-cleanup-metric-key='verified'] "
                  + "[data-identical-cleanup-metric-part='label']"
              );
              const range = document.createRange();
              range.selectNodeContents(label);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const selectors = [
                "#slimmingIdenticalCleanupMetrics > *",
                "#slimmingIdenticalCleanupMetrics > * > *",
                "#slimmingIdenticalCleanupDispositionChart *",
                "#slimmingIdenticalCleanupGroupHistogram > *",
                "#slimmingIdenticalCleanupGroupHistogram > * > *",
                "#slimmingIdenticalCleanupSources > *",
                "#slimmingIdenticalCleanupSources > * > *",
                "#slimmingIdenticalCleanupNotice > *",
                "#slimmingIdenticalCleanupNotice > * > *",
              ];
              const nodes = selectors.map((selector) => [
                selector,
                [...dialog.querySelectorAll(selector)],
              ]);
              const structuralChanges = [];
              const observer = new MutationObserver((mutations) => {
                for (const mutation of mutations) {
                  const changed = [...mutation.addedNodes, ...mutation.removedNodes]
                    .some((node) => node.nodeType === Node.ELEMENT_NODE);
                  if (changed) structuralChanges.push(mutation.target);
                }
              });
              observer.observe(dialog, { childList: true, subtree: true });
              window.__identicalCleanupContinuity = {
                dialog,
                label,
                nodes,
                observer,
                structuralChanges,
                scrollTop: dialog.scrollTop,
              };
              state.slimming.identicalCleanup.submitting = true;
              renderSlimmingIdenticalCleanupDialog();
              state.slimming.identicalCleanup.submitting = false;
              renderSlimmingIdenticalCleanupDialog();
            }"""
        )
        stable_cleanup_plan = await page.evaluate(
            """() => {
              const frame = window.__identicalCleanupContinuity;
              frame.observer.disconnect();
              return {
                nodes: frame.nodes.every(([selector, nodes]) => {
                  const current = [...frame.dialog.querySelectorAll(selector)];
                  return current.length === nodes.length
                    && current.every((node, index) => node === nodes[index]);
                }),
                zeroStructuralChanges: frame.structuralChanges.length === 0,
                selection: window.getSelection()?.toString() === "已核验媒体",
                hover: frame.dialog.querySelector(
                  "[data-identical-cleanup-metric-key='verified']"
                )?.matches(":hover") === true,
                focus: document.activeElement?.id === "cancelSlimmingIdenticalCleanupButton",
                scroll: frame.dialog.scrollTop === frame.scrollTop,
              };
            }"""
        )
        assert all(stable_cleanup_plan.values()), stable_cleanup_plan
        await page.locator("#fastSlimmingIdenticalCleanupButton").focus()
        await page.go_back()
        await page.wait_for_function(
            "() => !document.querySelector('#slimmingIdenticalCleanupDialog').open"
        )
        assert await page.evaluate("() => document.activeElement?.id") == "searchInput"
        await page.go_forward()
        await page.locator("#slimmingIdenticalCleanupDialog[open]").wait_for()
        assert len(plan_requests) == 1
        assert await page.evaluate(
            "() => document.activeElement?.id"
        ) == "fastSlimmingIdenticalCleanupButton"
        await page.locator("#recoverableSlimmingIdenticalCleanupButton").click()
        await page.wait_for_function(
            "() => !document.querySelector('#slimmingIdenticalCleanupDialog').open"
        )
        assert len(submitted_cleanup_requests) == 1
        assert submitted_cleanup_requests[0]["planID"] == PLAN_ID
        assert submitted_cleanup_requests[0]["mode"] == "recoverableRecycle"
        assert submitted_cleanup_requests[0]["operationID"]
        assert await page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) != "slimmingIdenticalCleanup"
        assert await page.evaluate("() => document.activeElement?.id") == "searchInput"

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
        await page.wait_for_function(
            "() => !document.querySelector('#slimmingIdenticalCleanupDialog').open"
        )

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
            "message": "正在按红心保护与保留优先级逐组移入可恢复回收站…",
            "updatedAtMs": 1_700_000_050_200,
        })
        await page.evaluate(
            "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
        )
        assert await page.locator("#identicalCleanupBlockingTitle").inner_text() == "正在移入回收站"
        assert await page.locator("#identicalCleanupBlockingProgressLabel").inner_text() == "已处理 3 / 8 张"
        assert await page.locator("#identicalCleanupBlockingProgressBar").get_attribute("value") == "3"
        await page.evaluate(
            """() => {
              const status = document.querySelector("#slimmingRemovalStatus");
              window.__stableRunningRemovalStatus = {
                header: status.querySelector(".slimming-removal-status-header"),
                message: status.querySelector(".slimming-removal-status-header strong"),
                phase: status.querySelector(".slimming-removal-status-header .secondary"),
                progress: status.querySelector("progress"),
                blockingCard: document.querySelector("#identicalCleanupBlockingCard"),
              };
            }"""
        )
        cleanup_request.update({
            "progress": {
                **cleanup_request["progress"],
                "completedAssetCount": 6,
                "copiedBytes": 3072,
            },
            "message": "已安全处理 6/8 项，正在继续…",
            "updatedAtMs": 1_700_000_050_250,
        })
        await page.evaluate(
            "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
        )
        stable_running_status = await page.evaluate(
            """() => {
              const frame = window.__stableRunningRemovalStatus;
              const status = document.querySelector("#slimmingRemovalStatus");
              const progress = status.querySelector("progress");
              return {
                header: status.querySelector(".slimming-removal-status-header")
                  === frame.header,
                message: status.querySelector(".slimming-removal-status-header strong")
                  === frame.message,
                phase: status.querySelector(".slimming-removal-status-header .secondary")
                  === frame.phase,
                progress: progress === frame.progress,
                blockingCard: document.activeElement === frame.blockingCard,
                messageUpdated: frame.message.textContent
                  === "已安全处理 6/8 项，正在继续…",
                progressUpdated: progress.value === 6
                  && progress.getAttribute("aria-label") === "已完成 6/8 项",
              };
            }"""
        )
        assert all(stable_running_status.values()), stable_running_status
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
            "audit": {
                "hiddenAssetIDs": ["RECYCLE_0001"],
                "failedAssetIDs": ["RECYCLE_0002"],
                "authorizationRequiredAssetIDs": [],
                "authorizationDeniedPhotosAssetIDs": [],
            },
            "verification": {
                "isComplete": False,
                "verifiedGroupCount": 3,
                "targetGroupCount": 4,
                "targetRetainedAssetCount": 4,
                "currentAvailableAssetCount": 5,
                "unresolvedGroupCount": 1,
                "observedAssetCount": 12,
                "recycledRedundantAssetCount": 7,
                "remainingRedundantAssetCount": 1,
                "unresolvedAssetCount": 0,
            },
            "updatedAtMs": 1_700_000_051_000,
        })
        await page.evaluate(
            "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
        )
        assert not await page.locator("#identicalCleanupBlockingDialog").evaluate(
            "dialog => dialog.open"
        )
        await page.locator("#slimmingVerificationDialog[open]").wait_for()
        assert await page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "slimmingVerification"
        verification_history = await page.evaluate("() => JSON.stringify(history.state)")
        assert REQUEST_ID not in verification_history
        assert "RECYCLE_0002" not in verification_history
        assert "3 / 4" in await page.locator("#slimmingVerificationScore").inner_text()
        assert "目标是保留全部红心资产；没有红心时每组保留 1 项" in await page.locator(
            "#slimmingVerificationGoal"
        ).inner_text()
        assert "只把删除后确实仅剩 1 项" not in await page.locator(
            "#slimmingVerificationDialog"
        ).inner_text()
        await page.locator(
            "#slimmingVerificationMetrics "
            "[data-slimming-verification-metric-key='target']"
        ).hover()
        await page.locator("#closeSlimmingVerificationButton").focus()
        stable_verification = await page.evaluate(
            """() => {
              const dialog = document.querySelector("#slimmingVerificationDialog");
              const label = dialog.querySelector(
                "[data-slimming-verification-metric-key='target'] "
                  + "[data-slimming-verification-metric-part='title']"
              );
              const range = document.createRange();
              range.selectNodeContents(label);
              const selection = window.getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const selectors = [
                "#slimmingVerificationMetrics > *",
                "#slimmingVerificationMetrics > * > *",
                "#slimmingVerificationResult > *",
              ];
              const nodes = selectors.map((selector) => [
                selector,
                [...dialog.querySelectorAll(selector)],
              ]);
              const structuralChanges = [];
              const observer = new MutationObserver((mutations) => {
                for (const mutation of mutations) {
                  const changed = [...mutation.addedNodes, ...mutation.removedNodes]
                    .some((node) => node.nodeType === Node.ELEMENT_NODE);
                  if (changed) structuralChanges.push(mutation.target);
                }
              });
              observer.observe(dialog, { childList: true, subtree: true });
              const request = state.slimming.identicalCleanup.verificationRequest;
              Object.assign(request.verification, {
                isComplete: true,
                verifiedGroupCount: 4,
                currentAvailableAssetCount: 4,
                unresolvedGroupCount: 0,
                recycledRedundantAssetCount: 8,
                remainingRedundantAssetCount: 0,
              });
              renderSlimmingVerificationReport(request);
              const completeRendered = {
                score: document.querySelector("#slimmingVerificationScore").textContent,
                unresolved: dialog.querySelector(
                  "[data-slimming-verification-metric-key='unresolved'] strong"
                )?.textContent,
                heading: dialog.querySelector(
                  "[data-slimming-verification-result-key='heading']"
                )?.textContent,
              };
              Object.assign(request.verification, {
                isComplete: false,
                verifiedGroupCount: 3,
                currentAvailableAssetCount: 5,
                unresolvedGroupCount: 1,
                recycledRedundantAssetCount: 7,
                remainingRedundantAssetCount: 1,
              });
              renderSlimmingVerificationReport(request);
              observer.disconnect();
              return {
                nodes: nodes.every(([selector, stableNodes]) => {
                  const current = [...dialog.querySelectorAll(selector)];
                  return current.length === stableNodes.length
                    && current.every((node, index) => node === stableNodes[index]);
                }),
                zeroStructuralChanges: structuralChanges.length === 0,
                selection: window.getSelection()?.toString() === "目标保留",
                hover: dialog.querySelector(
                  "[data-slimming-verification-metric-key='target']"
                )?.matches(":hover") === true,
                focus: document.activeElement?.id === "closeSlimmingVerificationButton",
                completeScore: completeRendered.score.trim() === "4 / 4",
                completeUnresolved: completeRendered.unresolved === "0",
                completeHeading: completeRendered.heading === "核验完成",
                restoredScore: document.querySelector(
                  "#slimmingVerificationScore"
                ).textContent.trim() === "3 / 4",
              };
            }"""
        )
        assert all(stable_verification.values()), stable_verification
        await page.go_back()
        await page.wait_for_function(
            "() => !document.querySelector('#slimmingVerificationDialog').open"
        )
        await page.wait_for_function(
            "() => !state.workspaceNavigation.pendingReturnPromise"
        )
        assert await page.evaluate("() => document.activeElement?.id") == "searchInput"
        await page.go_forward()
        await page.locator("#slimmingVerificationDialog[open]").wait_for()
        assert "3 / 4" in await page.locator("#slimmingVerificationScore").inner_text()
        await page.keyboard.press("Escape")
        await page.wait_for_function(
            "() => !document.querySelector('#slimmingVerificationDialog').open"
        )
        await page.wait_for_function(
            "() => !state.workspaceNavigation.pendingReturnPromise"
        )
        assert await page.evaluate("() => document.activeElement?.id") == "searchInput"
        await page.evaluate(
            "() => new Promise(resolve => requestAnimationFrame("
            "() => requestAnimationFrame(resolve)))"
        )
        cleanup_request["updatedAtMs"] = await page.evaluate("() => Date.now()")
        await page.evaluate(
            """fixture => {
              document.querySelector("#slimmingWorkspace").classList.remove("hidden");
              syncSlimmingPresentation({ focus: false, renderSurfaces: false });
              state.slimming.selectedJobID = fixture.jobID;
              state.slimming.identicalCleanup.requests = [fixture.request];
              renderSlimmingRemovalStatus();
            }""",
            {"jobID": JOB_ID, "request": cleanup_request},
        )

        verification_button = page.locator(
            "#slimmingRemovalStatus [data-slimming-verification-request-id]"
        )
        await verification_button.focus()
        assert await page.evaluate(
            "() => document.activeElement?.hasAttribute("
            "'data-slimming-verification-request-id')"
        )
        await page.evaluate(
            """() => {
              const status = document.querySelector("#slimmingRemovalStatus");
              window.__stableSlimmingRemovalStatus = {
                header: status.querySelector(".slimming-removal-status-header"),
                message: status.querySelector(".slimming-removal-status-header strong"),
                phase: status.querySelector(".slimming-removal-status-header .secondary"),
                audit: status.querySelectorAll(".slimming-removal-audit")[0],
                verification: status.querySelectorAll(".slimming-removal-audit")[1],
                report: status.querySelector(
                  "[data-slimming-verification-request-id]"
                ),
              };
            }"""
        )
        cleanup_request.update({
            "message": "已在 Mac 上取消；核验数据已刷新",
            "verification": {
                **cleanup_request["verification"],
                "isComplete": True,
                "verifiedGroupCount": 4,
                "currentAvailableAssetCount": 4,
                "unresolvedGroupCount": 0,
                "recycledRedundantAssetCount": 8,
                "remainingRedundantAssetCount": 0,
            },
            "audit": {
                **cleanup_request["audit"],
                "hiddenAssetIDs": ["RECYCLE_0001", "RECYCLE_0002"],
                "failedAssetIDs": [],
            },
            "updatedAtMs": cleanup_request["updatedAtMs"] + 100,
        })
        await page.evaluate(
            "() => loadSlimmingIdenticalCleanupRequests({ quiet: true })"
        )
        stable_removal_status = await page.evaluate(
            """() => {
              const frame = window.__stableSlimmingRemovalStatus;
              const status = document.querySelector("#slimmingRemovalStatus");
              return {
                header: status.querySelector(".slimming-removal-status-header")
                  === frame.header,
                message: status.querySelector(".slimming-removal-status-header strong")
                  === frame.message,
                phase: status.querySelector(".slimming-removal-status-header .secondary")
                  === frame.phase,
                audit: status.querySelectorAll(".slimming-removal-audit")[0]
                  === frame.audit,
                verification: status.querySelectorAll(".slimming-removal-audit")[1]
                  === frame.verification,
                report: status.querySelector(
                  "[data-slimming-verification-request-id]"
                ) === frame.report,
                focus: document.activeElement === frame.report,
                messageUpdated: frame.message.textContent
                  === "已在 Mac 上取消；核验数据已刷新",
                auditUpdated: frame.audit.textContent
                  === "已从候选结果隐藏 2 项",
                verificationUpdated: frame.verification.textContent.includes("4/4"),
              };
            }"""
        )
        assert all(stable_removal_status.values()), stable_removal_status
        await verification_button.click()
        await page.locator("#slimmingVerificationDialog[open]").wait_for()
        assert "4 / 4" in await page.locator("#slimmingVerificationScore").inner_text()
        await page.keyboard.press("Escape")
        await page.wait_for_function(
            "() => !document.querySelector('#slimmingVerificationDialog').open"
        )

        cleanup_request.update({
            "verification": None,
            "verificationUnavailableMessage": (
                "删除动作已经结束，但无法读取删除后的实际资产状态：合成核验读取失败"
            ),
            "message": "删除动作已经结束，但删除后核验未完成；未显示未经证实的保留数量",
            "updatedAtMs": cleanup_request["updatedAtMs"] + 100,
        })
        await page.evaluate(
            """fixture => {
              document.querySelector("#slimmingWorkspace").classList.remove("hidden");
              syncSlimmingPresentation({ focus: false, renderSurfaces: false });
              state.slimming.identicalCleanup.requests = [fixture];
              renderSlimmingRemovalStatus();
            }""",
            cleanup_request,
        )
        unavailable_button = page.locator(
            "#slimmingRemovalStatus [data-slimming-verification-request-id]"
        )
        assert await unavailable_button.inner_text() == "查看核验说明"
        assert "实际资产状态尚未完成独立核验" in await page.locator(
            "#slimmingRemovalStatus"
        ).inner_text()
        await unavailable_button.click()
        await page.locator("#slimmingVerificationDialog[open]").wait_for()
        assert await page.locator("#slimmingVerificationTitle").inner_text() == "删除后核验未完成"
        assert await page.locator("#slimmingVerificationScoreSection").evaluate(
            "node => node.classList.contains('hidden')"
        )
        assert await page.locator("#slimmingVerificationMetrics").evaluate(
            "node => node.classList.contains('hidden')"
        )
        unavailable_report = await page.locator("#slimmingVerificationDialog").inner_text()
        assert "未显示未经证实的保留数量" in unavailable_report
        assert "合成核验读取失败" in unavailable_report
        assert "不会用删除前计划值代替结果" in unavailable_report
        assert "目标保留" not in unavailable_report
        assert await page.evaluate(
            "() => document.documentElement.scrollWidth <= document.documentElement.clientWidth"
        )
        await page.screenshot(
            path="/tmp/imageall-identical-cleanup-verification-unavailable-390.png",
            full_page=True,
        )
        await page.keyboard.press("Escape")
        await page.wait_for_function(
            "() => !document.querySelector('#slimmingVerificationDialog').open"
        )

        assert len(plan_requests) == 2
        assert page_errors == [], page_errors
        assert resource_errors == [], resource_errors
        assert console_errors == [], console_errors
        await browser.close()

    print("identical cleanup Mac-parity browser regression passed")


if __name__ == "__main__":
    asyncio.run(main())
