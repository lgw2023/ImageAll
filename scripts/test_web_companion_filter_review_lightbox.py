#!/usr/bin/env python3
import base64
import json
import re
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8800"
SOURCE_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
CAT_TAG_ID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"
TRAVEL_TAG_ID = "cccccccc-1111-2222-3333-cccccccccccc"
SUBJECT_GROUP_ID = "eeeeeeee-1111-2222-3333-eeeeeeeeeeee"
SCENE_GROUP_ID = "ffffffff-1111-2222-3333-ffffffffffff"
IMAGE_IDS = [
    "11111111-1111-1111-1111-111111111111",
    "22222222-2222-2222-2222-222222222222",
]
REVIEW_IDS = [
    "33333333-3333-3333-3333-333333333333",
    "44444444-4444-4444-4444-444444444444",
    "55555555-5555-5555-5555-555555555555",
]
VIDEO_ID = "66666666-6666-6666-6666-666666666666"
SUGGESTION_TAG_IDS = [
    f"77777777-7777-7777-7777-77777777777{index}" for index in range(6)
]
PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
MP4_BYTES = base64.b64decode(
    "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMzbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAZAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAl10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAZAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAGQAAAAAAABAAAAAAHVbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAEABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABgG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAUBzdGJsAAAAuHN0c2QAAAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBQsAK/+EAFmdCwArZHsBEAAADAAQAAAMAUDxImSABAAVoy4PLIAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAADRsAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAEAAAEAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAEAAAAAQAAACRzdHN6AAAAAAAAAAAAAAAEAAACgwAAAAkAAAAKAAAACQAAABRzdGNvAAAAAAAAAAEAAANjAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAAAqdtZGF0AAACcQYF//9t3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MToweDExMSBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MjUwIGtleWludF9taW49MTAgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAKZYiED/JigADD7gAAAAVBmjgf6gAAAAZBmlQHeoAAAAAFQZpgN9Q="
)


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def asset_summary(asset_id, file_name, media_type="public.jpeg"):
    is_video = media_type == "public.mpeg-4"
    return {
        "id": asset_id,
        "sourceID": SOURCE_ID,
        "sourceName": "Apple Photos",
        "fileName": file_name,
        "mediaType": media_type,
        "mediaKind": "video" if is_video else "image",
        "availability": "available",
        "contentRevision": 1,
        "acceptedTagCount": 1,
        "rejectedTagCount": 0,
        "mediaCreatedAtMs": 1_700_000_000_000,
        "width": 1200,
        "height": 900,
        "durationMs": 12_000 if is_video else None,
    }


def asset_detail(asset_id, file_name, media_type="public.jpeg"):
    return {
        "assetID": asset_id,
        "sourceID": SOURCE_ID,
        "sourceName": "Apple Photos",
        "fileName": file_name,
        "relativePath": None,
        "mediaType": media_type,
        "availability": "available",
        "contentRevision": 1,
        "acceptedTagCount": 1,
        "rejectedTagCount": 0,
        "mediaCreatedAtMs": 1_700_000_000_000,
        "mediaModifiedAtMs": 1_700_000_100_000,
        "width": 1200,
        "height": 900,
        "durationMs": 12_000 if media_type == "public.mpeg-4" else None,
        "fingerprintSizeBytes": 4_500_000 if media_type == "public.mpeg-4" else 800_000,
        "tags": [
            {"tagID": CAT_TAG_ID, "displayName": "猫", "decision": "accepted"},
            {"tagID": TRAVEL_TAG_ID, "displayName": "旅行", "decision": "unknown"},
        ],
        "pendingSuggestions": [
            {
                "tagID": tag_id,
                "displayName": f"建议标签 {index + 1}",
                "suggestionOrigin": [
                    "featurePrint",
                    "standardModel",
                    "personalModel",
                    "personalAdamW",
                ][index % 4],
            }
            for index, tag_id in enumerate(SUGGESTION_TAG_IDS)
        ],
    }


