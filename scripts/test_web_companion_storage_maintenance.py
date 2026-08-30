#!/usr/bin/env python3
import json
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8801"
SOURCE_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
REQUEST_ID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"


def historical_request(index):
    phases = ["completed", "failed", "cancelled"]
    phase = phases[index % len(phases)]
    return {
        "id": f"dddddddd-1111-2222-3333-{index:012d}",
        "operationID": f"eeeeeeee-1111-2222-3333-{index:012d}",
        "action": "exportPortableData" if index % 2 == 0 else "clearPreviewCache",
        "phase": phase,
        "message": f"合成存储操作 {index + 1} 已记录",
        "updatedAtMs": 1_699_999_999_000 - index * 1_000,
    }


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def main():
    submitted_actions = []
    active_request = None
    storage_reads_after_submit = 0
    storage_reads = 0
    page_errors = []
    console_errors = []
    failed_resources = []
    historical_requests = [historical_request(index) for index in range(8)]

    def storage_snapshot():
        requests = ([] if active_request is None else [active_request]) + historical_requests
        return {
            "previewCache": {"entryCount": 24, "registeredBytes": 1_500_000},
            "photosOriginals": {"entryCount": 3, "registeredBytes": 9_000_000},
            "appStorage": {
                "kind": "internalStorage",
                "requiresRestart": True,
                "pendingExternalRootName": "ImageAll-External",
            },
            "requests": requests,
        }

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True,
            executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        context = browser.new_context(
            viewport={"width": 1440, "height": 960},
            service_workers="block",
        )
        context.add_init_script(
            """
            class QuietWebSocket extends EventTarget { send() {} close() {} }
            Object.defineProperty(globalThis, "WebSocket", { value: QuietWebSocket });
            """
        )
        page = context.new_page()
        page.on(
            "console",
            lambda message: console_errors.append(message.text)
            if message.type == "error" else None,
        )
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        page.on(
            "response",
            lambda response: failed_resources.append((response.status, response.url))
            if response.status >= 400 else None,
        )
        page.route("**/favicon.ico", lambda route: route.fulfill(status=204, body=""))
        page.route(
            "**/world-map/index.html",
            lambda route: route.fulfill(
                status=200,
                content_type="text/html; charset=utf-8",
                body="<!doctype html><title>Map test shell</title>",
            ),
        )
        page.route(
            "**/web/session",
            lambda route: fulfill_json(
                route,
                {"authenticated": True, "authMode": "pairedDevice", "deviceName": "Synthetic Browser"},
            ),
        )
        page.route(
            "**/v1/capabilities",
            lambda route: fulfill_json(
                route,
                {
                    "protocolVersion": 1,
                    "hostID": "cccccccc-1111-2222-3333-cccccccccccc",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                },
            ),
        )
        sources = [{
            "id": SOURCE_ID,
            "kind": "photos",
            "displayName": "Apple Photos",
            "state": "active",
        }]
        page.route("**/v1/sources", lambda route: fulfill_json(route, sources))
        page.route("**/v1/tags", lambda route: fulfill_json(route, []))
        page.route("**/v1/tag-groups", lambda route: fulfill_json(route, []))
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
        page.route(
            "**/v1/embedding-preparation?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "isAvailable": True, "activities": []}),
        )
        page.route(
            "**/v1/sample-suggestions?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "isAvailable": True, "maximumSampleCount": 500, "activities": []}),
        )
        page.route(
            "**/v1/tag-library-suggestions?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "maximumPendingCount": 500, "personalCentroidAvailable": False, "personalAdamWAvailable": False, "tags": [], "activities": []}),
        )
        page.route(
            "**/v1/assets?**",
            lambda route: fulfill_json(route, {"items": [], "nextCursor": None}),
        )

        def route_storage_snapshot(route):
            nonlocal storage_reads_after_submit, storage_reads, active_request
            storage_reads += 1
            if active_request is not None:
                storage_reads_after_submit += 1
                completion_threshold = (
                    2 if active_request["action"] == "exportPortableData" else 1
                )
                if storage_reads_after_submit >= completion_threshold:
                    completed_messages = {
                        "exportPortableData": "已导出 42 条记录到“ImageAll-Export-Test”",
                        "clearPreviewCache": "已清理 24 条可重建预览缓存",
                        "clearPhotosOriginals": "已清理 3 条 ImageAll Photos 原图副本",
                    }
                    active_request = {
                        **active_request,
                        "phase": "completed",
                        "message": completed_messages.get(
                            active_request["action"],
                            "Mac 存储操作已完成",
                        ),
                        "updatedAtMs": 1_700_000_001_000,
                        "result": {
                            "bundleName": "ImageAll-Export-Test",
                            "totalRecordCount": 42,
                        },
                    }
            fulfill_json(route, storage_snapshot())

        def route_storage_submit(route):
            nonlocal active_request, storage_reads_after_submit
            payload = route.request.post_data_json
            submitted_actions.append(payload)
            storage_reads_after_submit = 0
            awaiting_messages = {
                "exportPortableData": "请回到 Mac 选择用户数据导出位置",
                "clearPreviewCache": "等待 Mac 最终确认清理预览缓存",
                "clearPhotosOriginals": "等待 Mac 最终确认清理长期原图副本",
            }
            active_request = {
                "id": REQUEST_ID,
                "operationID": payload["operationID"],
                "action": payload["action"],
                "phase": "awaitingMac",
                "message": awaiting_messages.get(payload["action"], "等待 Mac 完成操作"),
                "updatedAtMs": 1_700_000_000_000,
            }
            fulfill_json(route, active_request, status=202)

        page.route("**/v1/storage-maintenance", route_storage_snapshot)
        page.route("**/v1/storage-maintenance/requests", route_storage_submit)

        page.goto(BASE_URL, wait_until="networkidle")
        storage_history_length = page.evaluate("() => history.length")
        page.locator("#storageButton").click()
        page.locator("#storageContent:not(.hidden)").wait_for()
        assert page.evaluate("() => history.length") in {
            storage_history_length,
            storage_history_length + 1,
        }
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "storageMaintenance"
        storage_reads_after_open = storage_reads
        page.evaluate("() => history.back()")
        page.locator("#storageDialog").wait_for(state="hidden")
        page.wait_for_function("() => document.activeElement?.id === 'storageButton'")
        page.evaluate("() => history.forward()")
        page.locator("#storageDialog[open]").wait_for()
        assert storage_reads == storage_reads_after_open
        assert page.locator("#previewCacheSize").inner_text() == "1.5 MB"
        assert "24 条" in page.locator("#previewCacheEntries").inner_text()
        assert page.locator("#photosOriginalsSize").inner_text() == "9 MB"
        assert page.locator("#appStorageKind").inner_text() == "Mac 内置存储"
        assert "ImageAll-External" in page.locator("#appStorageDetail").inner_text()
        assert "/Volumes/" not in page.locator("#storageDialog").inner_text()

        page.evaluate(
            """
            () => {
              const content = document.querySelector("#storageContent");
              content.scrollTop = content.scrollHeight;
              document.querySelector("#chooseExternalStorageButton")
                .focus({ preventScroll: true });
            }
            """
        )
        page.wait_for_timeout(150)
        storage_history_context = page.evaluate(
            "() => history.state?.imageAllWorkspace?.context"
        )
        assert storage_history_context["storageFocusID"] == "chooseExternalStorageButton"
        assert storage_history_context["storageScrollTop"] > 0
        assert storage_history_context["storageReturnControlID"] == "storageButton"
        serialized_storage_context = json.dumps(
            storage_history_context,
            ensure_ascii=False,
        )
        assert "ImageAll-External" not in serialized_storage_context
        assert "合成存储操作" not in serialized_storage_context
        assert "dddddddd" not in serialized_storage_context

        saved_storage_scroll = storage_history_context["storageScrollTop"]
        storage_reads_before_reload = storage_reads
        page.reload(wait_until="networkidle")
        page.locator("#storageDialog[open]").wait_for()
        page.locator("#storageContent:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'chooseExternalStorageButton'"
        )
        assert storage_reads == storage_reads_before_reload + 1
        restored_storage_scroll = page.evaluate(
            """
            () => {
              const content = document.querySelector("#storageContent");
              return {
                actual: content.scrollTop,
                maximum: Math.max(0, content.scrollHeight - content.clientHeight),
              };
            }
            """
        )
        assert restored_storage_scroll["actual"] == min(
            saved_storage_scroll,
            restored_storage_scroll["maximum"],
        )
        page.screenshot(
            path="/tmp/imageall-storage-history-restored.png",
            full_page=True,
        )

        page.evaluate(
            """
            () => {
              const workspace = structuredClone(history.state.imageAllWorkspace);
              workspace.context.storageFocusID = "appStorageDetail";
              workspace.context.storageScrollTop = -42;
              workspace.context.storageReturnControlID = "appStorageKind";
              history.replaceState({
                ...history.state,
                imageAllWorkspace: workspace,
              }, "", location.href);
            }
            """
        )
        storage_reads_before_invalid_reload = storage_reads
        page.reload(wait_until="networkidle")
        page.locator("#storageDialog[open]").wait_for()
        page.locator("#storageContent:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'storageRefreshButton'"
        )
        assert storage_reads == storage_reads_before_invalid_reload + 1
        normalized_storage_context = page.evaluate(
            "() => history.state?.imageAllWorkspace?.context"
        )
        assert normalized_storage_context["storageFocusID"] == "storageRefreshButton"
        assert normalized_storage_context["storageScrollTop"] == 0
        assert normalized_storage_context["storageReturnControlID"] is None
        assert "appStorageDetail" not in json.dumps(normalized_storage_context)
        assert "appStorageKind" not in json.dumps(normalized_storage_context)

        storage_reads_before_history_round_trip = storage_reads
        page.evaluate("() => history.back()")
        page.locator("#storageDialog").wait_for(state="hidden")
        page.wait_for_function("() => document.activeElement?.id === 'storageButton'")
        page.evaluate("() => history.forward()")
        page.locator("#storageDialog[open]").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'storageRefreshButton'"
        )
        assert storage_reads == storage_reads_before_history_round_trip

        page.evaluate(
            """
            () => {
              const originalFetch = window.fetch.bind(window);
              window.__storageRefreshRelease = null;
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/storage-maintenance") return originalFetch(input, init);
                return new Promise((resolve, reject) => {
                  window.__storageRefreshRelease = () => {
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  };
                });
              };
              const content = document.querySelector("#storageContent");
              content.scrollTop = content.scrollHeight;
            }
            """
        )
        page.locator("#storageRefreshButton").focus()
        page.locator(".storage-history-row").first.hover()
        page.evaluate(
            """
            () => {
              const content = document.querySelector("#storageContent");
              const row = document.querySelector(".storage-history-row");
              const textNode = row?.querySelector(".storage-history-message")?.firstChild;
              const range = document.createRange();
              range.selectNodeContents(textNode);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              window.__storageStableFrame = {
                row,
                mark: row?.querySelector(".storage-history-mark"),
                message: row?.querySelector(".storage-history-message"),
                textNode,
                selectedText: selection.toString(),
                time: row?.querySelector("small"),
                scrollTop: content.scrollTop,
              };
            }
            """
        )
        page.keyboard.press("Enter")
        page.wait_for_function("() => Boolean(window.__storageRefreshRelease)")
        pending_continuity = page.evaluate(
            """
            () => {
              const frame = window.__storageStableFrame;
              const row = document.querySelector(".storage-history-row");
              return {
                row: frame.row === row,
                mark: frame.mark === row?.querySelector(".storage-history-mark"),
                message: frame.message === row?.querySelector(".storage-history-message"),
                selection: getSelection().anchorNode === frame.textNode
                  && getSelection().toString() === frame.selectedText,
                time: frame.time === row?.querySelector("small"),
                hover: row.matches(":hover"),
                scroll: document.querySelector("#storageContent").scrollTop === frame.scrollTop,
              };
            }
            """
        )
        assert all(pending_continuity.values()), pending_continuity
        page.evaluate("() => window.__storageRefreshRelease()")
        page.wait_for_function("() => !document.querySelector('#storageRefreshButton').disabled")
        assert page.evaluate(
            """
            () => {
              const frame = window.__storageStableFrame;
              const row = document.querySelector(".storage-history-row");
              return frame.row === row
                && frame.mark === row?.querySelector(".storage-history-mark")
                && frame.message === row?.querySelector(".storage-history-message")
                && getSelection().anchorNode === frame.textNode
                && getSelection().toString() === frame.selectedText
                && frame.time === row?.querySelector("small")
                && row.matches(":hover")
                && document.activeElement?.id === "storageRefreshButton"
                && document.querySelector("#storageContent").scrollTop === frame.scrollTop;
            }
            """
        ), "unchanged storage refresh replaced the visible history row"

        page.evaluate(
            """
            () => {
              const rows = [...document.querySelectorAll(".storage-history-row")];
              const existing = rows.find((row) =>
                row.querySelector(".storage-history-message")?.textContent
                  === "合成存储操作 1 已记录"
              );
              window.__storageHistoryShiftFrame = {
                existing,
                mark: existing?.querySelector(".storage-history-mark"),
                message: existing?.querySelector(".storage-history-message"),
                time: existing?.querySelector("small"),
                evicted: rows.at(-1),
              };
            }
            """
        )

        page.locator("#exportPortableDataButton").click()
        page.locator("#storagePending:not(.hidden)").wait_for()
        assert submitted_actions[-1]["action"] == "exportPortableData"
        assert page.locator("#storageStatusLabel").inner_text() == "等待 Mac"
        assert page.locator("#storageButton").get_attribute("aria-busy") == "true"
        assert page.evaluate(
            """
            () => {
              const frame = window.__storageHistoryShiftFrame;
              const active = [...document.querySelectorAll(".storage-history-row")].find((row) =>
                row.querySelector(".storage-history-message")?.textContent
                  === "请回到 Mac 选择用户数据导出位置"
              );
              window.__storageActiveHistoryFrame = {
                row: active,
                mark: active?.querySelector(".storage-history-mark"),
                message: active?.querySelector(".storage-history-message"),
                time: active?.querySelector("small"),
              };
              return Boolean(active)
                && frame.existing?.isConnected
                && frame.mark === frame.existing.querySelector(".storage-history-mark")
                && frame.message === frame.existing.querySelector(".storage-history-message")
                && frame.time === frame.existing.querySelector("small")
                && !frame.evicted?.isConnected;
            }
            """
        ), "inserting a new storage request rebuilt an existing history row"
        page.locator("#storageCloseButton").click()
        page.locator("#storageDialog").wait_for(state="hidden")
        page.wait_for_function("() => document.activeElement?.id === 'storageButton'")
        assert page.locator("#storageStatusLabel").inner_text() == "等待 Mac"
        page.screenshot(
            path="/tmp/imageall-storage-background-status.png",
            full_page=True,
        )
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('已导出 42 条记录')",
            timeout=5_000,
        )
        assert page.locator("#storageStatusLabel").inner_text() == "预览缓存"
        assert page.locator("#storageButton").get_attribute("aria-busy") == "false"
        page.locator("#storageButton").click()
        assert page.locator("#storageContent").is_visible()
        assert page.locator("#storageHistory").get_by_text("已导出 42 条记录").is_visible()
        assert page.evaluate(
            """
            () => {
              const frame = window.__storageActiveHistoryFrame;
              const row = [...document.querySelectorAll(".storage-history-row")].find((candidate) =>
                candidate.querySelector(".storage-history-message")?.textContent
                  .includes("已导出 42 条记录")
              );
              return frame.row === row
                && frame.mark === row?.querySelector(".storage-history-mark")
                && frame.message === row?.querySelector(".storage-history-message")
                && frame.time === row?.querySelector("small")
                && row?.dataset.phase === "completed";
            }
            """
        ), "storage request phase change replaced its history row"
        page.locator("#storageContent:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#storageHistory').textContent.includes('已导出 42 条记录')"
        )
        assert page.locator("#storagePending").is_hidden()

        preview_request_count = len(submitted_actions)
        page.locator("#clearPreviewCacheButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "confirmation"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.confirmationBaseLevel"
        ) == "storageMaintenance"
        storage_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "ImageAll-External" not in storage_history_payload
        assert "清理预览缓存" not in storage_history_payload
        assert page.locator("#confirmDialogTitle").inner_text() == "清理预览缓存？"
        assert "不会删除原照片、人工标签" in page.locator(
            "#confirmDialogMessage"
        ).inner_text()
        assert page.locator("#confirmActionButton").inner_text() == "清理预览缓存"
        page.keyboard.press("Escape")
        page.locator("#confirmDialog").wait_for(state="hidden")
        assert page.locator("#storageDialog").is_visible()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "storageMaintenance"
        assert len(submitted_actions) == preview_request_count
        page.wait_for_function(
            "() => document.activeElement?.id === 'clearPreviewCacheButton'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#cancelConfirmButton").click()
        page.locator("#confirmDialog").wait_for(state="hidden")
        assert page.locator("#storageDialog").is_visible()
        page.locator("#clearPreviewCacheButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        with page.expect_response(
            lambda response: response.url.endswith("/v1/storage-maintenance/requests")
            and response.request.method == "POST"
        ) as clear_preview:
            page.locator("#confirmActionButton").click()
        assert clear_preview.value.status == 202
        assert submitted_actions[-1]["action"] == "clearPreviewCache"
        page.wait_for_function(
            "() => document.querySelector('#storageHistory').textContent.includes('已清理 24 条')",
            timeout=5_000,
        )
        page.wait_for_function(
            "() => document.activeElement?.id === 'clearPreviewCacheButton'"
        )

        originals_request_count = len(submitted_actions)
        page.locator("#clearPhotosOriginalsButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        assert page.locator("#confirmDialogTitle").inner_text() == "清理全部长期原图副本？"
        assert "不会修改 Apple Photos、人工标签" in page.locator(
            "#confirmDialogMessage"
        ).inner_text()
        assert page.locator("#confirmActionButton").inner_text() == "清理全部长期原图副本"
        page.screenshot(
            path="/tmp/imageall-storage-originals-confirmation.png",
            full_page=True,
        )
        page.locator("#cancelConfirmButton").click()
        assert len(submitted_actions) == originals_request_count
        page.wait_for_function(
            "() => document.activeElement?.id === 'clearPhotosOriginalsButton'"
        )
        page.locator("#clearPhotosOriginalsButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        with page.expect_response(
            lambda response: response.url.endswith("/v1/storage-maintenance/requests")
            and response.request.method == "POST"
        ) as clear_originals:
            page.locator("#confirmActionButton").click()
        assert clear_originals.value.status == 202
        assert submitted_actions[-1]["action"] == "clearPhotosOriginals"
        page.wait_for_function(
            "() => document.querySelector('#storageHistory').textContent.includes('已清理 3 条')",
            timeout=5_000,
        )
        page.wait_for_function(
            "() => document.activeElement?.id === 'clearPhotosOriginalsButton'"
        )

        page.evaluate(
            """
            () => {
              const content = document.querySelector("#storageContent");
              content.scrollTop = content.scrollHeight;
            }
            """
        )
        page.screenshot(
            path="/tmp/imageall-storage-history-continuity.png",
            full_page=True,
        )

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        assert page.locator("#storageDialog").is_visible()
        assert page.locator("#clearPreviewCacheButton").is_visible()
        assert page.locator("#storageRefreshButton").is_visible()
        page.screenshot(path="/tmp/imageall-storage-maintenance-synthetic.png", full_page=True)

        assert not page_errors, page_errors
        assert not console_errors, {"console": console_errors, "resources": failed_resources}
        browser.close()

    print(
        "storage maintenance browser flow passed; "
        f"submitted={len(submitted_actions)}; last={submitted_actions[-1]['action']}"
    )


if __name__ == "__main__":
    main()
