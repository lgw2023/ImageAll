#!/usr/bin/env python3
import base64
import json

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8803"
SOURCE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
ASSET_IDS = [
    "11111111-1111-1111-1111-111111111111",
    "22222222-2222-2222-2222-222222222222",
]
PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def asset_item(asset_id):
    index = ASSET_IDS.index(asset_id) + 1
    return {
        "id": asset_id,
        "fileName": f"IMG_{index:04}.JPG",
        "sourceID": SOURCE_ID,
        "sourceName": "Apple Photos",
        "availability": "available",
        "contentRevision": index,
        "acceptedTagCount": index,
        "rejectedTagCount": 0,
    }


def asset_detail(asset_id):
    index = ASSET_IDS.index(asset_id) + 1
    return {
        "assetID": asset_id,
        "sourceID": SOURCE_ID,
        "sourceName": "Apple Photos",
        "sourceState": "active",
        "fileName": f"IMG_{index:04}.JPG",
        "relativePath": f"精选/IMG_{index:04}.JPG",
        "mediaType": "public.jpeg",
        "availability": "available",
        "contentRevision": index,
        "acceptedTagCount": index,
        "rejectedTagCount": 0,
        "mediaCreatedAtMs": 1_735_689_600_000 + index * 1_000,
        "mediaModifiedAtMs": 1_735_776_000_000 + index * 1_000,
        "width": 4032,
        "height": 3024,
        "durationMs": None,
        "fingerprintSizeBytes": 2_500_000 + index,
        "tags": [],
    }


