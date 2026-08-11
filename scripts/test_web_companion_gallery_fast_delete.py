#!/usr/bin/env python3
import base64
import json
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8818"
SOURCE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
TAG_ID = "88888888-8888-8888-8888-888888888888"
ASSET_IDS = [f"71000000-0000-0000-0000-{index:012d}" for index in range(1, 89)]
TAG_DECISIONS = {asset_id: "unknown" for asset_id in ASSET_IDS}
FAVORITE_VALUES = {asset_id: asset_id == ASSET_IDS[2] for asset_id in ASSET_IDS}
PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def favorite_state(asset_id):
    is_favorite = FAVORITE_VALUES[asset_id]
    return {
        "assetID": asset_id,
        "isFavorite": is_favorite,
        "photosObservedValue": is_favorite,
        "syncStatus": "synced",
        "lastErrorCode": None,
    }


def asset_item(asset_id):
    index = ASSET_IDS.index(asset_id) + 1
    decision = TAG_DECISIONS[asset_id]
    return {
        "id": asset_id,
        "fileName": f"IMG_{index:04}.JPG",
        "sourceID": SOURCE_ID,
        "sourceName": "Apple Photos",
        "mediaKind": "image",
        "mediaType": "public.jpeg",
        "availability": "available",
        "contentRevision": index,
        "acceptedTagCount": 1 if decision == "accepted" else 0,
        "rejectedTagCount": 1 if decision == "rejected" else 0,
        "favorite": favorite_state(asset_id),
    }


def asset_detail(asset_id):
    item = asset_item(asset_id)
    index = ASSET_IDS.index(asset_id) + 1
    return {
        "assetID": asset_id,
        "sourceID": SOURCE_ID,
        "sourceName": "Apple Photos",
        "sourceState": "active",
        "fileName": item["fileName"],
        "relativePath": f"Synthetic/{item['fileName']}",
        "mediaKind": "image",
        "mediaType": "public.jpeg",
        "availability": "available",
        "contentRevision": index,
        "acceptedTagCount": item["acceptedTagCount"],
        "rejectedTagCount": item["rejectedTagCount"],
        "mediaCreatedAtMs": 1_735_689_600_000 + index * 1_000,
        "mediaModifiedAtMs": 1_735_776_000_000 + index * 1_000,
        "width": 4032,
        "height": 3024,
        "durationMs": None,
        "fingerprintSizeBytes": 2_500_000 + index,
        "tags": [{
            "tagID": TAG_ID,
            "displayName": "猫",
            "decision": TAG_DECISIONS[asset_id],
        }],
        "favorite": favorite_state(asset_id),
    }


