#!/usr/bin/env python3
import base64
import json

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8804"
SOURCE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
ASSET_ID = "11111111-1111-1111-1111-111111111111"
PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def snapshot(operation_id, phase, progress, message=None):
    return {
        "operationID": operation_id,
        "assetID": ASSET_ID,
        "phase": phase,
        "progress": progress,
        "message": message,
        "updatedAtMs": 1_700_000_000_000,
    }


def main():
    lifecycle = {
        "operation_id": None,
        "phase": None,
        "progress": 0.0,
        "poll_count": 0,
        "allow_complete": False,
        "cache_ready": False,
        "starts": [],
        "cancels": [],
    }
    page_errors = []
    console_errors = []
    unexpected_failures = []

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

        def record_failed_response(response):
            if response.status < 400:
                return
            expected = response.status in (404, 409) and (
                "cloud-preview-requests" in response.url
                or "/preview" in response.url
            )
            if not expected:
                unexpected_failures.append((response.status, response.url))

        page.on("response", record_failed_response)
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
                {
                    "authenticated": True,
                    "authMode": "pairedDevice",
                    "deviceName": "Synthetic Browser",
                },
            ),
        )
        page.route(
            "**/v1/capabilities",
            lambda route: fulfill_json(
                route,
                {
                    "protocolVersion": 2,
                    "hostID": "55555555-5555-5555-5555-555555555555",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                    "capabilities": ["cloudPreviewLifecycle"],
                },
            ),
        )
        page.route(
            "**/v1/sources",
            lambda route: fulfill_json(
                route,
                [{
                    "id": SOURCE_ID,
                    "kind": "photos",
                    "displayName": "Apple Photos",
                    "state": "active",
                }],
            ),
        )
        page.route("**/v1/tags", lambda route: fulfill_json(route, []))
        page.route("**/v1/tag-groups", lambda route: fulfill_json(route, []))
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
        page.route(
            "**/v1/embedding-preparation?**",
            lambda route: fulfill_json(
                route,
                {"mediaKind": "image", "isAvailable": True, "activities": []},
            ),
        )
        page.route(
            "**/v1/sample-suggestions?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "isAvailable": True,
                    "maximumSampleCount": 500,
                    "activities": [],
                },
            ),
        )
        page.route(
            "**/v1/tag-library-suggestions?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "maximumPendingCount": 500,
                    "personalCentroidAvailable": False,
                    "personalAdamWAvailable": False,
                    "tags": [],
                    "activities": [],
                },
            ),
        )
        page.route(
            "**/v1/assets?**",
            lambda route: fulfill_json(
                route,
                {
                    "items": [{
                        "id": ASSET_ID,
                        "fileName": "ICLOUD_0001.HEIC",
                        "sourceID": SOURCE_ID,
                        "sourceName": "Apple Photos",
                        "availability": "available",
                        "contentRevision": 7,
                        "acceptedTagCount": 0,
                        "rejectedTagCount": 0,
                    }],
                    "nextCursor": None,
                },
            ),
        )

        def handle_asset_detail(route):
            fulfill_json(route, {
                "assetID": ASSET_ID,
                "sourceID": SOURCE_ID,
                "sourceName": "Apple Photos",
                "sourceState": "active",
                "fileName": "ICLOUD_0001.HEIC",
                "relativePath": "Apple Photos/ICLOUD_0001.HEIC",
                "mediaType": "public.heic",
                "availability": "available",
                "contentRevision": 7,
                "acceptedTagCount": 0,
                "rejectedTagCount": 0,
                "width": 4032,
                "height": 3024,
                "durationMs": None,
                "fingerprintSizeBytes": 3_200_000,
                "tags": [],
            })

        page.route("**/v1/assets/*", handle_asset_detail)
        page.route(
            "**/v1/assets/*/thumbnail?**",
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )

        def handle_preview(route):
            if lifecycle["cache_ready"]:
                route.fulfill(status=200, content_type="image/png", body=PIXEL)
            else:
                fulfill_json(
                    route,
                    {"code": "conflict", "message": "cloud preview required"},
                    status=409,
                )

        page.route("**/v1/assets/*/preview?**", handle_preview)

        def handle_lifecycle(route):
            if route.request.method == "POST":
                operation_id = route.request.post_data_json["operationID"]
                lifecycle["operation_id"] = operation_id
                lifecycle["phase"] = "downloading"
                lifecycle["progress"] = 0.0
                lifecycle["poll_count"] = 0
                lifecycle["starts"].append(operation_id)
                fulfill_json(route, snapshot(operation_id, "downloading", 0.0), status=202)
                return
            if lifecycle["operation_id"] is None:
                fulfill_json(
                    route,
                    {"code": "not_found", "message": "cloud preview download not found"},
                    status=404,
                )
                return
            lifecycle["poll_count"] += 1
            if lifecycle["allow_complete"] and lifecycle["poll_count"] >= 2:
                lifecycle["phase"] = "completed"
                lifecycle["progress"] = 1.0
                lifecycle["cache_ready"] = True
            elif lifecycle["phase"] == "downloading":
                lifecycle["progress"] = 0.42
            fulfill_json(
                route,
                snapshot(
                    lifecycle["operation_id"],
                    lifecycle["phase"],
                    lifecycle["progress"],
                ),
            )

        page.route("**/v1/assets/*/cloud-preview-requests", handle_lifecycle)

        def handle_cancel(route):
            operation_id = route.request.post_data_json["operationID"]
            assert operation_id == lifecycle["operation_id"]
            lifecycle["cancels"].append(operation_id)
            lifecycle["phase"] = "cancelled"
            fulfill_json(
                route,
                snapshot(operation_id, "cancelled", lifecycle["progress"]),
            )

        page.route("**/v1/assets/*/cloud-preview-requests/cancel", handle_cancel)

        page.goto(BASE_URL, wait_until="networkidle")
        page.wait_for_timeout(250)
        if page.locator("#assetGrid .asset-card-main").count() != 1:
            page.screenshot(path="/tmp/imageall-cloud-preview-boot-failure.png", full_page=True)
            raise AssertionError({
                "body": page.locator("body").inner_text(),
                "console": console_errors,
                "page_errors": page_errors,
                "responses": unexpected_failures,
            })
        page.locator("#assetGrid .asset-card-main").click()
        page.locator("#cloudPreviewRecovery:not(.hidden)").wait_for()
        assert "仅存储在 iCloud" in page.locator("#cloudPreviewTitle").inner_text()

        page.locator("#cloudPreviewButton").click()
        page.wait_for_function(
            "() => document.querySelector('#cloudPreviewProgress').value >= 0.42"
        )
        assert "42%" in page.locator("#cloudPreviewMessage").inner_text()
        assert page.locator("#cloudPreviewButton").inner_text() == "取消"
        assert page.locator("#cloudPreviewProgress").is_visible()

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(120)
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        page.screenshot(
            path="/tmp/imageall-cloud-preview-progress-cancel.png",
            full_page=True,
        )

        page.locator("#cloudPreviewButton").click()
        page.wait_for_function(
            "() => document.querySelector('#cloudPreviewTitle').textContent.includes('仅存储在 iCloud')"
        )
        assert len(lifecycle["cancels"]) == 1
        assert page.locator("#cloudPreviewButton").inner_text() == "从 iCloud 获取预览"

        lifecycle["allow_complete"] = True
        page.locator("#cloudPreviewButton").click()
        page.locator("#cloudPreviewRecovery").wait_for(state="hidden")
        page.wait_for_function(
            "() => !document.querySelector('#previewImage').classList.contains('hidden') "
            "&& document.querySelector('#previewImage').naturalWidth > 0"
        )
        assert len(lifecycle["starts"]) == 2
        assert lifecycle["starts"][0] != lifecycle["starts"][1]
        assert lifecycle["cancels"] == [lifecycle["starts"][0]]
        assert lifecycle["cache_ready"] is True

        assert not page_errors, page_errors
        unexpected_console = [
            message for message in console_errors
            if not message.startswith("Failed to load resource:")
        ]
        assert not unexpected_console, unexpected_console
        assert not unexpected_failures, unexpected_failures
        context.close()
        browser.close()

    print(
        "cloud preview lifecycle browser flow passed; "
        f"starts={len(lifecycle['starts'])}; cancels={len(lifecycle['cancels'])}; "
        f"polls={lifecycle['poll_count']}"
    )


if __name__ == "__main__":
    main()