def main():
    page_errors = []
    console_errors = []
    failed_resources = []
    detail_requests = []

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
                    "protocolVersion": 1,
                    "hostID": "55555555-5555-5555-5555-555555555555",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
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
                {"items": [asset_item(asset_id) for asset_id in ASSET_IDS], "nextCursor": None},
            ),
        )

        def handle_asset_detail(route):
            asset_id = route.request.url.split("/v1/assets/", 1)[1].split("?", 1)[0]
            detail_requests.append(asset_id)
            fulfill_json(route, asset_detail(asset_id))

        page.route("**/v1/assets/*", handle_asset_detail)
        page.route(
            "**/v1/assets/*/thumbnail?**",
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )
        page.route(
            "**/v1/assets/*/preview?**",
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )
        page.route(
            "**/v1/tags/selection",
            lambda route: fulfill_json(route, []),
        )

        page.goto(BASE_URL, wait_until="networkidle")
        cards = page.locator("#assetGrid .asset-card-main")
        assert cards.count() == 2
        cards.nth(0).click()
        cards.nth(1).click(modifiers=["Meta"])

        page.locator("#selectionInspectorPrimary:not(.hidden)").wait_for()
        page.wait_for_function(
            "id => state.selectionPrimaryDetail?.assetID === id",
            arg=ASSET_IDS[1],
        )
        assert page.locator("#selectionInspectorPrimaryTitle").inner_text() == "IMG_0002.JPG"
        assert page.locator("#selectionInspectorPrimaryPosition").inner_text() == "当前主项 · 选区 2 / 2"
        primary_metadata = page.locator("#selectionInspectorPrimaryMetadata").inner_text()
        assert "精选/IMG_0002.JPG" in primary_metadata
        assert "4032 × 3024" in primary_metadata
        assert "2.5 MB" in primary_metadata
        assert detail_requests[-1] == ASSET_IDS[1]

        # Mac-style split view resizing is layout-only: loaded assets, selection,
        # primary inspector context and scroll position must remain intact.
        page.evaluate(
            """
            () => {
              document.querySelector('#assetGrid').style.paddingBottom = '1500px';
              document.querySelector('#libraryScroll').scrollTop = 360;
            }
            """
        )
        page.wait_for_function("() => document.querySelector('#libraryScroll').scrollTop > 300")
        selected_before_resize = page.evaluate("() => [...state.selectedAssetIDs].sort()")
        scroll_before_resize = page.locator("#libraryScroll").evaluate("node => node.scrollTop")

        sidebar_handle = page.locator("#sidebarResizeHandle")
        sidebar_box = sidebar_handle.bounding_box()
        assert sidebar_box is not None
        page.mouse.move(sidebar_box["x"] + 4, sidebar_box["y"] + 180)
        page.mouse.down()
        page.mouse.move(sidebar_box["x"] + 59, sidebar_box["y"] + 180, steps=5)
        page.mouse.up()
        page.wait_for_function("() => state.layout.sidebarWidth === 275")

        inspector_handle = page.locator("#inspectorResizeHandle")
        inspector_box = inspector_handle.bounding_box()
        assert inspector_box is not None
        page.mouse.move(inspector_box["x"] + 4, inspector_box["y"] + 180)
        page.mouse.down()
        page.mouse.move(inspector_box["x"] - 36, inspector_box["y"] + 180, steps=5)
        page.mouse.up()
        page.wait_for_function("() => state.layout.inspectorWidth === 340")

        assert page.evaluate("() => [...state.selectedAssetIDs].sort()") == selected_before_resize
        assert page.evaluate("id => state.selectedAssetID === id", ASSET_IDS[1])
        assert page.locator("#libraryScroll").evaluate("node => node.scrollTop") == scroll_before_resize
        assert sidebar_handle.get_attribute("aria-valuenow") == "275"
        assert inspector_handle.get_attribute("aria-valuenow") == "340"
        page.screenshot(path="/tmp/imageall-split-view-resizing.png", full_page=True)

        # Keyboard adjustments follow the visual separator direction and persist
        # as non-sensitive browser workspace preferences.
        sidebar_handle.focus()
        page.keyboard.press("End")
        page.keyboard.press("ArrowLeft")
        inspector_handle.focus()
        page.keyboard.press("Home")
        page.keyboard.press("ArrowLeft")
        assert page.evaluate("() => state.layout.sidebarWidth") == 290
        assert page.evaluate("() => state.layout.inspectorWidth") == 250

        page.reload(wait_until="networkidle")
        page.locator("#assetGrid .asset-card-main").first.wait_for()
        assert page.evaluate("() => state.layout.sidebarWidth") == 290
        assert page.evaluate("() => state.layout.inspectorWidth") == 250
        assert page.locator("#sidebarResizeHandle").get_attribute("aria-valuenow") == "290"
        assert page.locator("#inspectorResizeHandle").get_attribute("aria-valuenow") == "250"

        page.locator("#sidebarVisibilityButton").click()
        assert page.locator("#sidebarResizeHandle").is_hidden()
        page.locator("#sidebarVisibilityButton").click()
        assert page.evaluate("() => state.layout.sidebarWidth") == 290
        page.locator("#inspectorVisibilityButton").click()
        assert page.locator("#inspectorResizeHandle").is_hidden()
        page.locator("#inspectorVisibilityButton").click()
        assert page.evaluate("() => state.layout.inspectorWidth") == 250

        page.locator("#sidebarResizeHandle").dblclick()
        page.locator("#inspectorResizeHandle").dblclick()
        assert page.evaluate("() => state.layout.sidebarWidth") == 220
        assert page.evaluate("() => state.layout.inspectorWidth") == 300

        cards = page.locator("#assetGrid .asset-card-main")
        cards.nth(0).click()
        cards.nth(1).click(modifiers=["Meta"])
        page.locator("#selectionInspectorPrimary:not(.hidden)").wait_for()

        selected_before_preview = page.evaluate("() => [...state.selectedAssetIDs].sort()")
        page.locator("#selectionInspectorPrimaryPreview").click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "IMG_0002.JPG" in page.locator("#lightboxTitle").inner_text()
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        assert page.evaluate("() => [...state.selectedAssetIDs].sort()") == selected_before_preview
        assert page.evaluate("id => state.selectedAssetID === id", ASSET_IDS[1])

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(120)
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        assert page.locator("#selectionInspectorPrimary").is_visible()
        assert page.locator("#selectionInspectorPrimaryPreview").is_visible()
        assert page.locator("#selectionInspectorPrimaryMetadata").is_visible()
        page.screenshot(
            path="/tmp/imageall-selection-primary-inspector.png",
            full_page=True,
        )

        assert not page_errors, page_errors
        assert not console_errors, {
            "console": console_errors,
            "resources": failed_resources,
        }
        context.close()
        browser.close()

    print(
        "selection primary inspector browser flow passed; "
        f"details={detail_requests}; selected={len(selected_before_preview)}"
    )


if __name__ == "__main__":
    main()
