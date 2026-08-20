#!/usr/bin/env python3
import base64
import json
import re
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8810"
SOURCE_ID = "aaaaaaaa-1111-4222-8333-aaaaaaaaaaaa"
REVIEW_TAG_ID = "bbbbbbbb-1111-4222-8333-bbbbbbbbbbbb"
TAG_GROUP_ID = "dddddddd-1111-4222-8333-dddddddddddd"
WORLD_MAP_CLUSTER_ID = "cluster-shanghai"
PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def asset_id(index):
    return f"10000000-0000-4000-8000-{index:012d}"


def asset_summary(index):
    return {
        "id": asset_id(index),
        "sourceID": SOURCE_ID,
        "sourceName": "Synthetic Archive",
        "fileName": f"ITEM_{index:03d}.JPG",
        "mediaType": "public.jpeg",
        "availability": "available",
        "contentRevision": 1,
        "acceptedTagCount": 0,
        "rejectedTagCount": 0,
        "mediaCreatedAtMs": 1_700_000_000_000 + index,
        "width": 1600,
        "height": 1200,
    }


def asset_detail(index):
    return {
        "assetID": asset_id(index),
        "sourceID": SOURCE_ID,
        "sourceName": "Synthetic Archive",
        "fileName": f"ITEM_{index:03d}.JPG",
        "relativePath": f"Album/ITEM_{index:03d}.JPG",
        "mediaType": "public.jpeg",
        "availability": "available",
        "contentRevision": 1,
        "acceptedTagCount": 0,
        "rejectedTagCount": 0,
        "mediaCreatedAtMs": 1_700_000_000_000 + index,
        "mediaModifiedAtMs": 1_700_000_100_000 + index,
        "width": 1600,
        "height": 1200,
        "durationMs": None,
        "fingerprintSizeBytes": 800_000 + index,
        "tags": [{
            "tagID": REVIEW_TAG_ID,
            "displayName": "猫",
            "decision": "unknown",
        }],
        "pendingSuggestions": [],
    }


def review_item(index):
    return {
        "assetID": asset_id(index),
        "fileName": f"REVIEW_{index:03d}.JPG",
        "availability": "available",
        "acceptedTagCount": 0,
        "rejectedTagCount": 0,
        "suggestionOrigin": "featurePrint",
        "score": 0.91,
    }


def dispatch_lightbox_touch(page, events):
    page.evaluate(
        """
        events => {
          const stage = document.querySelector('#lightboxStage');
          for (const event of events) {
            stage.dispatchEvent(new PointerEvent(event.type, {
              bubbles: true,
              cancelable: true,
              pointerId: event.pointerId,
              pointerType: 'touch',
              isPrimary: event.pointerId === 1,
              clientX: event.x,
              clientY: event.y,
              button: 0,
              buttons: event.type === 'pointerup' || event.type === 'pointercancel' ? 0 : 1,
            }));
          }
        }
        """,
        events,
    )