def review_item(asset_id, index):
    return {
        "assetID": asset_id,
        "fileName": f"REVIEW_{index}.JPG",
        "availability": "available",
        "acceptedTagCount": 0,
        "rejectedTagCount": 0,
        "suggestionOrigin": "featurePrint",
        "score": 0.92 - index * 0.03,
    }


def main():
    asset_queries = []
    tag_decisions = []
    review_decisions = []
    source_actions = []
    source_requests = []
    media_requests = []
    favorite_mutations = []
    favorite_states = {
        asset_id: False
        for asset_id in IMAGE_IDS + REVIEW_IDS + [VIDEO_ID]
    }
    prewarm_poll_count = [0]
    cloud_preview_downloads = []
    page_errors = []
    console_errors = []
    review_items = [review_item(asset_id, index + 1) for index, asset_id in enumerate(REVIEW_IDS)]

    def projected_review_items():
        return [{
            **item,
            "favorite": {
                "assetID": item["assetID"],
                "isFavorite": favorite_states[item["assetID"]],
                "photosObservedValue": favorite_states[item["assetID"]],
                "syncStatus": "synced",
                "lastErrorCode": None,
            },
        } for item in review_items]

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
                {"authenticated": True, "authMode": "pairedDevice", "deviceName": "Synthetic Browser"},
            ),
        )
        page.route(
            "**/v1/capabilities",
            lambda route: fulfill_json(
                route,
                {
                    "protocolVersion": 1,
                    "hostID": "dddddddd-1111-2222-3333-dddddddddddd",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                    "capabilities": ["sourceManagement", "favorites"],
                },
            ),
        )
        sources = [{
            "id": SOURCE_ID,
            "kind": "photos",
            "displayName": "Apple Photos",
            "state": "active",
        }]
        tags = [
            {"id": CAT_TAG_ID, "displayName": "猫", "state": "active", "groupID": SUBJECT_GROUP_ID},
            {"id": TRAVEL_TAG_ID, "displayName": "旅行", "state": "active", "groupID": SCENE_GROUP_ID},
        ]
        page.route("**/v1/sources", lambda route: fulfill_json(route, sources))
        page.route("**/v1/tags", lambda route: fulfill_json(route, tags))
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(route, [
                {"id": SUBJECT_GROUP_ID, "displayName": "主体", "sortOrder": 0},
                {"id": SCENE_GROUP_ID, "displayName": "场景", "sortOrder": 1},
            ]),
        )
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
        def route_source_management(route):
            if source_requests and source_requests[0]["phase"] == "running":
                prewarm_poll_count[0] += 1
                completed = min(2, prewarm_poll_count[0])
                source_requests[0].update({
                    "completedCount": completed,
                    "totalCount": 3,
                    "warmedCount": completed,
                    "failedCount": 0,
                    "message": f"正在预热 Apple Photos 的网格缩略图 {completed} / 3",
                })
            fulfill_json(
                route,
                {"sources": sources, "canConnectPhotos": False, "requests": source_requests},
            )

        page.route("**/v1/source-management", route_source_management)

        def route_source_action(route):
            payload = route.request.post_data_json
            source_actions.append(payload)
            if payload["action"] == "cancelPrewarm":
                request = source_requests[0]
                request.update({
                    "phase": "cancelled",
                    "message": "已取消 Apple Photos 的缩略图预热",
                    "updatedAtMs": 1_700_000_000_500,
                })
                fulfill_json(route, request)
                return
            phase = "running" if payload["action"].startswith("prewarm") else "awaitingMac"
            message = (
                "正在预热 Apple Photos 的网格缩略图 0 / 3"
                if phase == "running" else "等待 Mac 确认"
            )
            request = {
                "id": "99999999-9999-9999-9999-999999999999",
                "operationID": payload["operationID"],
                "action": payload["action"],
                "sourceID": payload.get("sourceID"),
                "sourceDisplayName": "Apple Photos",
                "phase": phase,
                "message": message,
                "completedCount": 0 if phase == "running" else None,
                "totalCount": 3 if phase == "running" else None,
                "warmedCount": 0 if phase == "running" else None,
                "failedCount": 0 if phase == "running" else None,
                "updatedAtMs": 1_700_000_000_000,
            }
            source_requests[:] = [request]
            fulfill_json(
                route,
                request,
            )

        page.route("**/v1/source-management/requests", route_source_action)

        def route_assets(route):
            query = parse_qs(urlparse(route.request.url).query)
            asset_queries.append(query)
            if query.get("mediaKinds") == ["video"]:
                items = [asset_summary(VIDEO_ID, "CLIP_0001.MP4", "public.mpeg-4")]
            else:
                items = [
                    asset_summary(IMAGE_IDS[0], "CAT_0001.JPG"),
                    asset_summary(IMAGE_IDS[1], "TRIP_0002.JPG"),
                ]
            for item in items:
                item["favorite"] = {
                    "assetID": item["id"],
                    "isFavorite": favorite_states[item["id"]],
                    "photosObservedValue": favorite_states[item["id"]],
                    "syncStatus": "synced",
                    "lastErrorCode": None,
                }
            fulfill_json(route, {"items": items, "nextCursor": None})

        page.route("**/v1/assets?**", route_assets)

        def route_asset_detail(route):
            asset_id = urlparse(route.request.url).path.rsplit("/", 1)[-1]
            if asset_id == VIDEO_ID:
                detail = asset_detail(asset_id, "CLIP_0001.MP4", "public.mpeg-4")
            else:
                index = (IMAGE_IDS + REVIEW_IDS).index(asset_id) + 1
                detail = asset_detail(asset_id, f"PHOTO_{index:04d}.JPG")
            detail["favorite"] = {
                "assetID": asset_id,
                "isFavorite": favorite_states[asset_id],
                "photosObservedValue": favorite_states[asset_id],
                "syncStatus": "synced",
                "lastErrorCode": None,
            }
            fulfill_json(route, detail)

        page.route(re.compile(r".*/v1/assets/[0-9a-f-]+$"), route_asset_detail)

        def route_favorite_mutation(route):
            payload = route.request.post_data_json
            favorite_mutations.append(payload)
            for asset_id in payload["assetIDs"]:
                favorite_states[asset_id] = payload["isFavorite"]
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "changedCount": len(payload["assetIDs"]),
                    "localOnlyCount": 0,
                    "syncedCount": len(payload["assetIDs"]),
                    "pendingCount": 0,
                    "failedCount": 0,
                    "states": [{
                        "assetID": asset_id,
                        "isFavorite": favorite_states[asset_id],
                        "photosObservedValue": favorite_states[asset_id],
                        "syncStatus": "synced",
                        "lastErrorCode": None,
                    } for asset_id in payload["assetIDs"]],
                    "replayed": False,
                },
            )

        page.route("**/v1/favorites", route_favorite_mutation)
        def route_asset_image(route):
            path = urlparse(route.request.url).path
            asset_id = path.split("/")[-2]
            if path.endswith("/preview") and asset_id == IMAGE_IDS[1] \
                    and asset_id not in cloud_preview_downloads:
                fulfill_json(
                    route,
                    {"code": "conflict", "message": "cloud preview required"},
                    status=409,
                )
                return
            route.fulfill(status=200, content_type="image/png", body=PNG_BYTES)

        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            route_asset_image,
        )

        def route_cloud_preview(route):
            asset_id = urlparse(route.request.url).path.split("/")[-2]
            assert route.request.method == "POST"
            cloud_preview_downloads.append(asset_id)
            if len(cloud_preview_downloads) == 1:
                fulfill_json(
                    route,
                    {"code": "internalError", "message": "synthetic cloud failure"},
                    status=500,
                )
                return
            route.fulfill(status=200, content_type="image/png", body=PNG_BYTES)

        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/cloud-preview$"),
            route_cloud_preview,
        )
        def route_media(route):
            media_requests.append(route.request.url)
            route.fulfill(
                status=200,
                content_type="video/mp4",
                headers={"Accept-Ranges": "bytes", "Cache-Control": "no-store"},
                body=MP4_BYTES,
            )

        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/media(\?.*)?$"),
            route_media,
        )

        def route_tag_decision(route):
            payload = route.request.post_data_json
            tag_decisions.append(payload)
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "appliedAssetCount": len(payload["assetIDs"]),
                    "replayed": False,
                    "undoID": "77777777-7777-7777-7777-777777777777",
                },
            )

        page.route("**/v1/tag-decisions/batch", route_tag_decision)
        page.route(
            "**/v1/review/overview?**",
            lambda route: fulfill_json(
                route,
                {
                    "totalPendingSuggestionCount": len(review_items),
                    "tags": [{
                        "id": CAT_TAG_ID,
                        "displayName": "猫",
                        "acceptedSampleCount": 8,
                        "rejectedSampleCount": 4,
                        "pendingSuggestionCount": len(review_items),
                        "pendingSuggestionCounts": {
                            "featurePrint": len(review_items),
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
        page.route(
            "**/v1/review/queue?**",
            lambda route: fulfill_json(
                route,
                {"items": projected_review_items(), "nextCursor": None},
            ),
        )

        def route_review_decision(route):
            payload = route.request.post_data_json
            review_decisions.append(payload)
            decided_ids = set(payload["assetIDs"])
            review_items[:] = [item for item in review_items if item["assetID"] not in decided_ids]
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "appliedAssetCount": len(decided_ids),
                    "replayed": False,
                    "undoID": "88888888-8888-8888-8888-888888888888",
                },
            )

        page.route("**/v1/review/decisions/batch", route_review_decision)

        page.goto(BASE_URL, wait_until="networkidle")
        page.locator(f'[data-quick-tag-id="{CAT_TAG_ID}"]').click()
        page.locator("#activeFilterBar:not(.hidden)").wait_for()
        assert "猫 已确认" in page.locator("#activeFilterSummary").inner_text()
        assert any(query.get("acceptedTagIDs") == [CAT_TAG_ID] for query in asset_queries)

        page.locator("#filterButton").click()
        page.locator("#filterTagSelect").select_option(TRAVEL_TAG_ID)
        page.locator("#filterTagDecision").select_option("rejected")
        page.locator("#addTagFilterButton").click()
        page.locator("#applyFiltersButton").click()
        page.locator("#activeFilterRelation:not(.hidden)").wait_for()
        assert "旅行 已拒绝" in page.locator("#activeFilterSummary").inner_text()
        page.locator('[data-active-filter-match="any"]').click()
        page.wait_for_function(
            "() => document.querySelector('[data-active-filter-match=\"any\"]').getAttribute('aria-pressed') === 'true'"
        )
        assert any(query.get("tagMatchMode") == ["any"] for query in asset_queries)
        page.locator("#clearActiveFiltersButton").click()
        page.locator("#activeFilterBar").wait_for(state="hidden")

        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').click()
        page.locator("#inspectorContent:not(.hidden)").wait_for()
        page.locator("#inspectorSuggestionsSection:not(.hidden)").wait_for()
        assert page.locator("#inspectorSuggestionCount").inner_text() == "6"
        assert page.locator("#inspectorSuggestions .inspector-suggestion-row").count() == 5
        assert page.locator("#inspectorSuggestions .inspector-suggestion-origin").all_inner_texts()[:4] == [
            "特征向量",
            "标准模型",
            "个人模型",
            "超级个人模型",
        ]
        page.locator("#expandInspectorSuggestionsButton").click()
        assert page.locator("#inspectorSuggestions .inspector-suggestion-row").count() == 6
        page.screenshot(path="/tmp/imageall-inspector-suggestions-synthetic.png", full_page=True)
        page.wait_for_function(
            "(key) => document.activeElement?.dataset.inspectorSuggestionKey === key",
            arg=f"{SUGGESTION_TAG_IDS[5]}|standardModel",
        )
        first_suggestion_accept = page.locator(
            f'#inspectorSuggestions [data-tag-id="{SUGGESTION_TAG_IDS[0]}"][data-action="accept"]'
        )
        first_suggestion_accept.click()
        page.wait_for_function(
            "(key) => document.activeElement?.dataset.inspectorSuggestionKey === key",
            arg=f"{SUGGESTION_TAG_IDS[0]}|featurePrint",
        )
        assert tag_decisions[-1]["tagID"] == SUGGESTION_TAG_IDS[0]
        assert tag_decisions[-1]["action"] == "accept"
        assert tag_decisions[-1]["assetIDs"] == [IMAGE_IDS[0]]

        assert page.locator("#inspectorTags .inspector-tag-group").count() == 2
        group_toggle_texts = page.locator(
            "#inspectorTags .inspector-tag-group-toggle"
        ).all_inner_texts()
        assert len(group_toggle_texts) == 2
        assert "主体" in group_toggle_texts[0] and "1" in group_toggle_texts[0]
        assert "场景" in group_toggle_texts[1] and "1" in group_toggle_texts[1]
        subject_toggle = page.locator(
            f'#inspectorTags [data-inspector-tag-group-toggle="{SUBJECT_GROUP_ID}"]'
        )
        scene_toggle = page.locator(
            f'#inspectorTags [data-inspector-tag-group-toggle="{SCENE_GROUP_ID}"]'
        )
        subject_toggle.focus()
        page.keyboard.press("ArrowDown")
        assert page.evaluate("() => document.activeElement?.dataset.inspectorTagGroupToggle") == SCENE_GROUP_ID
        scene_toggle.click()
        assert scene_toggle.get_attribute("aria-expanded") == "false"
        scene_toggle.click()
        assert scene_toggle.get_attribute("aria-expanded") == "true"

        travel_chip = page.locator(f'#inspectorTags [data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]')
        travel_chip.click()
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        assert tag_decisions[-1]["action"] == "accept"
        assert tag_decisions[-1]["assetIDs"] == [IMAGE_IDS[0]]
        cat_chip = page.locator(f'#inspectorTags [data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]')
        cat_chip.click(
            button="right"
        )
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=CAT_TAG_ID,
        )
        assert tag_decisions[-1]["action"] == "clear"
        travel_chip.focus()
        page.keyboard.press("x")
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        assert tag_decisions[-1]["action"] == "reject"

        page.locator("#commandButton").click()
        page.locator("#commandSearchInput").fill("确认标签：猫")
        page.locator(f'[data-command-id="tagAction:accept:{CAT_TAG_ID}"]').click()
        page.wait_for_function("() => document.querySelector('#commandPalette').open === false")
        assert tag_decisions[-1]["action"] == "accept"
        assert tag_decisions[-1]["assetIDs"] == [IMAGE_IDS[0]]

        page.locator(f'[data-asset-id="{IMAGE_IDS[1]}"]').click()
        page.locator("#cloudPreviewRecovery:not(.hidden)").wait_for()
        assert "仅存储在 iCloud" in page.locator("#cloudPreviewTitle").inner_text()
        page.locator("#cloudPreviewButton").click()
        page.wait_for_function(
            "() => document.querySelector('#cloudPreviewTitle').textContent.includes('无法获取')"
        )
        assert page.locator("#cloudPreviewButton").inner_text() == "重试"
        page.locator("#cloudPreviewButton").click()
        page.wait_for_function(
            "() => !document.querySelector('#previewImage').classList.contains('hidden')"
        )
        assert cloud_preview_downloads == [IMAGE_IDS[1], IMAGE_IDS[1]]
        assert page.locator("#cloudPreviewRecovery").is_hidden()
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').click()

        page.locator(f'[data-source-id="{SOURCE_ID}"]').click(button="right")
        source_menu_actions = page.locator(
            "#sourceContextMenu [data-source-context-action]"
        ).all_inner_texts()
        assert "预热缩略图缓存" in source_menu_actions
        assert "专门用于原比例的缓存" in source_menu_actions
        page.locator(
            '#sourceContextMenu [data-source-context-action="prewarmThumbnails"]'
        ).click()
        page.locator("#sourceManagerDialog").wait_for(state="visible")
        page.wait_for_function(
            "() => document.querySelector('#sourceManagerPending').textContent.includes('0 / 3')"
        )
        assert source_actions[-1]["action"] == "prewarmThumbnails"
        assert page.locator("#sourceManagerPending progress").get_attribute("max") == "3"
        assert page.locator('[data-source-pending-action="cancelPrewarm"]').is_enabled()
        page.locator("#sourceManagerCloseButton").click()
        page.wait_for_function(
            "() => !document.querySelector('#sourcePrewarmStatusButton').classList.contains('hidden')"
            " && document.querySelector('#sourcePrewarmStatusLabel').textContent.includes('/3')"
        )
        page.locator("#sourcePrewarmStatusButton").click()
        page.locator("#sourceManagerDialog").wait_for(state="visible")
        page.screenshot(path="/tmp/imageall-source-prewarm-synthetic.png", full_page=True)
        page.locator('[data-source-pending-action="cancelPrewarm"]').click()
        page.wait_for_function(
            "() => document.querySelector('#sourcePrewarmStatusButton').classList.contains('hidden')"
        )
        assert source_actions[-1]["action"] == "cancelPrewarm"
        page.locator("#sourceManagerCloseButton").click()

        page.locator("#commandButton").click()
        page.locator("#commandSearchInput").fill("连接文件夹来源")
        page.locator('[data-command-id="connectFolder"]').click()
        page.wait_for_function("() => document.querySelector('#sourceManagerDialog').open === true")
        page.wait_for_function("() => document.querySelector('#sourceManagerPending').textContent.includes('等待 Mac')")
        assert source_actions[-1]["action"] == "connectFolder"
        assert source_actions[-1].get("sourceID") is None
        page.locator("#sourceManagerCloseButton").click()

        page.locator("#reviewNavigationButton").click()
        page.locator(f'[data-review-overview-tag-id="{CAT_TAG_ID}"]').click()
        page.locator("#reviewQueueLayout:not(.hidden)").wait_for()
        first_review_card = page.locator(f'[data-review-index="0"]')
        first_review_main = first_review_card.locator(":scope > .review-card-main")
        first_review_favorite = first_review_card.locator(":scope > .review-card-favorite")
        assert first_review_main.get_attribute("aria-pressed") == "true"
        review_scroll_top = page.locator("#reviewQueuePane").evaluate("element => element.scrollTop")
        first_review_card.hover()
        first_review_favorite.click()
        page.wait_for_function(
            "() => document.querySelector('[data-review-index=\"0\"] > .review-card-favorite')"
            "?.dataset.favorite === 'true'"
        )
        assert favorite_mutations[-1]["assetIDs"] == [REVIEW_IDS[0]]
        assert favorite_mutations[-1]["isFavorite"] is True
        assert first_review_main.get_attribute("aria-pressed") == "true"
        assert page.locator("#lightbox").is_hidden()
        assert page.locator("#reviewQueuePane").evaluate("element => element.scrollTop") == review_scroll_top
        first_review_favorite.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('[data-review-index=\"0\"] > .review-card-favorite')"
            "?.dataset.favorite === 'false'"
        )
        assert favorite_mutations[-1]["isFavorite"] is False
        assert first_review_main.get_attribute("aria-pressed") == "true"
        assert page.locator("#lightbox").is_hidden()
        assert page.locator("#reviewQueuePane").evaluate("element => element.scrollTop") == review_scroll_top

        page.set_viewport_size({"width": 390, "height": 844})
        assert first_review_favorite.is_visible()
        review_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert review_dimensions["scroll"] <= review_dimensions["viewport"], review_dimensions
        page.screenshot(path="/tmp/imageall-review-card-favorite-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})

        page.locator("#reviewOpenLightboxButton").click()
        page.locator("#lightboxReviewActions:not(.hidden)").wait_for()
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        page.wait_for_function(
            "() => !document.querySelector('#lightboxFavoriteButton').disabled"
        )
        assert page.locator("#lightboxFavoriteButton").is_visible()
        page.locator("#lightboxFavoriteButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxFavoriteButton')?.dataset.favorite === 'true'"
        )
        assert favorite_mutations[-1]["assetIDs"] == [REVIEW_IDS[0]]
        assert favorite_mutations[-1]["isFavorite"] is True
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        page.screenshot(path="/tmp/imageall-review-lightbox-synthetic.png", full_page=True)
        page.locator('#lightboxReviewActions [data-action="accept"]').click()
        page.wait_for_function("() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_2.JPG')")
        assert review_decisions[-1]["action"] == "accept"
        page.keyboard.press("u")
        page.wait_for_function("() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_3.JPG')")
        assert len(review_decisions) == 1, review_decisions
        page.keyboard.press("x")
        page.wait_for_function("() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_2.JPG')")
        assert review_decisions[-1]["action"] == "reject"
        page.locator("#closeLightboxButton").click()
        page.locator("#closeReviewButton").click()

        page.locator('[data-media-kind="video"]').click()
        video_card = page.locator(f'[data-asset-id="{VIDEO_ID}"]')
        video_card.wait_for()
        video_card_main = video_card.locator(":scope > .asset-card-main")
        assert video_card.locator(".asset-video-badge").inner_text() == "▶ 0:12"
        assert "视频" in video_card_main.get_attribute("aria-label")
        initial_scroll_top = page.locator("#libraryScroll").evaluate("element => element.scrollTop")
        video_card.hover()
        hover_video = video_card.locator(".asset-hover-video")
        hover_video.wait_for()
        page.wait_for_function(
            "() => { const video = document.querySelector('.asset-hover-video'); "
            "return video && video.readyState >= 2 && !video.paused; }"
        )
        hover_state = hover_video.evaluate(
            "video => ({ muted: video.muted, loop: video.loop, controls: video.controls })"
        )
        assert hover_state == {"muted": True, "loop": True, "controls": False}, hover_state
        assert video_card_main.get_attribute("aria-pressed") == "false"
        assert page.locator("#libraryScroll").evaluate("element => element.scrollTop") == initial_scroll_top
        page.screenshot(path="/tmp/imageall-video-hover-synthetic.png", full_page=True)
        page.locator("#searchInput").hover()
        hover_video.wait_for(state="detached")
        assert media_requests, media_requests

        video_card.dblclick()
        page.locator("#lightboxVideo:not(.hidden)").wait_for()
        assert f"/v1/assets/{VIDEO_ID}/media?r=1" in page.locator("#lightboxVideo").get_attribute("src")
        assert page.locator("#lightboxImage").is_hidden()
        page.locator("#closeLightboxButton").click()

        page.locator('[data-media-kind="image"]').click()
        page.locator(f'[data-quick-tag-id="{CAT_TAG_ID}"]').click()
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        if page.locator("#closeInspectorButton").is_visible():
            page.locator("#closeInspectorButton").click()
        page.locator("#toast").wait_for(state="hidden")
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        assert page.locator("#activeFilterBar").is_visible()
        page.screenshot(path="/tmp/imageall-filter-review-lightbox-synthetic.png", full_page=True)

        assert not page_errors, page_errors
        unexpected_console_errors = [
            message for message in console_errors
            if "status of 409" not in message and "status of 500" not in message
        ]
        assert not unexpected_console_errors, unexpected_console_errors
        browser.close()

    print(
        "filter/review/lightbox browser flow passed; "
        f"asset queries={len(asset_queries)}; tag decisions={len(tag_decisions)}; "
        f"review decisions={len(review_decisions)}; source actions={len(source_actions)}; "
        f"media requests={len(media_requests)}; favorites={len(favorite_mutations)}"
    )


if __name__ == "__main__":
    main()