def main():
    visible_ids = list(ASSET_IDS[:80])
    submitted_favorites = []
    submitted_removals = []
    removal = {"request": None}
    page_errors = []
    console_errors = []
    failed_resources = []

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
            lambda route: fulfill_json(route, {
                "authenticated": True,
                "authMode": "pairedDevice",
                "deviceName": "Synthetic Browser",
            }),
        )
        page.route(
            "**/v1/capabilities",
            lambda route: fulfill_json(route, {
                "protocolVersion": 1,
                "hostID": "55555555-5555-5555-5555-555555555555",
                "hostDisplayName": "Synthetic Mac",
                "hostAppVersion": "test",
                "capabilities": ["librarySlimming", "favorites"],
            }),
        )
        page.route(
            "**/v1/sources",
            lambda route: fulfill_json(route, [{
                "id": SOURCE_ID,
                "kind": "photos",
                "displayName": "Apple Photos",
                "state": "active",
            }]),
        )
        page.route("**/v1/tags", lambda route: fulfill_json(route, [{
            "id": TAG_ID,
            "displayName": "猫",
            "state": "active",
            "groupID": None,
        }]))
        page.route("**/v1/tag-groups", lambda route: fulfill_json(route, []))
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
        page.route(
            "**/v1/embedding-preparation?**",
            lambda route: fulfill_json(route, {
                "mediaKind": "image", "isAvailable": False, "activities": [],
            }),
        )
        page.route(
            "**/v1/sample-suggestions?**",
            lambda route: fulfill_json(route, {
                "mediaKind": "image",
                "isAvailable": False,
                "maximumSampleCount": 500,
                "activities": [],
            }),
        )
        page.route(
            "**/v1/tag-library-suggestions?**",
            lambda route: fulfill_json(route, {
                "mediaKind": "image",
                "maximumPendingCount": 500,
                "personalCentroidAvailable": False,
                "personalAdamWAvailable": False,
                "tags": [],
                "activities": [],
            }),
        )
        page.route(
            "**/v1/library-slimming/identical-cleanup/requests?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "requests": []}),
        )

        def handle_assets(route):
            query = parse_qs(urlparse(route.request.url).query)
            cursor = query.get("cursor", [None])[0]
            limit = int(query.get("limit", [72])[0])
            offset = 80 if cursor == "page-after-80" else (72 if cursor else 0)
            items = visible_ids[offset:offset + limit]
            next_cursor = "page2" if offset + len(items) < len(visible_ids) else None
            fulfill_json(route, {
                "items": [asset_item(asset_id) for asset_id in items],
                "nextCursor": next_cursor,
            })

        page.route("**/v1/assets?**", handle_assets)

        def handle_asset_detail(route):
            asset_id = route.request.url.split("/v1/assets/", 1)[1].split("/", 1)[0]
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
        def handle_selection_tags(route):
            selected_ids = route.request.post_data_json["assetIDs"]
            fulfill_json(route, [{
                "tagID": TAG_ID,
                "acceptedCount": sum(
                    TAG_DECISIONS[asset_id] == "accepted" for asset_id in selected_ids
                ),
                "rejectedCount": sum(
                    TAG_DECISIONS[asset_id] == "rejected" for asset_id in selected_ids
                ),
                "unknownCount": sum(
                    TAG_DECISIONS[asset_id] == "unknown" for asset_id in selected_ids
                ),
            }])

        page.route("**/v1/tags/selection", handle_selection_tags)

        submitted_tag_decisions = []

        def handle_tag_decisions(route):
            payload = route.request.post_data_json
            submitted_tag_decisions.append(payload)
            decision = "unknown" if payload["action"] == "clear" else payload["action"] + "ed"
            for asset_id in payload["assetIDs"]:
                TAG_DECISIONS[asset_id] = decision
            fulfill_json(route, {
                "operationID": payload["operationID"],
                "appliedAssetCount": len(payload["assetIDs"]),
                "replayed": False,
                "undoID": "cccccccc-1111-2222-3333-cccccccccccc",
            })

        page.route("**/v1/tag-decisions/batch", handle_tag_decisions)

        def handle_favorites(route):
            payload = route.request.post_data_json
            submitted_favorites.append(payload)
            changed_count = sum(
                FAVORITE_VALUES[asset_id] != payload["isFavorite"]
                for asset_id in payload["assetIDs"]
            )
            for asset_id in payload["assetIDs"]:
                FAVORITE_VALUES[asset_id] = payload["isFavorite"]
            fulfill_json(route, {
                "operationID": payload["operationID"],
                "changedCount": changed_count,
                "localOnlyCount": 0,
                "syncedCount": len(payload["assetIDs"]),
                "pendingCount": 0,
                "failedCount": 0,
                "states": [{
                    "assetID": asset_id,
                    "isFavorite": FAVORITE_VALUES[asset_id],
                    "photosObservedValue": FAVORITE_VALUES[asset_id],
                    "syncStatus": "synced",
                    "lastErrorCode": None,
                } for asset_id in payload["assetIDs"]],
                "replayed": False,
            })

        page.route("**/v1/favorites", handle_favorites)

        def handle_removals(route):
            if route.request.method == "POST":
                payload = route.request.post_data_json
                submitted_removals.append(payload)
                canonical_ids = sorted(set(payload["assetIDs"]))
                removal["request"] = {
                    "id": "77777777-4444-4444-4444-444444444444",
                    "operationID": payload["operationID"],
                    "scope": payload.get("scope"),
                    "jobID": payload.get("jobID"),
                    "clusterID": payload.get("clusterID"),
                    "mediaKind": payload["mediaKind"],
                    "assetIDs": canonical_ids,
                    "mode": payload["mode"],
                    "phase": "awaitingMac",
                    "progress": None,
                    "audit": None,
                    "message": "请回到 Mac 核对并确认删除当前图库选区",
                    "updatedAtMs": 1_700_000_002_000,
                }
                fulfill_json(route, removal["request"], status=202)
                return
            fulfill_json(route, {
                "mediaKind": "image",
                "requests": [removal["request"]] if removal["request"] else [],
            })

        page.route("**/v1/library-slimming/removals", handle_removals)
        page.route("**/v1/library-slimming/removals?**", handle_removals)

        page.goto(BASE_URL, wait_until="networkidle")
        cards = page.locator("#assetGrid .asset-card-main")
        assert cards.count() == 72
        cards.nth(10).click(modifiers=["Meta"])
        page.wait_for_function(
            "id => state.selectionMode && state.selectedAssetIDs.has(id)",
            arg=ASSET_IDS[10],
        )
        append_baseline = page.evaluate(
            """
            () => {
              const originalSyncAssetCard = syncAssetCard;
              globalThis.__gallerySyncAssetCardCalls = 0;
              globalThis.__gallerySyncAssetCardStacks = [];
              globalThis.__appendBaselineCards = [
                ...document.querySelectorAll("#assetGrid > .asset-card")
              ];
              syncAssetCard = (...args) => {
                globalThis.__gallerySyncAssetCardCalls += 1;
                if (globalThis.__gallerySyncAssetCardStacks.length < 3) {
                  globalThis.__gallerySyncAssetCardStacks.push(new Error().stack);
                }
                return originalSyncAssetCard(...args);
              };
              const scroll = document.querySelector("#libraryScroll");
              scroll.scrollTop = 520;
              return {
                count: globalThis.__appendBaselineCards.length,
                scrollTop: scroll.scrollTop,
                selectedIDs: [...state.selectedAssetIDs],
                focusedAssetID: document.activeElement
                  ?.closest("[data-asset-id]")?.dataset.assetId || null,
              };
            }
            """
        )
        assert append_baseline["count"] == 72
        assert append_baseline["scrollTop"] > 0
        page.evaluate("() => loadAssets({ append: true, preserveSelection: true })")
        page.wait_for_function("() => state.assets.length === 80 && state.nextCursor === null")
        assert cards.count() == 80
        append_sync = page.evaluate(
            """
            () => ({
              count: globalThis.__gallerySyncAssetCardCalls,
              stacks: globalThis.__gallerySyncAssetCardStacks,
              retained: globalThis.__appendBaselineCards.every(
                (card, index) => document.querySelector("#assetGrid").children[index] === card
              ),
              scrollTop: document.querySelector("#libraryScroll").scrollTop,
              selectedIDs: [...state.selectedAssetIDs],
              focusedAssetID: document.activeElement
                ?.closest("[data-asset-id]")?.dataset.assetId || null,
            })
            """
        )
        assert append_sync["count"] == 8, append_sync
        assert append_sync["retained"] is True, append_sync
        assert append_sync["scrollTop"] == append_baseline["scrollTop"], append_sync
        assert append_sync["selectedIDs"] == append_baseline["selectedIDs"], append_sync
        assert append_sync["focusedAssetID"] == append_baseline["focusedAssetID"], append_sync

        visible_ids.extend(ASSET_IDS[80:])
        page.evaluate(
            """
            () => {
              const stale = document.createElement("div");
              stale.className = "asset-card";
              stale.dataset.assetId = "stale-dom-only-card";
              document.querySelector("#assetGrid").append(stale);
              state.nextCursor = "page-after-80";
              globalThis.__gallerySyncAssetCardCalls = 0;
              globalThis.__gallerySyncAssetCardStacks = [];
            }
            """
        )
        page.evaluate("() => loadAssets({ append: true, preserveSelection: true })")
        page.wait_for_function("() => state.assets.length === 88 && state.nextCursor === null")
        append_fallback = page.evaluate(
            """
            () => ({
              count: globalThis.__gallerySyncAssetCardCalls,
              staleCount: document.querySelectorAll(
                '#assetGrid > [data-asset-id="stale-dom-only-card"]'
              ).length,
              cardCount: document.querySelectorAll("#assetGrid > .asset-card").length,
              scrollTop: document.querySelector("#libraryScroll").scrollTop,
            })
            """
        )
        assert append_fallback["count"] == 88, append_fallback
        assert append_fallback["staleCount"] == 0, append_fallback
        assert append_fallback["cardCount"] == 88, append_fallback
        assert append_fallback["scrollTop"] == append_baseline["scrollTop"], append_fallback

        page.evaluate(
            """
            () => {
              const originalRenderSelectionInspector = renderSelectionInspector;
              globalThis.__gallerySyncAssetCardCalls = 0;
              globalThis.__gallerySyncAssetCardStacks = [];
              globalThis.__selectionInspectorRenderCalls = 0;
              renderSelectionInspector = (...args) => {
                globalThis.__selectionInspectorRenderCalls += 1;
                return originalRenderSelectionInspector(...args);
              };
            }
            """
        )

        cards.nth(2).click()
        cards.nth(55).click(modifiers=["Meta"])
        page.wait_for_function("() => state.selectedAssetIDs.size === 2")
        cards.nth(60).click(modifiers=["Meta", "Shift"])
        page.wait_for_function("() => state.selectedAssetIDs.size === 7")
        cards.nth(2).click()
        page.wait_for_function("() => state.selectedAssetIDs.size === 1")
        cards.nth(55).click(modifiers=["Meta"])
        page.wait_for_function("() => state.selectedAssetIDs.size === 2")
        selection_sync = page.evaluate(
            "() => ({ count: globalThis.__gallerySyncAssetCardCalls, "
            "stacks: globalThis.__gallerySyncAssetCardStacks, "
            "inspectorRenders: globalThis.__selectionInspectorRenderCalls })"
        )
        assert selection_sync["count"] == 0, selection_sync
        # One render mounts the inspector and one may publish the debounced
        # Host aggregate when this real pointer sequence crosses 120 ms.
        assert selection_sync["inspectorRenders"] <= 2, selection_sync

        page.evaluate(
            "() => { globalThis.__gallerySyncAssetCardCalls = 0; "
            "globalThis.__gallerySyncAssetCardStacks = []; }"
        )
        favorite_card = page.locator(f'[data-asset-id="{ASSET_IDS[10]}"]')
        favorite_card.hover()
        with page.expect_response("**/v1/favorites"):
            favorite_card.locator(".asset-card-favorite").click()
        page.wait_for_function(
            "id => state.assets.find(asset => asset.id === id)?.favorite?.isFavorite === true",
            arg=ASSET_IDS[10],
        )
        favorite_sync = page.evaluate(
            "() => ({ count: globalThis.__gallerySyncAssetCardCalls, "
            "stacks: globalThis.__gallerySyncAssetCardStacks })"
        )
        assert favorite_sync["count"] == 1, favorite_sync
        assert submitted_favorites[-1]["assetIDs"] == [ASSET_IDS[10]]
        assert submitted_favorites[-1]["isFavorite"] is True

        page.wait_for_selector(
            f'#selectionInspectorTags [data-tag-chip-action][data-tag-id="{TAG_ID}"]'
        )
        page.evaluate(
            "() => { globalThis.__gallerySyncAssetCardCalls = 0; "
            "globalThis.__gallerySyncAssetCardStacks = []; }"
        )
        page.locator(
            f'#selectionInspectorTags [data-tag-chip-action][data-tag-id="{TAG_ID}"]'
        ).click()
        page.wait_for_function(
            "ids => ids.every(id => state.assets.find(asset => asset.id === id)"
            "?.acceptedTagCount === 1)",
            arg=[ASSET_IDS[2], ASSET_IDS[55]],
        )
        tag_sync = page.evaluate(
            "() => ({ count: globalThis.__gallerySyncAssetCardCalls, "
            "stacks: globalThis.__gallerySyncAssetCardStacks })"
        )
        assert tag_sync["count"] == 2, tag_sync
        assert set(submitted_tag_decisions[-1]["assetIDs"]) == {
            ASSET_IDS[2], ASSET_IDS[55]
        }
        assert submitted_tag_decisions[-1]["action"] == "accept"
        assert page.locator("#selectionInspectorDeleteButton").is_visible()
        assert not page.locator("#selectionInspectorDeleteButton").is_disabled()

        page.keyboard.press("Meta+k")
        page.locator("#commandPalette[open]").wait_for()
        assert page.locator("#commandList").get_by_text(
            "删除所选照片并释放空间", exact=True
        ).is_visible()
        page.keyboard.press("Escape")

        page.locator("#libraryScroll").evaluate("element => { element.scrollTop = 700; }")
        scroll_before = page.locator("#libraryScroll").evaluate("element => element.scrollTop")
        page.locator("#selectionInspectorDeleteButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        assert page.locator("#confirmDialog").get_attribute("data-tone") == "danger"
        confirmation = page.locator("#confirmDialogMessage").inner_text()
        assert "其中 1 项有红心" in confirmation
        assert "文件夹来源会在身份核验后永久删除" in confirmation
        assert "Apple Photos 项只会进入系统“最近删除”" in confirmation
        assert not submitted_removals
        page.locator("#confirmActionButton").click()
        page.wait_for_function("() => document.querySelector('#galleryRemovalStatus').textContent.includes('等待 Mac')")

        assert len(submitted_removals) == 1
        payload = submitted_removals[0]
        assert payload["scope"] == "gallerySelection"
        assert payload["jobID"] is None
        assert payload["clusterID"] is None
        assert payload["mode"] == "releaseSourceSpace"
        assert set(payload["assetIDs"]) == {ASSET_IDS[2], ASSET_IDS[55]}

        hidden_ids = set(payload["assetIDs"])
        visible_ids[:] = [asset_id for asset_id in visible_ids if asset_id not in hidden_ids]
        removal["request"].update({
            "phase": "completed",
            "progress": {
                "phase": "completedAsset",
                "completedAssetCount": 2,
                "totalAssetCount": 2,
                "copiedBytes": 0,
                "totalFileBytes": 0,
            },
            "audit": {
                "hiddenAssetIDs": sorted(hidden_ids),
                "recycledEntryIDs": [],
                "permanentlyDeletedAssetIDs": sorted(hidden_ids),
                "durabilityPendingAssetIDs": [],
                "failedAssetIDs": [],
                "authorizationRequiredSourceIDs": [],
                "authorizationRequiredAssetIDs": [],
                "authorizationDeniedPhotosAssetIDs": [],
                "mutationAuthorizationInvalidAssetIDs": [],
                "photosMutationFailedAssetIDs": [],
                "photosMutationFailureCategories": [],
                "photosMutationFailureCodes": [],
                "sourceChangedAssetIDs": [],
            },
            "message": "已永久删除 2 张，来源空间已可回收",
            "updatedAtMs": 1_700_000_003_000,
        })

        page.wait_for_function(
            "ids => ids.every(id => !state.assets.some(asset => asset.id === id))",
            arg=sorted(hidden_ids),
        )
        assert page.locator("#assetGrid .asset-card-main").count() == 86
        assert page.evaluate("() => state.selectedAssetIDs.size") == 0
        assert page.evaluate("() => state.selectedAssetID") is None
        assert abs(page.locator("#libraryScroll").evaluate("element => element.scrollTop") - scroll_before) < 3
        assert page.locator("#inspectorPlaceholder").is_visible()

        remaining_cards = page.locator("#assetGrid .asset-card-main")
        page.locator("#cancelSelectionButton").click()
        remaining_cards.nth(4).click()
        page.locator("#inspectorDeleteButton:not(.hidden)").wait_for()
        page.locator("#openLightboxButton").click()
        page.locator("#lightboxDeleteButton:not(.hidden)").wait_for()
        page.locator("#lightboxDeleteButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#cancelConfirmButton").click()

        page.locator("#closeLightboxButton").click()
        remaining_cards.nth(4).click(button="right")
        page.locator("#assetDeleteContextAction:not(.hidden)").wait_for()
        assert not page.locator("#assetDeleteContextAction").is_disabled()
        page.keyboard.press("Escape")

        page.set_viewport_size({"width": 390, "height": 844})
        page.locator("#closeInspectorButton").click()
        remaining_cards.nth(5).click()
        remaining_cards.nth(6).click(modifiers=["Meta"])
        page.locator("#selectionInspectorDeleteButton:not(.hidden)").wait_for()
        page.wait_for_function(
            """
            () => {
              const inspector = document.querySelector("#inspector.open");
              const button = document.querySelector("#selectionInspectorDeleteButton");
              if (!inspector || !button) return false;
              const bounds = button.getBoundingClientRect();
              return bounds.left >= 0 && bounds.right <= innerWidth;
            }
            """
        )
        assert page.evaluate("() => document.documentElement.scrollWidth <= innerWidth")
        bounds = page.locator("#selectionInspectorDeleteButton").bounding_box()
        assert bounds and bounds["x"] >= 0 and bounds["x"] + bounds["width"] <= 390

        assert not failed_resources, failed_resources
        assert not page_errors, page_errors
        assert not console_errors, console_errors
        browser.close()


if __name__ == "__main__":
    main()
