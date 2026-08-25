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
    jobs_requests = 0
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
        def route_jobs(route):
            nonlocal jobs_requests
            jobs_requests += 1
            fulfill_json(route, [])

        page.route("**/v1/jobs", route_jobs)
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
            "**/v1/training/activities?**",
            lambda route: fulfill_json(route, []),
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
        assert page.locator("#appView").get_attribute("inert") is None
        assert page.locator("#sourceSidebar").is_visible()
        assert page.locator("#inspector").is_visible()
        assert page.locator("#inspectorWorkspacePlaceholder").is_visible()
        assert page.locator("#inspectorWorkspacePlaceholderTitle").inner_text() == "图库总览"
        assert page.locator("#inspectorWorkspacePlaceholderText").inner_text() == \
            "总览页已在主窗口展示聚合统计。"
        assert page.locator("#inspectorPlaceholderTagEditor").is_hidden()
        assert page.locator("#galleryOverviewWorkspace").get_attribute("role") == "region"
        assert page.locator("#galleryOverviewWorkspace").get_attribute("aria-modal") is None
        assert page.locator("#closeGalleryOverviewButton").is_hidden()
        assert page.locator("#libraryTitle").inner_text() == "图库总览"
        overview_bounds = page.locator("#galleryOverviewWorkspace").bounding_box()
        library_bounds = page.locator("#libraryPane").bounding_box()
        assert overview_bounds is not None and library_bounds is not None
        assert overview_bounds["x"] >= library_bounds["x"]
        assert overview_bounds["y"] >= library_bounds["y"]
        assert overview_bounds["x"] + overview_bounds["width"] <= \
            library_bounds["x"] + library_bounds["width"] + 1
        assert overview_bounds["y"] + overview_bounds["height"] <= \
            library_bounds["y"] + library_bounds["height"] + 1
        assert page.locator("#searchForm").evaluate(
            "element => Boolean(element.closest('[inert]'))"
        )
        page.screenshot(
            path="/tmp/imageall-gallery-overview-integrated.png",
            full_page=True,
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "galleryOverview"
        page.locator("#refreshGalleryOverviewButton").focus()
        overview_jobs_before = jobs_requests
        page.keyboard.press("j")
        page.locator("#jobsPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'galleryOverview' "
            "&& history.state?.imageAllWorkspace?.navigationLevel === 'jobs'"
        )
        assert jobs_requests == overview_jobs_before + 1
        page.keyboard.press("j")
        page.locator("#jobsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "galleryOverview"
        page.evaluate("() => history.forward()")
        page.locator("#jobsPopover:not(.hidden)").wait_for()
        assert jobs_requests == overview_jobs_before + 1
        page.keyboard.press("Escape")
        page.locator("#jobsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )
        all_media_button = page.locator('#libraryNavigation [data-source-id=""]')
        all_media_button.click()
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )
        assert all_media_button.get_attribute("aria-current") == "page"
        assert not page.locator("#searchForm").evaluate(
            "element => Boolean(element.closest('[inert]'))"
        )
        page.locator("#galleryOverviewNavigationButton").click()
        page.locator("#galleryOverviewWorkspace:not(.hidden)").wait_for()
        page.locator("#galleryOverviewBody:not(.hidden)").wait_for()
        overview_search_history_length = page.evaluate("history.length")
        overview_search_requests = overview_requests
        overview_search_asset_queries = len(asset_queries)
        page.locator("#refreshGalleryOverviewButton").focus()
        page.keyboard.press("Meta+F")
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        page.wait_for_function("() => document.activeElement?.id === 'searchInput'")
        assert page.evaluate("history.length") == overview_search_history_length + 1
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "gallery"
        assert overview_requests == overview_search_requests
        assert len(asset_queries) == overview_search_asset_queries
        page.evaluate("history.back()")
        page.locator("#galleryOverviewWorkspace:not(.hidden)").wait_for()
        page.locator("#galleryOverviewBody:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )
        assert overview_requests == overview_search_requests
        assert len(asset_queries) == overview_search_asset_queries
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        assert page.locator("#commandContextLabel").inner_text() == "当前：图库总览"
        assert "返回图库" in page.locator('[data-command-id="returnWorkspace"]').inner_text()
        assert page.locator('[data-command-id="openSlimming"]').count() == 1
        assert page.locator('[data-command-id="selectAll"]').count() == 0
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )
        page.keyboard.press("Meta+K")
        page.keyboard.press("Meta+K")
        page.wait_for_function(
            "() => !document.querySelector('#commandPalette').open "
            "&& document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )
        page.keyboard.press("Meta+K")
        page.locator('[data-command-id="showAll"]').click()
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )
        page.evaluate("() => history.back()")
        page.locator("#galleryOverviewWorkspace:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'galleryOverview'"
        )
        page.evaluate("() => history.back()")
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )
        page.wait_for_function(
            "() => document.activeElement?.id === 'galleryOverviewNavigationButton'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#galleryOverviewWorkspace:not(.hidden)").wait_for()
        page.locator("#galleryOverviewBody:not(.hidden)").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "galleryOverview"
        page.keyboard.press("Escape")
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )
        page.locator("#galleryOverviewNavigationButton").click()
        page.locator("#galleryOverviewWorkspace:not(.hidden)").wait_for()
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
        page.evaluate(
            """
            () => {
              const originalFetch = window.fetch.bind(window);
              window.__galleryOverviewRefreshRelease = null;
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/gallery-overview") return originalFetch(input, init);
                return new Promise((resolve, reject) => {
                  window.__galleryOverviewRefreshRelease = () => {
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  };
                });
              };
              const scroll = document.querySelector("#galleryOverviewScroll");
              const source = document.querySelector("[data-gallery-overview-source-id]");
              scroll.scrollTop = 180;
              source.focus({ preventScroll: true });
              window.__galleryOverviewStableFrame = {
                photo: document.querySelector('[data-gallery-overview-media-kind="image"]'),
                source,
                tag: document.querySelector("[data-gallery-overview-tag-id]"),
                year: document.querySelector(".gallery-overview-year"),
                scrollTop: scroll.scrollTop,
              };
              document.querySelector("#refreshGalleryOverviewButton").click();
            }
            """
        )
        page.wait_for_function(
            "() => document.querySelector('#galleryOverviewWorkspace').getAttribute('aria-busy') === 'true'"
        )
        assert page.evaluate(
            """
            () => {
              const frame = window.__galleryOverviewStableFrame;
              return frame.photo === document.querySelector('[data-gallery-overview-media-kind="image"]')
                && frame.source === document.querySelector("[data-gallery-overview-source-id]")
                && frame.tag === document.querySelector("[data-gallery-overview-tag-id]")
                && frame.year === document.querySelector(".gallery-overview-year")
                && document.activeElement === frame.source
                && document.querySelector("#galleryOverviewScroll").scrollTop === frame.scrollTop;
            }
            """
        ), "refresh replaced visible overview content while the request was pending"
        page.evaluate("() => window.__galleryOverviewRefreshRelease()")
        page.wait_for_function(
            "() => !document.querySelector('#galleryOverviewWorkspace').getAttribute('aria-busy')?.includes('true')"
        )
        assert page.evaluate(
            """
            () => {
              const frame = window.__galleryOverviewStableFrame;
              return frame.photo === document.querySelector('[data-gallery-overview-media-kind="image"]')
                && frame.source === document.querySelector("[data-gallery-overview-source-id]")
                && frame.tag === document.querySelector("[data-gallery-overview-tag-id]")
                && frame.year === document.querySelector(".gallery-overview-year")
                && document.activeElement === frame.source
                && document.querySelector("#galleryOverviewScroll").scrollTop === frame.scrollTop;
            }
            """
        ), "unchanged refresh replaced visible overview content"
        page.evaluate(
            """
            () => {
              const originalFetch = window.fetch.bind(window);
              window.__galleryOverviewRefreshRelease = null;
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/gallery-overview") return originalFetch(input, init);
                return new Promise((resolve, reject) => {
                  window.__galleryOverviewRefreshRelease = () => {
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  };
                });
              };
              const scroll = document.querySelector("#galleryOverviewScroll");
              const source = document.querySelector("[data-gallery-overview-source-id]");
              scroll.scrollTop = 180;
              source.focus({ preventScroll: true });
              window.__galleryOverviewChangedFrame = {
                photo: document.querySelector('[data-gallery-overview-media-kind="image"]'),
                source,
                tag: document.querySelector("[data-gallery-overview-tag-id]"),
                year: document.querySelector(".gallery-overview-year"),
                scrollTop: scroll.scrollTop,
              };
              document.querySelector("#refreshGalleryOverviewButton").click();
            }
            """
        )
        page.wait_for_function("() => Boolean(window.__galleryOverviewRefreshRelease)")
        overview["sources"][0]["imageCount"] = 121
        overview["media"][0]["totalCount"] = 121
        overview["media"][0]["exactUniqueCount"] = 111
        overview["media"][0]["exactFingerprintCount"] = 119
        overview["availability"][0]["imageCount"] = 119
        page.evaluate("() => window.__galleryOverviewRefreshRelease()")
        page.wait_for_function(
            "() => document.querySelector('#galleryOverviewWorkspace').getAttribute('aria-busy') === 'false'"
        )
        assert page.evaluate(
            """
            () => {
              const frame = window.__galleryOverviewChangedFrame;
              const source = document.querySelector("[data-gallery-overview-source-id]");
              return frame.photo === document.querySelector('[data-gallery-overview-media-kind="image"]')
                && frame.source === source
                && frame.tag === document.querySelector("[data-gallery-overview-tag-id]")
                && frame.year === document.querySelector(".gallery-overview-year")
                && source.querySelector(".gallery-overview-bar-count").textContent === "151"
                && document.activeElement === frame.source
                && document.querySelector("#galleryOverviewScroll").scrollTop === frame.scrollTop;
            }
            """
        ), "changed refresh did not update the existing overview frame in place"
        page.evaluate(
            """
            () => {
              const originalFetch = window.fetch.bind(window);
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/gallery-overview") return originalFetch(input, init);
                window.fetch = originalFetch;
                return Promise.reject(new Error("模拟图库总览刷新失败"));
              };
              const scroll = document.querySelector("#galleryOverviewScroll");
              const source = document.querySelector("[data-gallery-overview-source-id]");
              scroll.scrollTop = 180;
              source.focus({ preventScroll: true });
              window.__galleryOverviewFailedFrame = {
                photo: document.querySelector('[data-gallery-overview-media-kind="image"]'),
                source,
                tag: document.querySelector("[data-gallery-overview-tag-id]"),
                year: document.querySelector(".gallery-overview-year"),
                scrollTop: scroll.scrollTop,
              };
              document.querySelector("#refreshGalleryOverviewButton").click();
            }
            """
        )
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('模拟图库总览刷新失败')"
        )
        assert page.evaluate(
            """
            () => {
              const frame = window.__galleryOverviewFailedFrame;
              return frame.photo === document.querySelector('[data-gallery-overview-media-kind="image"]')
                && frame.source === document.querySelector("[data-gallery-overview-source-id]")
                && frame.tag === document.querySelector("[data-gallery-overview-tag-id]")
                && frame.year === document.querySelector(".gallery-overview-year")
                && document.activeElement === frame.source
                && document.querySelector("#galleryOverviewScroll").scrollTop === frame.scrollTop;
            }
            """
        ), "failed refresh replaced the last successful overview frame"
        page.screenshot(
            path="/tmp/imageall-gallery-overview-refresh-continuity.png",
            full_page=True,
        )
        page.wait_for_timeout(500)
        assert overview_requests == 3, f"unexpected repeated overview refreshes: {overview_requests}"

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        assert page.locator("#appView").get_attribute("inert") is not None
        assert page.locator("#galleryOverviewWorkspace").get_attribute("role") == "dialog"
        assert page.locator("#galleryOverviewWorkspace").get_attribute("aria-modal") == "true"
        assert page.locator("#closeGalleryOverviewButton").is_visible()
        assert page.locator("#closeGalleryOverviewButton").get_attribute("aria-label") == "返回图库"
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        assert page.locator("#galleryOverviewTimeline").is_visible()
        page.locator("#refreshGalleryOverviewButton").focus()
        command_history_length = page.evaluate("() => history.length")
        command_overview_requests = overview_requests
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        assert page.evaluate("() => history.length") == command_history_length + 1
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "commandPalette"
        command_bounds = page.locator("#commandPalette").bounding_box()
        assert command_bounds is not None
        assert command_bounds["x"] >= 0
        assert command_bounds["x"] + command_bounds["width"] <= 390
        assert page.locator("#commandContextLabel").inner_text() == "当前：图库总览"
        page.screenshot(path="/tmp/imageall-command-palette-overview-390.png", full_page=True)
        private_command_search = "私密命令 /Users/example/Photos"
        page.locator("#commandSearchInput").fill(private_command_search)
        assert private_command_search not in page.evaluate("() => JSON.stringify(history.state)")
        page.evaluate("() => history.back()")
        page.locator("#commandPalette").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#commandPalette[open]").wait_for()
        assert page.locator("#commandContextLabel").inner_text() == "当前：图库总览"
        assert page.locator("#commandSearchInput").input_value() == ""
        page.keyboard.press("Escape")
        page.locator("#commandPalette").wait_for(state="hidden")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "workspace"
        assert overview_requests == command_overview_requests

        page.locator("#refreshGalleryOverviewButton").focus()
        shortcuts_history_length = page.evaluate("() => history.length")
        shortcuts_overview_requests = overview_requests
        page.keyboard.press("?")
        page.locator("#shortcutDialog[open]").wait_for()
        assert page.evaluate("() => history.length") in {
            shortcuts_history_length,
            shortcuts_history_length + 1,
        }
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "keyboardShortcuts"
        shortcut_bounds = page.locator("#shortcutDialog").bounding_box()
        assert shortcut_bounds is not None
        assert shortcut_bounds["x"] >= 0
        assert shortcut_bounds["x"] + shortcut_bounds["width"] <= 390
        assert shortcut_bounds["y"] >= 0
        assert shortcut_bounds["y"] + shortcut_bounds["height"] <= 844
        assert page.locator("#shortcutDialog dl").evaluate(
            "node => node.scrollHeight > node.clientHeight"
        )
        page.screenshot(
            path="/tmp/imageall-keyboard-shortcuts-overview-390.png",
            full_page=True,
        )
        page.evaluate("() => history.back()")
        page.locator("#shortcutDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#shortcutDialog[open]").wait_for()
        page.locator("#closeShortcutButton").click()
        page.locator("#shortcutDialog").wait_for(state="hidden")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "workspace"
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )

        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        page.locator("#commandSearchInput").fill("快捷键")
        page.locator('[data-command-id="shortcuts"]').click()
        page.locator("#shortcutDialog[open]").wait_for()
        assert page.locator("#commandPalette").is_hidden()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "keyboardShortcuts"
        page.keyboard.press("Escape")
        page.locator("#shortcutDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshGalleryOverviewButton'"
        )
        assert overview_requests == shortcuts_overview_requests

        page.locator("#closeGalleryOverviewButton").click()
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        compact_shortcut_overview_requests = overview_requests
        page.locator("#compactToolbarMenuButton").click()
        page.locator("#compactToolbarMenu:not(.hidden)").wait_for()
        page.locator(
            '[data-compact-toolbar-target="shortcutButton"]'
        ).click()
        page.locator("#shortcutDialog[open]").wait_for()
        assert page.locator("#compactToolbarMenu").is_hidden()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "keyboardShortcuts"
        page.evaluate("() => history.back()")
        page.locator("#shortcutDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'compactToolbarMenuButton'"
        )
        assert overview_requests == compact_shortcut_overview_requests
        page.locator("#sidebarToggle").click()
        page.locator("#sourceSidebar.open").wait_for()
        page.locator("#galleryOverviewNavigationButton").click()
        page.locator("#galleryOverviewWorkspace:not(.hidden)").wait_for()
        page.locator("#galleryOverviewBody:not(.hidden)").wait_for()
        page.screenshot(path="/tmp/imageall-gallery-overview-synthetic.png", full_page=True)

        overview = {
            "media": [],
            "sources": [],
            "positiveTags": [],
            "years": [],
            "availability": [],
            "undatedCount": 0,
            "positiveLabeledAssetCount": 0,
            "acceptedDecisionCount": 0,
            "favorites": [],
        }
        page.locator("#refreshGalleryOverviewButton").click()
        page.locator("#galleryOverviewEmpty:not(.hidden)").wait_for()
        assert page.locator("#galleryOverviewStatus").is_hidden()
        assert page.locator("#galleryOverviewBody").is_hidden()
        assert page.locator("#galleryOverviewEmpty").get_by_text(
            "图库还没有内容", exact=True
        ).is_visible()
        assert "连接来源并完成索引后" in page.locator(
            "#galleryOverviewEmpty"
        ).inner_text()
        assert not page.locator("#galleryOverviewTotalMetric").is_visible()
        assert page.evaluate(
            "() => document.documentElement.scrollWidth <= window.innerWidth"
        )
        page.screenshot(path="/tmp/imageall-gallery-overview-empty-390.png", full_page=True)
        assert overview_requests == 4

        page.keyboard.press("Escape")
        page.locator("#galleryOverviewWorkspace").wait_for(state="hidden")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "gallery"
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
