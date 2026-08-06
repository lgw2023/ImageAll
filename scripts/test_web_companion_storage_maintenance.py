#!/usr/bin/env python3
import json
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8801"
SOURCE_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
REQUEST_ID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"


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
    page_errors = []
    console_errors = []
    failed_resources = []

    def storage_snapshot():
        requests = [] if active_request is None else [active_request]
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
            nonlocal storage_reads_after_submit, active_request
            if active_request is not None:
                storage_reads_after_submit += 1
                if storage_reads_after_submit >= 1:
                    active_request = {
                        **active_request,
                        "phase": "completed",
                        "message": "已导出 42 条记录到“ImageAll-Export-Test”",
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
            active_request = {
                "id": REQUEST_ID,
                "operationID": payload["operationID"],
                "action": payload["action"],
                "phase": "awaitingMac",
                "message": "请回到 Mac 选择用户数据导出位置",
                "updatedAtMs": 1_700_000_000_000,
            }
            fulfill_json(route, active_request, status=202)

        page.route("**/v1/storage-maintenance", route_storage_snapshot)
        page.route("**/v1/storage-maintenance/requests", route_storage_submit)

        page.goto(BASE_URL, wait_until="networkidle")
        page.locator("#storageButton").click()
        page.locator("#storageContent:not(.hidden)").wait_for()
        assert page.locator("#previewCacheSize").inner_text() == "1.5 MB"
        assert "24 条" in page.locator("#previewCacheEntries").inner_text()
        assert page.locator("#photosOriginalsSize").inner_text() == "9 MB"
        assert page.locator("#appStorageKind").inner_text() == "Mac 内置存储"
        assert "ImageAll-External" in page.locator("#appStorageDetail").inner_text()
        assert "/Volumes/" not in page.locator("#storageDialog").inner_text()

        page.locator("#exportPortableDataButton").click()
        page.locator("#storagePending:not(.hidden)").wait_for()
        assert submitted_actions[-1]["action"] == "exportPortableData"
        page.wait_for_function(
            "() => document.querySelector('#storageHistory').textContent.includes('已导出 42 条记录')",
            timeout=5_000,
        )
        assert page.locator("#storagePending").is_hidden()

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
