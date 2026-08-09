#!/usr/bin/env python3
import json
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8799"
SOURCE_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
TAG_ID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def main():
    asset_queries = []
    overview_requests = 0
    console_errors = []
    page_errors = []
    overview = {
        "media": [
            {
                "mediaKind": "image",
                "totalCount": 120,
                "exactUniqueCount": 110,
                "exactRedundantCount": 10,
                "exactFingerprintCount": 118,
            },
            {
                "mediaKind": "video",
                "totalCount": 30,
                "exactUniqueCount": 29,
                "exactRedundantCount": 1,
                "exactFingerprintCount": 30,
            },
        ],
        "sources": [
            {
                "id": SOURCE_ID,
                "displayName": "Apple Photos",
                "kind": "photos",
                "state": "active",
                "imageCount": 120,
                "videoCount": 30,
            }
        ],
        "positiveTags": [
            {
                "id": TAG_ID,
                "displayName": "猫",
                "imageCount": 18,
                "videoCount": 2,
            }
        ],
        "years": [
            {"year": 2024, "imageCount": 32, "videoCount": 5},
            {"year": 2025, "imageCount": 41, "videoCount": 12},
            {"year": 2026, "imageCount": 44, "videoCount": 13},
        ],
        "availability": [
            {"availability": "available", "imageCount": 118, "videoCount": 30},
            {"availability": "missing", "imageCount": 2, "videoCount": 0},
        ],
        "undatedCount": 3,
        "positiveLabeledAssetCount": 20,
        "acceptedDecisionCount": 24,
        "favorites": [
            {"mediaKind": "image", "count": 17},
            {"mediaKind": "video", "count": 3},
        ],
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
                {"authenticated": True, "authMode": "account", "username": "test"},
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
                    "capabilities": ["favorites"],
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
        page.route(
            "**/v1/tags",
            lambda route: fulfill_json(
                route,
                [{"id": TAG_ID, "displayName": "猫", "state": "active", "groupID": None}],
            ),
        )
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

        def route_assets(route):
            asset_queries.append(parse_qs(urlparse(route.request.url).query))
            fulfill_json(route, {"items": [], "nextCursor": None})

        def route_overview(route):
            nonlocal overview_requests
            overview_requests += 1
            fulfill_json(route, overview)

        page.route("**/v1/assets?**", route_assets)
        page.route("**/v1/gallery-overview", route_overview)

        page.goto(BASE_URL, wait_until="networkidle")
        page.locator("#galleryOverviewNavigationButton").click()
        page.locator("#galleryOverviewWorkspace:not(.hidden)").wait_for()
        page.locator("#galleryOverviewBody:not(.hidden)").wait_for()
        assert page.locator("#galleryOverviewTotalMetric").inner_text() == "150"
        assert page.locator("#galleryOverviewUniqueMetric").inner_text() == "139"
        assert page.locator("#galleryOverviewPositiveMetric").inner_text() == "20"
        assert page.locator("#galleryOverviewFavoriteMetric").inner_text() == "20"
        assert page.locator("#galleryOverviewFavoriteImageMetric").inner_text() == "17"
        assert page.locator("#galleryOverviewFavoriteVideoMetric").inner_text() == "3"
        assert page.locator("[data-gallery-overview-source-id]").count() == 1
        assert page.locator("[data-gallery-overview-tag-id]").inner_text().startswith("猫")

        page.locator("#galleryOverviewFavoritesMetric").click()
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        page.wait_for_timeout(100)
        assert any(query.get("favorite") == ["favorited"] for query in asset_queries)

        page.locator("#galleryOverviewNavigationButton").click()

        page.locator(f'[data-gallery-overview-source-id="{SOURCE_ID}"]').click()
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "expected => new URL(location.href).origin && document.querySelector(`[data-source-id='${expected}']`).classList.contains('selected')",
            arg=SOURCE_ID,
        )
        assert any(query.get("sourceIDs") == [SOURCE_ID] for query in asset_queries)

        page.locator("#galleryOverviewNavigationButton").click()
        page.locator(f'[data-gallery-overview-tag-id="{TAG_ID}"]').click()
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        page.wait_for_timeout(100)
        assert any(query.get("acceptedTagIDs") == [TAG_ID] for query in asset_queries)

        page.locator("#galleryOverviewNavigationButton").click()
        page.locator("#refreshGalleryOverviewButton").click()
        page.wait_for_function(
            "() => !document.querySelector('#galleryOverviewWorkspace').getAttribute('aria-busy')?.includes('true')"
        )
        page.wait_for_timeout(500)
        assert overview_requests == 2, f"unexpected repeated overview refreshes: {overview_requests}"

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        assert page.locator("#galleryOverviewTimeline").is_visible()
        page.screenshot(path="/tmp/imageall-gallery-overview-synthetic.png", full_page=True)

        page.keyboard.press("Escape")
        assert page.locator("#galleryOverviewWorkspace").is_hidden()
        assert page.locator("#appView").get_attribute("inert") is None
        assert not page_errors, page_errors
        assert not console_errors, console_errors
        browser.close()

    print(
        "gallery-overview browser flow passed; "
        f"overview requests={overview_requests}; asset requests={len(asset_queries)}"
    )


if __name__ == "__main__":
    main()