def main():
    asset_queries = []
    review_queries = []
    review_decisions = []
    review_undos = []
    tag_undos = []
    review_pagination_enabled = {"value": False}
    page_errors = []
    console_errors = []
    http_errors = []
    world_map_snapshot_queries = []

    first_page = [asset_summary(index) for index in range(1, 73)]
    second_page = [asset_summary(index) for index in range(73, 75)]
    first_review_page = [review_item(index) for index in range(1, 49)]
    second_review_page = [review_item(49)]
    third_review_page = [review_item(50)]
    index_by_id = {
        asset_id(index): index for index in range(1, 75)
    }

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True,
            executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        context = browser.new_context(
            viewport={"width": 1440, "height": 900},
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
            lambda response: http_errors.append({
                "status": response.status,
                "method": response.request.method,
                "url": response.url,
            }) if response.status >= 400 else None,
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
                    "protocolVersion": 2,
                    "hostID": "cccccccc-1111-4222-8333-cccccccccccc",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                    "capabilities": [],
                },
            ),
        )
        page.route(
            "**/v1/sources",
            lambda route: fulfill_json(
                route,
                [{
                    "id": SOURCE_ID,
                    "kind": "folder",
                    "displayName": "Synthetic Archive",
                    "state": "active",
                }],
            ),
        )
        page.route(
            "**/v1/tags",
            lambda route: fulfill_json(
                route,
                [{
                    "id": REVIEW_TAG_ID,
                    "displayName": "猫",
                    "state": "active",
                    "groupID": TAG_GROUP_ID,
                }],
            ),
        )
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(
                route,
                [{
                    "id": TAG_GROUP_ID,
                    "displayName": "主体",
                    "sortOrder": 0,
                    "isSystem": True,
                }],
            ),
        )
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
            "**/v1/training/activities?**",
            lambda route: fulfill_json(route, []),
        )

        def route_assets(route):
            query = parse_qs(urlparse(route.request.url).query)
            asset_queries.append(query)
            if query.get("cursor") == ["page-2"]:
                fulfill_json(route, {"items": second_page, "nextCursor": None})
            else:
                fulfill_json(route, {"items": first_page, "nextCursor": "page-2"})

        page.route("**/v1/assets?**", route_assets)

        def route_world_map_snapshot(route):
            world_map_snapshot_queries.append(
                parse_qs(urlparse(route.request.url).query)
            )
            fulfill_json(
                route,
                {
                    "clusters": [{
                        "id": WORLD_MAP_CLUSTER_ID,
                        "longitude": 121.47,
                        "latitude": 31.23,
                        "photoCount": 2,
                        "gpsCount": 1,
                        "tagCount": 1,
                        "displayName": "上海",
                        "selectionQuery": {
                            "cellDegrees": 0.25,
                            "longitudeBucket": 485,
                            "latitudeBucket": 124,
                            "bounds": {
                                "west": 121.2,
                                "south": 31.0,
                                "east": 121.8,
                                "north": 31.5,
                            },
                            "maximumAssets": 36,
                        },
                    }],
                    "eligiblePhotoCount": 74,
                    "locatedPhotoCount": 2,
                    "unlocatedPhotoCount": 72,
                },
            )

        page.route("**/v1/world-map/snapshot?**", route_world_map_snapshot)
        page.route(
            "**/v1/world-map/selection",
            lambda route: fulfill_json(
                route,
                {
                    "assets": [{
                        "id": asset_id(index),
                        "fileName": f"MAP_{index:03d}.JPG",
                        "availability": "available",
                        "contentRevision": 1,
                        "favorite": None,
                    } for index in (1, 2)],
                    "totalPhotoCount": 2,
                },
            ),
        )

        page.route(
            "**/v1/review/overview?**",
            lambda route: fulfill_json(
                route,
                {
                    "totalPendingSuggestionCount": 50,
                    "tags": [{
                        "id": REVIEW_TAG_ID,
                        "displayName": "猫",
                        "acceptedSampleCount": 8,
                        "rejectedSampleCount": 4,
                        "pendingSuggestionCount": 50,
                        "pendingSuggestionCounts": {
                            "featurePrint": 50,
                            "standardModel": 0,
                            "personalModel": 0,
                            "personalAdamW": 0,
                        },
                        "taskStatus": "completed",
                        "checkedCount": 12,
                        "totalCount": 12,
                        "skippedCount": 0,
                        "missingPositiveCount": 0,
                        "missingNegativeCount": 0,
                        "canReview": True,
                    }],
                },
            ),
        )

        def route_review_queue(route):
            query = parse_qs(urlparse(route.request.url).query)
            review_queries.append(query)
            if query.get("cursor") == ["review-page-3"]:
                fulfill_json(route, {"items": third_review_page, "nextCursor": None})
                return
            if query.get("cursor") == ["review-page-2"]:
                fulfill_json(
                    route,
                    {"items": second_review_page, "nextCursor": "review-page-3"},
                )
            else:
                fulfill_json(
                    route,
                    {
                        "items": first_review_page,
                        "nextCursor": "review-page-2"
                        if review_pagination_enabled["value"] else None,
                    },
                )

        page.route("**/v1/review/queue?**", route_review_queue)

        def route_review_decision(route):
            payload = route.request.post_data_json
            review_decisions.append(payload)
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "appliedAssetCount": len(payload["assetIDs"]),
                    "replayed": False,
                    "undoID": "eeeeeeee-1111-4222-8333-eeeeeeeeeeee",
                },
            )

        page.route("**/v1/review/decisions/batch", route_review_decision)

        def route_review_undo(route):
            payload = route.request.post_data_json
            review_undos.append(payload)
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "restoredAssetCount": 3,
                    "replayed": False,
                },
            )

        page.route("**/v1/review/decisions/undo", route_review_undo)

        def route_tag_undo(route):
            payload = route.request.post_data_json
            tag_undos.append(payload)
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "restoredAssetCount": 1,
                    "replayed": False,
                },
            )

        page.route("**/v1/tag-decisions/undo", route_tag_undo)

        def route_tag_selection(route):
            payload = route.request.post_data_json
            asset_count = len(payload.get("assetIDs", []))
            fulfill_json(
                route,
                [{
                    "tagID": tag_id,
                    "acceptedCount": 0,
                    "rejectedCount": 0,
                    "unknownCount": asset_count,
                } for tag_id in payload.get("tagIDs", [])],
            )

        page.route("**/v1/tags/selection", route_tag_selection)

        def route_asset_detail(route):
            current_id = urlparse(route.request.url).path.rsplit("/", 1)[-1]
            fulfill_json(route, asset_detail(index_by_id[current_id]))

        page.route(re.compile(r".*/v1/assets/[0-9a-f-]+$"), route_asset_detail)
        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            lambda route: route.fulfill(
                status=200,
                content_type="image/png",
                body=PNG_BYTES,
            ),
        )

        page.goto(BASE_URL, wait_until="networkidle")
        page.wait_for_timeout(1_000)
        initial_gallery = page.evaluate(
            """() => ({
              cards: document.querySelectorAll('#assetGrid > .asset-card').length,
              assets: state.assets.length,
              nextCursor: state.nextCursor,
              loading: state.loadingAssets,
              refreshing: state.refreshingWorkspace,
              appHidden: document.querySelector('#appView').classList.contains('hidden'),
              pairingHidden: document.querySelector('#pairingView').classList.contains('hidden'),
            })"""
        )
        assert initial_gallery["cards"] == 72, {
            "gallery": initial_gallery,
            "assetQueries": asset_queries,
            "pageErrors": page_errors,
            "consoleErrors": console_errors,
        }
        assert not any(query.get("cursor") == ["page-2"] for query in asset_queries)

        # Command-Z follows the most recent Host undo channel while leaving
        # native text-field undo untouched.
        page.evaluate(
            """
            () => {
              undoToast("标签已更新", "11111111-1111-4111-8111-111111111111", "tag");
              undoToast("审核已更新", "22222222-2222-4222-8222-222222222222", "review");
            }
            """
        )
        page.keyboard.press("Meta+z")
        page.wait_for_function("() => state.undo.review.id === null")
        assert review_undos[-1]["undoID"] == "22222222-2222-4222-8222-222222222222"
        assert page.evaluate("() => state.undo.tag.id") == "11111111-1111-4111-8111-111111111111"

        page.locator("#searchInput").focus()
        tag_undo_count = len(tag_undos)
        page.keyboard.press("Meta+z")
        assert len(tag_undos) == tag_undo_count

        page.locator("#assetGrid .asset-card-main").first.click()
        page.keyboard.press("Meta+z")
        page.wait_for_function("() => state.undo.tag.id === null")
        assert tag_undos[-1]["undoID"] == "11111111-1111-4111-8111-111111111111"

        last_first_page = page.locator(
            f'#assetGrid > .asset-card[data-asset-id="{asset_id(72)}"]'
        )
        last_first_page.dispatch_event("click")
        last_first_page.dispatch_event("dblclick")
        page.locator("#lightbox:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#assetFileName')?.textContent === 'ITEM_072.JPG'"
        )
        docked = page.evaluate("""() => {
          const lightbox = document.querySelector('#lightbox');
          const library = document.querySelector('#libraryPane');
          const inspector = document.querySelector('#inspector');
          const lightboxBounds = lightbox.getBoundingClientRect();
          const libraryBounds = library.getBoundingClientRect();
          const inspectorBounds = inspector.getBoundingClientRect();
          return {
            docked: lightbox.classList.contains('library-docked'),
            modal: lightbox.getAttribute('aria-modal'),
            appInert: document.querySelector('#appView').inert,
            libraryInert: library.inert,
            inspectorInert: inspector.inert,
            frameMatches: Math.abs(lightboxBounds.left - libraryBounds.left) < 1
              && Math.abs(lightboxBounds.top - libraryBounds.top) < 1
              && Math.abs(lightboxBounds.right - libraryBounds.right) < 1
              && Math.abs(lightboxBounds.bottom - libraryBounds.bottom) < 1,
            inspectorClear: lightboxBounds.right <= inspectorBounds.left + 1,
          };
        }""")
        assert docked == {
            "docked": True,
            "modal": "false",
            "appInert": False,
            "libraryInert": True,
            "inspectorInert": False,
            "frameMatches": True,
            "inspectorClear": True,
        }, docked
        # Let the lightbox's one-shot opening focus settle before exercising the
        # still-live inspector; otherwise Playwright can race that animation frame.
        page.wait_for_timeout(50)
        page.locator("#inspectorTagSearch").focus()
        page.wait_for_function(
            "() => document.activeElement?.id === 'inspectorTagSearch'"
        )
        page.locator("#inspectorTagSearch").fill("猫")
        page.locator(
            f'#inspectorTags [data-tag-chip-action][data-tag-id="{REVIEW_TAG_ID}"]'
        ).wait_for()
        page.locator("#inspectorTagSearch").press("Escape")
        assert page.locator("#inspectorTagSearch").input_value() == ""
        assert page.evaluate("() => state.inspectorTagSearchText") == ""
        assert page.evaluate("() => document.activeElement?.id") == "inspectorTagSearch"
        assert page.locator("#lightbox").is_visible()
        assert page.locator("#lightboxTitle").inner_text() == "ITEM_072.JPG"
        page.evaluate("""() => {
          const focusable = [...document.querySelector('#inspector').querySelectorAll(
            'button:not([disabled]), input:not([disabled]), select:not([disabled]), '
              + 'textarea:not([disabled]), a[href], [tabindex]:not([tabindex="-1"])'
          )].filter((element) => element.getClientRects().length > 0);
          focusable.at(-1)?.focus({ preventScroll: true });
        }""")
        page.keyboard.press("Tab")
        assert page.locator("#lightboxBackButton").evaluate(
            "element => document.activeElement === element"
        )
        assert page.locator("#lightboxTitle").inner_text() == "ITEM_072.JPG"
        assert page.locator("#lightboxPosition").inner_text() == "72 / 72 · 还有更多"
        assert page.locator("#lightboxBackLabel").inner_text() == "返回网格"
        assert page.locator("#lightboxNextButton").is_enabled()
        lightbox_history_length = page.evaluate("() => history.length")

        with page.expect_response(
            lambda response: "/v1/assets?" in response.url
            and parse_qs(urlparse(response.url).query).get("cursor") == ["page-2"]
        ) as page_two_response:
            page.locator("#lightboxNextButton").focus()
            page.keyboard.press("Space")
        assert page_two_response.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_073.JPG'"
            " && document.querySelector('#assetFileName')?.textContent === 'ITEM_073.JPG'"
        )
        page.wait_for_function("() => document.activeElement?.id === 'lightboxNextButton'")
        assert page.locator("#lightboxPosition").inner_text() == "73 / 74"
        page.keyboard.press("Space")
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_074.JPG'"
        )
        page.wait_for_function("() => document.activeElement?.id === 'lightboxPreviousButton'")
        assert page.locator("#lightbox:not(.hidden)").is_visible()
        page.keyboard.press("Space")
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_073.JPG'"
        )
        page.wait_for_function("() => document.activeElement?.id === 'lightboxPreviousButton'")
        assert page.locator(
            f'#assetGrid > .asset-card[data-asset-id="{asset_id(73)}"] > .asset-card-main'
        ).get_attribute("aria-pressed") == "true"
        assert page.locator("#assetGrid > .asset-card").count() == 74
        page.screenshot(path="/tmp/imageall-single-photo-pagination-synthetic.png", full_page=True)

        preview_before_refresh = page.evaluate(
            """() => {
              setLightboxScale(2);
              state.lightboxViewportOffsetX = 42;
              state.lightboxViewportOffsetY = -28;
              syncLightboxViewport();
              scheduleWorkspaceHistoryCheckpoint();
              return {
                scale: state.lightboxViewportScale,
                offsetX: state.lightboxViewportOffsetX,
                offsetY: state.lightboxViewportOffsetY,
              };
            }"""
        )
        assert preview_before_refresh["scale"] == 2
        page.wait_for_function(
            "assetID => history.state?.imageAllWorkspace?.context?.galleryLightbox?.assetID === assetID",
            arg=asset_id(73),
            timeout=2_500,
        )
        assert page.evaluate("() => history.length") == lightbox_history_length
        page.reload(wait_until="networkidle")
        page.locator("#lightbox:not(.hidden)").wait_for()
        page.wait_for_function(
            "expected => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_073.JPG' "
            "&& state.assets.length === 74 "
            "&& state.lightboxViewportScale === expected.scale "
            "&& state.lightboxViewportOffsetX === expected.offsetX "
            "&& state.lightboxViewportOffsetY === expected.offsetY",
            arg=preview_before_refresh,
        )
        assert page.evaluate("() => visibleWorkspaceRoute()") == "gallery"
        assert page.locator("#lightboxPosition").inner_text() == "73 / 74"
        assert page.locator(
            f'#assetGrid > .asset-card[data-asset-id="{asset_id(73)}"] > .asset-card-main'
        ).get_attribute("aria-pressed") == "true"
        history_after_preview_refresh = page.evaluate("() => JSON.stringify(history.state)")
        assert "ITEM_073.JPG" not in history_after_preview_refresh
        assert "/v1/assets/" not in history_after_preview_refresh
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "lightbox"
        page.screenshot(path="/tmp/imageall-single-photo-refresh-continuity.png", full_page=True)

        page.evaluate("() => history.back()")
        page.locator("#lightbox").wait_for(state="hidden", timeout=2_500)
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.galleryLightbox ?? null"
        ) is None
        assert page.locator(
            f'#assetGrid > .asset-card[data-asset-id="{asset_id(73)}"] > .asset-card-main'
        ).get_attribute("aria-pressed") == "true"
        page.evaluate("() => history.forward()")
        page.locator("#lightbox:not(.hidden)").wait_for(timeout=2_500)
        page.wait_for_function(
            "expected => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_073.JPG' "
            "&& state.lightboxViewportScale === expected.scale "
            "&& state.lightboxViewportOffsetX === expected.offsetX "
            "&& state.lightboxViewportOffsetY === expected.offsetY",
            arg=preview_before_refresh,
        )

        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            f"() => document.activeElement?.closest('.asset-card')?.dataset.assetId === "
            f"'{asset_id(73)}'"
        )
        assert page.locator(
            f'#assetGrid > .asset-card[data-asset-id="{asset_id(73)}"] > .asset-card-main'
        ).get_attribute("aria-pressed") == "true"
        assert page.locator("#libraryScroll").evaluate("element => element.scrollTop") > 0

        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        page.keyboard.press("ArrowRight")
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_074.JPG'"
        )
        assert page.locator("#lightboxNextButton").is_disabled()
        page.keyboard.press("ArrowLeft")
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_073.JPG'"
        )
        page.keyboard.press("Space")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            f"() => document.activeElement?.closest('.asset-card')?.dataset.assetId === "
            f"'{asset_id(73)}'"
        )

        page.set_viewport_size({"width": 390, "height": 844})
        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert page.locator("#lightboxBackButton").is_visible()
        assert not page.locator("#lightbox").evaluate(
            "element => element.classList.contains('library-docked')"
        )
        assert page.locator("#lightbox").get_attribute("aria-modal") == "true"
        assert page.locator("#appView").evaluate("element => element.inert")
        assert page.locator("#lightboxGestureHint").is_visible()
        assert "左右滑动切换" in page.locator("#lightboxStage").get_attribute("aria-label")
        page.screenshot(
            path="/tmp/imageall-single-photo-gesture-hint-narrow.png",
            full_page=True,
        )
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions

        gesture_history_length = page.evaluate("() => history.length")
        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 300, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 72, "y": 438},
            {"type": "pointerup", "pointerId": 1, "x": 72, "y": 438},
        ])
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_074.JPG'"
        )
        assert page.locator("#lightboxGestureHint").is_hidden()
        assert page.evaluate("() => history.length") == gesture_history_length

        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 180, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 150, "y": 434},
            {"type": "pointerup", "pointerId": 1, "x": 150, "y": 434},
        ])
        page.wait_for_timeout(180)
        assert page.locator("#lightboxTitle").inner_text() == "ITEM_074.JPG"

        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 190, "y": 300},
            {"type": "pointermove", "pointerId": 1, "x": 198, "y": 570},
            {"type": "pointerup", "pointerId": 1, "x": 198, "y": 570},
        ])
        page.wait_for_timeout(180)
        assert page.locator("#lightboxTitle").inner_text() == "ITEM_074.JPG"

        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 70, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 304, "y": 424},
            {"type": "pointerup", "pointerId": 1, "x": 304, "y": 424},
        ])
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'ITEM_073.JPG'"
        )

        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 145, "y": 430},
            {"type": "pointerdown", "pointerId": 2, "x": 245, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 95, "y": 430},
            {"type": "pointermove", "pointerId": 2, "x": 295, "y": 430},
            {"type": "pointerup", "pointerId": 2, "x": 295, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 125, "y": 452},
            {"type": "pointerup", "pointerId": 1, "x": 125, "y": 452},
        ])
        pinch_state = page.evaluate(
            """() => ({
              title: document.querySelector('#lightboxTitle').textContent,
              scale: state.lightboxViewportScale,
              offsetX: state.lightboxViewportOffsetX,
              offsetY: state.lightboxViewportOffsetY,
              historyLength: history.length,
            })"""
        )
        assert pinch_state["title"] == "ITEM_073.JPG"
        assert pinch_state["scale"] > 1.5, pinch_state
        assert abs(pinch_state["offsetX"]) + abs(pinch_state["offsetY"]) > 0, pinch_state
        assert pinch_state["historyLength"] == gesture_history_length

        page.locator("#lightboxZoomResetButton").click()
        page.wait_for_function("() => state.lightboxViewportScale === 1")
        page.screenshot(path="/tmp/imageall-single-photo-pagination-narrow.png", full_page=True)
        page.locator("#closeLightboxButton").click()

        page.set_viewport_size({"width": 1440, "height": 900})
        page.locator("#reviewNavigationButton").click()
        page.locator(f'[data-review-overview-tag-id="{REVIEW_TAG_ID}"]').click()
        page.locator("#reviewQueueLayout:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelectorAll('#reviewGrid > .review-card').length >= 48"
        )

        review_pagination_enabled["value"] = True
        page.locator('[data-review-index="20"] > .review-card-main').click()
        page.locator("#reviewQueuePane").evaluate("element => { element.scrollTop = 320; }")
        review_append_baseline = page.evaluate(
            """
            () => {
              const originalSyncReviewCardSelection = syncReviewCardSelection;
              globalThis.__reviewSyncCardCalls = 0;
              globalThis.__reviewBaselineCards = [
                ...document.querySelectorAll("#reviewGrid > .review-card")
              ];
              syncReviewCardSelection = (...args) => {
                globalThis.__reviewSyncCardCalls += 1;
                return originalSyncReviewCardSelection(...args);
              };
              return {
                count: globalThis.__reviewBaselineCards.length,
                scrollTop: document.querySelector("#reviewQueuePane").scrollTop,
                selectedIDs: [...state.review.selectedAssetIDs],
                focusedKey: document.activeElement?.closest(".review-card")
                  ?.dataset.reviewKey || null,
              };
            }
            """
        )
        assert review_append_baseline["count"] == 48
        assert review_append_baseline["scrollTop"] > 0
        page.evaluate(
            """() => {
              if (state.review.autoLoadFrame != null) {
                cancelAnimationFrame(state.review.autoLoadFrame);
                state.review.autoLoadFrame = null;
              }
              state.review.nextCursor = "review-page-2";
              return loadReviewQueue({
                append: true,
                preserveUnchangedGrid: true,
                schedulePagination: false,
              });
            }"""
        )
        page.wait_for_function(
            "() => state.review.items.length === 49 "
            "&& state.review.nextCursor === 'review-page-3'"
        )
        review_append_sync = page.evaluate(
            """
            () => ({
              count: globalThis.__reviewSyncCardCalls,
              retained: globalThis.__reviewBaselineCards.every(
                (card, index) => document.querySelector("#reviewGrid").children[index] === card
              ),
              scrollTop: document.querySelector("#reviewQueuePane").scrollTop,
              selectedIDs: [...state.review.selectedAssetIDs],
              focusedKey: document.activeElement?.closest(".review-card")
                ?.dataset.reviewKey || null,
            })
            """
        )
        assert review_append_sync["count"] == 1, review_append_sync
        assert review_append_sync["retained"] is True, review_append_sync
        assert review_append_sync["scrollTop"] == review_append_baseline["scrollTop"], (
            review_append_baseline,
            review_append_sync,
        )
        assert review_append_sync["selectedIDs"] == review_append_baseline["selectedIDs"]
        assert review_append_sync["focusedKey"] == review_append_baseline["focusedKey"]

        page.evaluate(
            """
            () => {
              const stale = document.createElement("div");
              stale.className = "review-card";
              stale.dataset.reviewKey = "stale-review-dom-only";
              document.querySelector("#reviewGrid").append(stale);
              globalThis.__reviewSyncCardCalls = 0;
            }
            """
        )
        page.evaluate(
            "() => loadReviewQueue({ append: true, preserveUnchangedGrid: true, "
            "schedulePagination: false })"
        )
        page.wait_for_function(
            "() => state.review.items.length === 50 && state.review.nextCursor === null"
        )
        review_append_fallback = page.evaluate(
            """
            () => ({
              count: globalThis.__reviewSyncCardCalls,
              staleCount: document.querySelectorAll(
                '#reviewGrid > [data-review-key="stale-review-dom-only"]'
              ).length,
              cardCount: document.querySelectorAll("#reviewGrid > .review-card").length,
              scrollTop: document.querySelector("#reviewQueuePane").scrollTop,
            })
            """
        )
        assert review_append_fallback["count"] == 50, review_append_fallback
        assert review_append_fallback["staleCount"] == 0, review_append_fallback
        assert review_append_fallback["cardCount"] == 50, review_append_fallback
        assert review_append_fallback["scrollTop"] == review_append_baseline["scrollTop"]
        page.locator("#reviewQueuePane").evaluate("element => { element.scrollTop = 0; }")

        # Review selection mirrors the Mac grid: marquee, Command-click,
        # Shift-click, Command-A and P/X/U all target the full frozen selection.
        review_grid_box = page.locator("#reviewGrid").bounding_box()
        assert review_grid_box
        marquee_start = page.evaluate(
            """() => {
              const grid = document.querySelector('#reviewGrid');
              const rect = grid.getBoundingClientRect();
              for (let y = rect.top + 1; y <= Math.min(rect.bottom - 1, rect.top + 120); y += 1) {
                for (let x = rect.left + 1; x <= Math.min(rect.right - 1, rect.left + 420); x += 1) {
                  const target = document.elementFromPoint(x, y);
                  if (target && grid.contains(target) && !target.closest('.review-card')) {
                    return { x, y };
                  }
                }
              }
              return null;
            }"""
        )
        assert marquee_start is not None, review_grid_box
        page.mouse.move(marquee_start["x"], marquee_start["y"])
        page.mouse.down()
        page.mouse.move(
            review_grid_box["x"] + 270,
            review_grid_box["y"] + 142,
            steps=6,
        )
        page.mouse.up()
        marquee_selected_count = page.locator(
            '#reviewGrid > .review-card > .review-card-main[aria-pressed="true"]'
        ).count()
        assert marquee_selected_count >= 2, {
            "start": marquee_start,
            "grid": review_grid_box,
            "selected": marquee_selected_count,
        }
        assert page.locator("#reviewSelectionSummary").inner_text().startswith("已选择")

        page.locator('[data-review-index="0"]').click()
        page.locator('[data-review-index="1"]').click(modifiers=["Meta"])
        page.locator('[data-review-index="3"]').click(modifiers=["Shift"])
        assert page.locator(
            '#reviewGrid > .review-card > .review-card-main[aria-pressed="true"]'
        ).count() == 3
        assert "已选择 3 张照片" in page.locator("#reviewSelectionSummary").inner_text()
        assert page.locator("#reviewFileName").inner_text() == "REVIEW_004.JPG"
        page.locator('#reviewDetail .review-action[data-action="reject"]').click()
        page.wait_for_function(
            "() => document.querySelectorAll("
            "'#reviewGrid > .review-card > .review-card-main[aria-pressed=\"true\"]'"
            ").length === 1"
        )
        assert review_decisions[-1]["action"] == "reject"
        assert review_decisions[-1]["assetIDs"] == [
            asset_id(2), asset_id(3), asset_id(4),
        ]
        assert page.locator("#undoTagButton").is_disabled()
        assert page.locator("#undoReviewButton").is_visible()
        assert page.locator("#undoReviewButton").is_enabled()
        assert page.locator("#reviewUndoButton").is_visible()
        assert page.locator("#reviewUndoButton").is_enabled()
        page.screenshot(path="/tmp/imageall-review-undo-toolbar-synthetic.png", full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        assert page.locator("#reviewUndoButton").is_visible()
        undo_box = page.locator("#reviewUndoButton").bounding_box()
        assert undo_box
        assert undo_box["x"] >= 0
        assert undo_box["x"] + undo_box["width"] <= 390
        undo_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert undo_dimensions["scroll"] <= undo_dimensions["viewport"], undo_dimensions
        page.screenshot(path="/tmp/imageall-review-undo-toolbar-narrow.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 900})
        page.keyboard.press("Meta+z")
        page.wait_for_function(
            "() => document.querySelector('#undoReviewButton')?.classList.contains('hidden')"
            " && document.querySelector('#reviewUndoButton')?.classList.contains('hidden')"
        )
        assert review_undos[-1]["undoID"] == "eeeeeeee-1111-4222-8333-eeeeeeeeeeee"

        page.locator('[data-review-index="0"]').click()
        page.locator('[data-review-index="1"]').click(modifiers=["Meta"])
        page.keyboard.press("u")
        assert len(review_decisions) == 1
        assert page.locator("#reviewFileName").inner_text() == "REVIEW_003.JPG"
        assert page.locator('[data-review-index="0"]').get_attribute("data-review-key").startswith(asset_id(1))

        page.keyboard.press("Meta+a")
        page.wait_for_function(
            """
            () => {
              const cards = document.querySelectorAll('#reviewGrid > .review-card');
              const selected = document.querySelectorAll(
                '#reviewGrid > .review-card > .review-card-main[aria-pressed="true"]'
              );
              return cards.length > 0 && selected.length === cards.length;
            }
            """
        )
        loaded_review_count = page.locator("#reviewGrid > .review-card").count()
        assert f"已选择 {loaded_review_count} 项" in page.locator("#reviewSummary").inner_text()
        page.screenshot(path="/tmp/imageall-review-multiselection-synthetic.png", full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        review_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert review_dimensions["scroll"] <= review_dimensions["viewport"], review_dimensions
        assert page.locator('#reviewDetail .review-action[data-action="accept"]').is_visible()
        page.screenshot(path="/tmp/imageall-review-multiselection-narrow.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 900})

        page.locator('[data-review-index="47"]').dispatch_event("click")
        page.wait_for_function(
            "() => document.querySelector('#reviewFileName')?.textContent === 'REVIEW_048.JPG'"
        )
        page.locator("#reviewOpenLightboxButton").click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        review_page_two_loaded = any(
            query.get("cursor") == ["review-page-2"] for query in review_queries
        )
        loaded_review_count = page.locator("#reviewGrid > .review-card").count()
        expected_review_position = f"48 / {loaded_review_count}"
        if not review_page_two_loaded:
            expected_review_position += " · 还有更多"
        assert page.locator("#lightboxPosition").inner_text() == expected_review_position
        assert page.locator("#lightboxBackLabel").inner_text() == "返回审核"
        page.locator("#lightboxNextButton").focus()
        if review_page_two_loaded:
            page.keyboard.press("Space")
        else:
            with page.expect_response(
                lambda response: "/v1/review/queue?" in response.url
                and parse_qs(urlparse(response.url).query).get("cursor") == ["review-page-2"]
            ) as review_page_two_response:
                page.keyboard.press("Space")
            assert review_page_two_response.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'REVIEW_049.JPG'"
            " && document.querySelector('#reviewFileName')?.textContent === 'REVIEW_049.JPG'"
        )
        page.wait_for_function("() => document.activeElement?.id === 'lightboxNextButton'")
        assert page.locator("#lightboxPosition").inner_text() == "49 / 50"
        assert page.locator(
            '[data-review-index="48"] > .review-card-main'
        ).get_attribute("aria-pressed") == "true"
        set_lightbox_scale = page.evaluate("() => { setLightboxScale(1); return history.length; }")
        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 760, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 250, "y": 436},
            {"type": "pointerup", "pointerId": 1, "x": 250, "y": 436},
        ])
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'REVIEW_050.JPG' "
            "&& document.querySelector('#reviewFileName')?.textContent === 'REVIEW_050.JPG'"
        )
        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 250, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 760, "y": 436},
            {"type": "pointerup", "pointerId": 1, "x": 760, "y": 436},
        ])
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'REVIEW_049.JPG' "
            "&& document.querySelector('#reviewFileName')?.textContent === 'REVIEW_049.JPG'"
        )
        assert page.evaluate("() => history.length") == set_lightbox_scale
        page.screenshot(path="/tmp/imageall-review-single-photo-pagination.png", full_page=True)

        review_preview_before_refresh = page.evaluate(
            """() => {
              setLightboxScale(1.6);
              state.lightboxViewportOffsetX = 24;
              state.lightboxViewportOffsetY = -18;
              syncLightboxViewport();
              scheduleWorkspaceHistoryCheckpoint();
              return {
                scale: state.lightboxViewportScale,
                offsetX: state.lightboxViewportOffsetX,
                offsetY: state.lightboxViewportOffsetY,
              };
            }"""
        )
        page.wait_for_function(
            "assetID => history.state?.imageAllWorkspace?.context?.reviewLightbox?.assetID === assetID",
            arg=asset_id(49),
            timeout=2_500,
        )
        page.reload(wait_until="networkidle")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for()
        page.locator("#lightbox:not(.hidden)").wait_for()
        page.wait_for_function(
            "expected => document.querySelector('#lightboxTitle')?.textContent === 'REVIEW_049.JPG' "
            "&& state.review.items.length === 50 "
            "&& state.lightboxViewportScale === expected.scale "
            "&& state.lightboxViewportOffsetX === expected.offsetX "
            "&& state.lightboxViewportOffsetY === expected.offsetY",
            arg=review_preview_before_refresh,
        )
        assert page.evaluate("() => visibleWorkspaceRoute()") == "review"
        assert page.locator("#lightboxPosition").inner_text() == "49 / 50"
        assert page.locator(
            '[data-review-index="48"] > .review-card-main'
        ).get_attribute("aria-pressed") == "true"
        history_after_review_preview_refresh = page.evaluate("() => JSON.stringify(history.state)")
        assert "REVIEW_049.JPG" not in history_after_review_preview_refresh
        assert "/v1/assets/" not in history_after_review_preview_refresh
        page.screenshot(path="/tmp/imageall-review-preview-refresh-continuity.png", full_page=True)

        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        assert page.locator(
            '[data-review-index="48"] > .review-card-main'
        ).get_attribute("aria-pressed") == "true"
        page.locator("#closeReviewButton").click()
        page.locator("#reviewWorkspace").wait_for(state="hidden")

        page.evaluate(
            """() => {
              const nextState = structuredClone(history.state);
              nextState.imageAllWorkspace.context.galleryLightbox = {
                assetID: 'missing-preview-asset',
                scale: 4,
                offsetX: 999,
                offsetY: -999,
                videoTime: 0,
              };
              history.replaceState(nextState, '', location.href);
            }"""
        )
        page.reload(wait_until="networkidle")
        page.locator("#appView:not(.hidden)").wait_for()
        assert page.evaluate("() => visibleWorkspaceRoute()") == "gallery"
        assert page.locator("#lightbox").is_hidden()
        assert page.locator("#lightboxTitle").inner_text() != "missing-preview-asset"

        page.locator(
            f'#assetGrid > .asset-card[data-asset-id="{asset_id(2)}"] > .asset-card-main'
        ).click()
        page.locator("#worldMapNavigationButton").click()
        page.locator("#worldMapWorkspace:not(.hidden)").wait_for()
        page.evaluate(
            "clusterID => loadWorldMapSelection(clusterID)",
            WORLD_MAP_CLUSTER_ID,
        )
        page.locator("#worldMapPhotoStrip .world-map-photo-card").nth(1).wait_for()
        page.locator(
            f'[data-world-map-asset-id="{asset_id(2)}"]'
        ).click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'MAP_002.JPG'"
        )
        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 250, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 760, "y": 434},
            {"type": "pointerup", "pointerId": 1, "x": 760, "y": 434},
        ])
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'MAP_001.JPG'"
        )
        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 760, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 250, "y": 434},
            {"type": "pointerup", "pointerId": 1, "x": 250, "y": 434},
        ])
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'MAP_002.JPG'"
        )
        world_map_preview_before_refresh = page.evaluate(
            """() => {
              state.worldMap.viewport = {
                west: 120.9,
                south: 30.8,
                east: 122.0,
                north: 31.8,
              };
              setLightboxScale(1.7);
              state.lightboxViewportOffsetX = 26;
              state.lightboxViewportOffsetY = -16;
              syncLightboxViewport();
              scheduleWorkspaceHistoryCheckpoint();
              return {
                scale: state.lightboxViewportScale,
                offsetX: state.lightboxViewportOffsetX,
                offsetY: state.lightboxViewportOffsetY,
              };
            }"""
        )
        page.wait_for_function(
            "assetID => history.state?.imageAllWorkspace?.context?.worldMapLightbox?.assetID === assetID",
            arg=asset_id(2),
            timeout=2_500,
        )
        page.reload(wait_until="networkidle")
        page.locator("#worldMapWorkspace:not(.hidden)").wait_for()
        page.locator("#lightbox:not(.hidden)").wait_for()
        page.wait_for_function(
            "expected => document.querySelector('#lightboxTitle')?.textContent === 'MAP_002.JPG' "
            "&& state.worldMap.selectedClusterID === 'cluster-shanghai' "
            "&& state.lightboxViewportScale === expected.scale "
            "&& state.lightboxViewportOffsetX === expected.offsetX "
            "&& state.lightboxViewportOffsetY === expected.offsetY",
            arg=world_map_preview_before_refresh,
        )
        assert page.evaluate("() => visibleWorkspaceRoute()") == "worldMap"
        assert page.locator("#worldMapDetailName").inner_text() == "上海"
        assert page.locator("#lightboxPosition").inner_text() == "2 / 2"
        assert page.evaluate("() => state.selectedAssetID") == asset_id(2)
        assert world_map_snapshot_queries[-1].get("west") == ["120.9"]
        assert world_map_snapshot_queries[-1].get("south") == ["30.8"]
        history_after_world_map_refresh = page.evaluate("() => JSON.stringify(history.state)")
        assert "MAP_002.JPG" not in history_after_world_map_refresh
        assert "/v1/assets/" not in history_after_world_map_refresh
        page.screenshot(path="/tmp/imageall-world-map-preview-refresh-continuity.png", full_page=True)
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            f"() => document.activeElement?.dataset.worldMapAssetId === '{asset_id(2)}'"
        )

        page.evaluate(
            """() => {
              const nextState = structuredClone(history.state);
              nextState.imageAllWorkspace.context.worldMapLightbox = {
                assetID: 'missing-map-preview',
                scale: 3,
                offsetX: 400,
                offsetY: -400,
                videoTime: 0,
              };
              history.replaceState(nextState, '', location.href);
            }"""
        )
        page.reload(wait_until="networkidle")
        page.locator("#worldMapWorkspace:not(.hidden)").wait_for()
        assert page.locator("#lightbox").is_hidden()
        assert page.locator("#worldMapDetailName").inner_text() == "上海"

        page.evaluate(
            """() => {
              const nextState = structuredClone(history.state);
              nextState.imageAllWorkspace.context.worldMapClusterID = 'missing-map-cluster';
              nextState.imageAllWorkspace.context.worldMapLightbox = {
                assetID: 'missing-map-preview',
                scale: 3,
                offsetX: 400,
                offsetY: -400,
                videoTime: 0,
              };
              history.replaceState(nextState, '', location.href);
            }"""
        )
        page.reload(wait_until="networkidle")
        page.locator("#worldMapWorkspace:not(.hidden)").wait_for()
        assert page.locator("#lightbox").is_hidden()
        assert page.locator("#worldMapDetail").is_hidden()
        assert page.evaluate("() => state.worldMap.selectedClusterID") is None

        page.evaluate(
            """assetIDs => {
              document.querySelector('#worldMapWorkspace').classList.add('hidden');
              document.querySelector('#slimmingWorkspace').classList.remove('hidden');
              state.slimming.mediaKind = 'image';
              state.slimming.members = assetIDs.map((id, index) => ({
                id,
                fileName: `SLIM_GESTURE_${index + 1}.JPG`,
                availability: 'available',
                contentRevision: 1,
              }));
              openLightbox('slimming', assetIDs[0]);
            }""",
            [asset_id(1), asset_id(2)],
        )
        page.locator("#lightbox:not(.hidden)").wait_for()
        dispatch_lightbox_touch(page, [
            {"type": "pointerdown", "pointerId": 1, "x": 760, "y": 430},
            {"type": "pointermove", "pointerId": 1, "x": 250, "y": 434},
            {"type": "pointerup", "pointerId": 1, "x": 250, "y": 434},
        ])
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent === 'SLIM_GESTURE_2.JPG'"
        )
        assert page.evaluate("() => state.lightboxContext") == "slimming"

        assert not page_errors, page_errors
        assert not console_errors, {
            "console": console_errors,
            "http": http_errors,
        }
        browser.close()

    print(
        "single-photo-navigation-browser: ok; "
        f"asset requests={len(asset_queries)}; loaded=74; "
        f"review batch decisions={len(review_decisions)}; review undos={len(review_undos)}; "
        f"tag undos={len(tag_undos)}"
    )


if __name__ == "__main__":
    main()
