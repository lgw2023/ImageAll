#!/usr/bin/env python3
import argparse
import base64
import json
import time
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8802"
SOURCE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SECOND_SOURCE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaab"
ASSET_IDS = [
    "11111111-1111-1111-1111-111111111111",
    "22222222-2222-2222-2222-222222222222",
]
SLIMMING_ASSET_IDS = [
    *ASSET_IDS,
    "33333333-1111-1111-1111-111111111111",
]
PREPARATION_ID = "33333333-3333-3333-3333-333333333333"
SLIMMING_JOB_ID = "44444444-4444-4444-4444-444444444444"
SLIMMING_SECOND_JOB_ID = "44444444-4444-4444-4444-444444444445"
SLIMMING_HISTORY_JOB_IDS = [
    f"44444444-5555-5555-5555-{index:012d}" for index in range(1, 121)
]
SLIMMING_CLUSTER_ID = "55555555-4444-4444-4444-444444444444"
SLIMMING_CONFIRMED_CLUSTER_ID = "55555555-4444-4444-4444-444444444445"
SLIMMING_IGNORED_CLUSTER_ID = "55555555-4444-4444-4444-444444444446"
SLIMMING_PAGINATION_CLUSTER_IDS = [
    f"55555556-4444-4444-4444-{index:012d}" for index in range(1, 106)
]
SLIMMING_PAGINATION_ASSET_IDS = [
    f"33333334-1111-1111-1111-{index:012d}" for index in range(1, 206)
]
SLIMMING_RECYCLE_IDS = [
    "66666666-4444-4444-4444-444444444441",
    "66666666-4444-4444-4444-444444444442",
    "66666666-4444-4444-4444-444444444443",
    "66666666-4444-4444-4444-444444444444",
    "66666666-4444-4444-4444-444444444445",
    "66666666-4444-4444-4444-444444444446",
    "66666666-4444-4444-4444-444444444447",
]
SLIMMING_RECYCLE_PAGINATION_IDS = [
    f"66666667-4444-4444-4444-{index:012d}" for index in range(1, 136)
]
SLIMMING_RECYCLE_PAGINATION_ASSET_IDS = [
    f"33333335-1111-1111-1111-{index:012d}" for index in range(1, 136)
]
SAMPLE_SUGGESTION_ID = "77777777-7777-7777-7777-777777777777"
CAT_TAG_ID = "88888888-8888-8888-8888-888888888888"
TRAVEL_TAG_ID = "99999999-9999-9999-9999-999999999999"
SINGLE_CREATED_TAG_ID = "aaaaaaaa-bbbb-cccc-dddd-000000000001"
SELECTION_CREATED_TAG_ID = "aaaaaaaa-bbbb-cccc-dddd-000000000002"
SUBJECT_GROUP_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
SCENE_GROUP_ID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"
PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
RECYCLE_PURGE_AFTER_MS = int(time.time() * 1_000) + 30 * 24 * 60 * 60 * 1_000


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def drag_marquee_to_bottom_edge(page, container_selector, grid_selector):
    page.wait_for_function(
        "selector => { const element = document.querySelector(selector); "
        "return element && element.scrollHeight - element.clientHeight >= 360; }",
        arg=container_selector,
    )
    container = page.locator(container_selector)
    grid = page.locator(grid_selector)
    container_box = container.bounding_box()
    grid_box = grid.bounding_box()
    assert container_box is not None and grid_box is not None
    container_metrics = container.evaluate(
        "element => { const cards = [...document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card')]; "
        "const first = cards[0]?.getBoundingClientRect(); "
        "const last = cards.at(-1)?.getBoundingClientRect(); return ({ "
        "selector: element.id || element.className, cardCount: cards.length, "
        "firstCard: first && { width: first.width, height: first.height, top: first.top }, "
        "lastCard: last && { width: last.width, height: last.height, top: last.top, bottom: last.bottom }, "
        "clientHeight: element.clientHeight, scrollHeight: element.scrollHeight, "
        "overflowY: getComputedStyle(element).overflowY }); }"
    )
    assert container_metrics["scrollHeight"] > container_metrics["clientHeight"], (
        container_metrics
    )
    # The main library reserves a narrow Mac-style split-view hit target at
    # its left edge. Start inside the grid's background padding so this helper
    # exercises marquee selection rather than intentionally resizing a column.
    start_x = grid_box["x"] + (8 if container_selector == "#libraryScroll" else 2)
    start_y = max(container_box["y"] + 2, grid_box["y"] + 2)
    end_x = container_box["x"] + container_box["width"] - 4
    end_y = container_box["y"] + container_box["height"] - 3
    page.mouse.move(start_x, start_y)
    page.mouse.down()
    page.mouse.move(end_x, end_y, steps=8)
    page.wait_for_function(
        "selector => { const element = document.querySelector(selector); "
        "return element.scrollTop >= Math.min(360, element.scrollHeight - element.clientHeight); }",
        arg=container_selector,
    )
    page.wait_for_timeout(250)
    scrolled = container.evaluate("element => element.scrollTop")
    page.mouse.up()
    return scrolled


def main(*, inspector_actions_only=False):
    submitted_preparations = []
    submitted_slimming = []
    submitted_slimming_cluster_reviews = []
    submitted_slimming_job_actions = []
    slimming_job_action_fail_next = [False]
    submitted_slimming_source_maintenance = []
    submitted_slimming_thresholds = []
    slimming_setup_reads = [0]
    submitted_slimming_removals = []
    submitted_slimming_recycle_actions = []
    slimming_recycle_action_failures = [0]
    slimming_recycle_query_failures = [0]
    submitted_source_management = []
    submitted_sample_suggestions = []
    submitted_tag_decisions = []
    submitted_created_tags = []
    submitted_favorites = []
    submitted_favorite_retries = []
    asset_request_urls = []
    recycle_request_urls = []
    favorite_states = {asset_id: False for asset_id in SLIMMING_ASSET_IDS}
    favorite_sync_status = {
        ASSET_IDS[0]: "failed",
        ASSET_IDS[1]: "synced",
        SLIMMING_ASSET_IDS[2]: "synced",
    }
    preparation_reads = 0
    preparation_active = False
    active_preparation_id = None
    sample_reads = 0
    sample_active = False
    active_slimming_removal = None
    hidden_slimming_asset_ids = set()
    deleted_slimming_job_ids = set()
    slimming_job_states = {
        SLIMMING_JOB_ID: "completed",
        SLIMMING_SECOND_JOB_ID: "completed",
    }
    slimming_job_attempts = {
        SLIMMING_JOB_ID: 1,
        SLIMMING_SECOND_JOB_ID: 1,
    }
    slimming_job_error_codes = {
        SLIMMING_JOB_ID: None,
        SLIMMING_SECOND_JOB_ID: None,
    }
    slimming_job_scan_progress = {
        SLIMMING_JOB_ID: None,
        SLIMMING_SECOND_JOB_ID: None,
    }
    expanded_slimming_history_enabled = False
    expanded_slimming_pagination_enabled = False
    expanded_slimming_recycle_pagination_enabled = False
    slimming_recycle_poll_revision = 0
    expanded_slimming_marquee_enabled = False
    source_index_reads = 0
    source_index_building = False
    active_slimming_thresholds = {
        "featurePrintRecallTopK": 32,
        "featurePrintMaxL2Distance": 0.4,
        "dinoCosineMinSimilarity": 0.85,
        "sceneBucketActivationAssetCount": 700,
        "featurePrintRecallMode": "topK",
        "featurePrintL2Mode": "radius",
        "dinoCosineMode": "minimum",
        "sceneBucketingMode": "automatic",
    }
    factory_slimming_thresholds = {
        "featurePrintRecallTopK": 16,
        "featurePrintMaxL2Distance": 25,
        "dinoCosineMinSimilarity": 0.88,
        "sceneBucketActivationAssetCount": 256,
        "featurePrintRecallMode": "topK",
        "featurePrintL2Mode": "radius",
        "dinoCosineMode": "minimum",
        "sceneBucketingMode": "automatic",
    }
    slimming_cluster_dispositions = {
        SLIMMING_CLUSTER_ID: None,
        SLIMMING_CONFIRMED_CLUSTER_ID: "confirmed",
        SLIMMING_IGNORED_CLUSTER_ID: "ignored",
    }
    page_errors = []
    console_errors = []
    failed_resources = []
    unexpected_dialogs = []
    tags_catalog = [
        {"id": CAT_TAG_ID, "displayName": "猫", "state": "active", "groupID": SUBJECT_GROUP_ID},
        {"id": TRAVEL_TAG_ID, "displayName": "旅行", "state": "active", "groupID": SCENE_GROUP_ID},
    ]
    created_tag_assignments = {}
    created_tag_results = {}
    create_attempts_by_name = {}

    def preparation_activity(phase, operation_id=PREPARATION_ID):
        completed = 2 if phase == "completed" else 1
        return {
            "operationID": operation_id,
            "mediaKind": "image",
            "phase": phase,
            "completedUnitCount": completed,
            "totalUnitCount": 2,
            "preparedCount": completed,
            "cachedCount": 0,
            "cloudOnlyCount": 0,
            "failedCount": 0,
            "availableActions": ["cancel"] if phase == "running" else [],
        }

    def sample_activity(phase):
        return {
            "operationID": SAMPLE_SUGGESTION_ID,
            "mediaKind": "image",
            "phase": phase,
            "completedUnitCount": 2 if phase == "completed" else 0,
            "totalUnitCount": 2,
            "suggestedCount": 3 if phase == "completed" else 0,
            "skippedCount": 0,
            "availableActions": ["cancel"] if phase == "running" else [],
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
        def accept_unexpected_dialog(dialog):
            unexpected_dialogs.append(dialog.message)
            dialog.accept()

        page.on("dialog", accept_unexpected_dialog)
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
                body="<!doctype html><title>Map shell</title>",
            ),
        )
        page.route(
            "**/web/session",
            lambda route: fulfill_json(
                route,
                {"authenticated": True, "authMode": "pairedDevice", "deviceName": "Synthetic"},
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
                    "capabilities": ["favorites", "sourceManagement", "librarySlimming"],
                },
            ),
        )
        page.route(
            "**/v1/sources",
            lambda route: fulfill_json(
                route,
                [{"id": SOURCE_ID, "kind": "photos", "displayName": "Apple Photos", "state": "active"}],
            ),
        )

        def handle_source_management_snapshot(route):
            fulfill_json(
                route,
                {
                    "sources": [
                        {"id": SOURCE_ID, "kind": "photos", "displayName": "Apple Photos", "state": "active"},
                        {"id": SECOND_SOURCE_ID, "kind": "folder", "displayName": "旅行归档", "state": "active"},
                    ],
                    "canConnectPhotos": False,
                    "requests": [],
                },
            )

        def handle_source_management_request(route):
            payload = route.request.post_data_json
            submitted_source_management.append(payload)
            fulfill_json(
                route,
                {
                    "id": f"bbbbbbbb-4444-4444-4444-{len(submitted_source_management):012d}",
                    "operationID": payload["operationID"],
                    "action": payload["action"],
                    "sourceID": payload.get("sourceID"),
                    "sourceDisplayName": "Apple Photos" if payload.get("sourceID") == SOURCE_ID else "旅行归档",
                    "phase": "completed",
                    "message": "来源恢复动作已完成",
                    "updatedAtMs": 1_700_000_020_000 + len(submitted_source_management),
                },
            )

        page.route("**/v1/source-management", handle_source_management_snapshot)
        page.route("**/v1/source-management/requests", handle_source_management_request)
        page.route("**/v1/tags", lambda route: fulfill_json(route, tags_catalog))

        def handle_create_tag_and_apply(route):
            payload = route.request.post_data_json
            submitted_created_tags.append(payload)
            name = payload["name"]
            operation_id = payload["operationID"]
            create_attempts_by_name[name] = create_attempts_by_name.get(name, 0) + 1
            if name == "重试标签" and create_attempts_by_name[name] == 1:
                fulfill_json(
                    route,
                    {"code": "operationInProgress", "message": "模拟暂时冲突，请重试"},
                    status=409,
                )
                return
            if operation_id in created_tag_results:
                fulfill_json(route, {**created_tag_results[operation_id], "replayed": True})
                return
            tag_id = (
                SINGLE_CREATED_TAG_ID
                if name == "重试标签"
                else SELECTION_CREATED_TAG_ID
            )
            if not any(tag["id"] == tag_id for tag in tags_catalog):
                tags_catalog.append(
                    {
                        "id": tag_id,
                        "displayName": name,
                        "state": "active",
                        "groupID": SUBJECT_GROUP_ID,
                    }
                )
            created_tag_assignments.setdefault(tag_id, set()).update(payload["assetIDs"])
            result = {
                "operationID": operation_id,
                "tagID": tag_id,
                "displayName": name,
                "appliedAssetCount": len(payload["assetIDs"]),
                "replayed": False,
                "undoID": f"cccccccc-2222-3333-4444-{len(created_tag_results) + 1:012d}",
            }
            created_tag_results[operation_id] = result
            fulfill_json(route, result)

        page.route("**/v1/tags/create-and-apply", handle_create_tag_and_apply)
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(route, [
                {"id": SUBJECT_GROUP_ID, "displayName": "主体", "sortOrder": 0, "isSystem": False},
                {"id": SCENE_GROUP_ID, "displayName": "场景", "sortOrder": 1, "isSystem": False},
            ]),
        )
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
        def favorite_state(asset_id):
            return {
                "assetID": asset_id,
                "isFavorite": favorite_states.get(asset_id, False),
                "photosObservedValue": favorite_states.get(asset_id, False),
                "syncStatus": favorite_sync_status.get(asset_id, "synced"),
                "lastErrorCode": None,
            }

        def handle_assets(route):
            asset_request_urls.append(route.request.url)
            visible_ids = ASSET_IDS
            if "favorite=favorited" in route.request.url:
                visible_ids = [asset_id for asset_id in ASSET_IDS if favorite_states[asset_id]]
            fulfill_json(
                route,
                {
                    "items": [
                        {
                            "id": asset_id,
                            "fileName": f"IMG_{ASSET_IDS.index(asset_id) + 1:04}.JPG",
                            "sourceID": SOURCE_ID,
                            "sourceName": "Apple Photos",
                            "availability": "available",
                            "contentRevision": 1,
                            "acceptedTagCount": sum(
                                asset_id in assignments
                                for assignments in created_tag_assignments.values()
                            ),
                            "rejectedTagCount": 0,
                            "favorite": favorite_state(asset_id),
                        }
                        for asset_id in visible_ids
                    ],
                    "nextCursor": None,
                },
            )

        page.route("**/v1/assets?**", handle_assets)

        def handle_favorites(route):
            payload = route.request.post_data_json
            submitted_favorites.append(payload)
            changed_count = sum(
                favorite_states[asset_id] != payload["isFavorite"]
                for asset_id in payload["assetIDs"]
            )
            for asset_id in payload["assetIDs"]:
                favorite_states[asset_id] = payload["isFavorite"]
                favorite_sync_status[asset_id] = "synced"
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "changedCount": changed_count,
                    "localOnlyCount": 0,
                    "syncedCount": len(payload["assetIDs"]),
                    "pendingCount": 0,
                    "failedCount": 0,
                    "states": [favorite_state(asset_id) for asset_id in payload["assetIDs"]],
                    "replayed": False,
                },
            )

        page.route("**/v1/favorites", handle_favorites)

        def handle_favorite_retry(route):
            payload = route.request.post_data_json
            submitted_favorite_retries.append(payload)
            for asset_id in ASSET_IDS:
                favorite_sync_status[asset_id] = "synced"
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "localOnlyCount": 0,
                    "syncedCount": len(ASSET_IDS),
                    "pendingCount": 0,
                    "failedCount": 0,
                    "replayed": False,
                },
            )

        page.route("**/v1/favorites/retry", handle_favorite_retry)

        def handle_asset_detail(route):
            asset_id = route.request.url.split("/v1/assets/", 1)[1].split("?", 1)[0]
            accepted_tag_count = sum(
                asset_id in assignments
                for assignments in created_tag_assignments.values()
            )
            fulfill_json(
                route,
                {
                    "assetID": asset_id,
                    "sourceID": SOURCE_ID,
                    "sourceName": "Apple Photos",
                    "sourceState": "active",
                    "fileName": f"IMG_{ASSET_IDS.index(asset_id) + 1:04}.JPG",
                    "relativePath": f"精选/IMG_{ASSET_IDS.index(asset_id) + 1:04}.JPG",
                    "mediaType": "public.jpeg",
                    "availability": "available",
                    "contentRevision": 1,
                    "acceptedTagCount": accepted_tag_count,
                    "rejectedTagCount": 0,
                    "mediaCreatedAtMs": 1_735_689_600_000,
                    "mediaModifiedAtMs": 1_735_776_000_000,
                    "width": 4032,
                    "height": 3024,
                    "durationMs": None,
                    "fingerprintSizeBytes": 2_500_000,
                    "tags": [
                        {
                            "tagID": tag["id"],
                            "displayName": tag["displayName"],
                            "decision": (
                                "accepted"
                                if asset_id in created_tag_assignments.get(tag["id"], set())
                                else "unknown"
                            ),
                        }
                        for tag in tags_catalog
                    ],
                    "favorite": favorite_state(asset_id),
                },
            )

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
            "**/v1/assets/*/media?**",
            lambda route: route.fulfill(status=200, content_type="video/mp4", body=b""),
        )
        def handle_selection_tags(route):
            payload = route.request.post_data_json
            selected_ids = set(payload["assetIDs"])
            aggregates = [
                {"tagID": CAT_TAG_ID, "acceptedCount": 2, "rejectedCount": 0, "unknownCount": 0},
                {"tagID": TRAVEL_TAG_ID, "acceptedCount": 1, "rejectedCount": 0, "unknownCount": 1},
            ]
            for tag_id, assignments in created_tag_assignments.items():
                accepted_count = len(selected_ids & assignments)
                aggregates.append(
                    {
                        "tagID": tag_id,
                        "acceptedCount": accepted_count,
                        "rejectedCount": 0,
                        "unknownCount": len(selected_ids) - accepted_count,
                    }
                )
            fulfill_json(route, aggregates)

        page.route("**/v1/tags/selection", handle_selection_tags)

        def handle_tag_decision(route):
            payload = route.request.post_data_json
            submitted_tag_decisions.append(payload)
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "appliedAssetCount": len(payload["assetIDs"]),
                    "replayed": False,
                    "undoID": "cccccccc-1111-2222-3333-cccccccccccc",
                },
            )

        page.route("**/v1/tag-decisions/batch", handle_tag_decision)
        page.route(
            "**/v1/review/overview?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "sourceIDs": [],
                    "totalPendingSuggestionCount": 0,
                    "tags": [],
                },
            ),
        )

        def handle_preparation(route):
            nonlocal preparation_reads, preparation_active, active_preparation_id
            if route.request.method == "POST":
                payload = route.request.post_data_json
                submitted_preparations.append(payload)
                preparation_active = True
                preparation_reads = 0
                active_preparation_id = payload["operationID"]
                fulfill_json(
                    route,
                    {
                        "activity": preparation_activity("running", active_preparation_id),
                        "replayed": False,
                    },
                    status=202,
                )
                return
            activities = []
            if preparation_active:
                preparation_reads += 1
                phase = "completed" if preparation_reads >= 2 else "running"
                activities = [preparation_activity(phase, active_preparation_id)]
                if phase == "completed":
                    preparation_active = False
                    active_preparation_id = None
            fulfill_json(
                route,
                {"mediaKind": "image", "isAvailable": True, "activities": activities},
            )

        page.route("**/v1/embedding-preparation?**", handle_preparation)
        page.route("**/v1/embedding-preparation/requests", handle_preparation)

        def handle_sample_suggestions(route):
            nonlocal sample_reads, sample_active
            if route.request.method == "POST":
                submitted_sample_suggestions.append(route.request.post_data_json)
                sample_active = True
                sample_reads = 0
                fulfill_json(
                    route,
                    {"activity": sample_activity("running"), "replayed": False},
                    status=202,
                )
                return
            activities = []
            if sample_active:
                sample_reads += 1
                phase = "completed" if sample_reads >= 2 else "running"
                activities = [sample_activity(phase)]
                if phase == "completed":
                    sample_active = False
            fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "isAvailable": True,
                    "maximumSampleCount": 500,
                    "activities": activities,
                },
            )

        page.route("**/v1/sample-suggestions?**", handle_sample_suggestions)
        page.route("**/v1/sample-suggestions/requests", handle_sample_suggestions)
        page.route(
            "**/v1/tag-library-suggestions?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "maximumPendingCount": 500, "personalCentroidAvailable": False, "personalAdamWAvailable": False, "tags": [], "activities": []}),
        )
        page.route(
            "**/v1/training/activities?**",
            lambda route: fulfill_json(route, []),
        )

        def handle_slimming_launch(route):
            submitted_slimming.append(route.request.post_data_json)
            fulfill_json(
                route,
                {
                    "operationID": "66666666-6666-6666-6666-666666666666",
                    "jobID": SLIMMING_JOB_ID,
                    "acceptedAtMs": 1_700_000_000_000,
                    "memberCount": 2,
                    "replayed": False,
                },
                status=202,
            )

        page.route("**/v1/library-slimming/launch", handle_slimming_launch)

        def slimming_setup_snapshot(media_kind):
            nonlocal source_index_reads, source_index_building
            if source_index_building:
                source_index_reads += 1
                index_state = "ready" if source_index_reads >= 2 else "building"
                if index_state == "ready":
                    source_index_building = False
            else:
                index_state = None
            second_index = None if index_state is None else {
                "state": index_state,
                "assetCount": 80,
                "indexedCount": 80 if index_state == "ready" else 24,
                "clusterCount": 12 if index_state == "ready" else 0,
                "pendingCount": 0 if index_state == "ready" else 56,
                "updatedAtMs": 1_700_000_010_000 + source_index_reads,
            }
            return {
                "mediaKind": media_kind,
                "sources": [
                    {
                        "id": SOURCE_ID,
                        "displayName": "Apple Photos",
                        "kind": "photos",
                        "similarityIndex": {
                            "state": "ready",
                            "assetCount": 120,
                            "indexedCount": 120,
                            "clusterCount": 18,
                            "pendingCount": 0,
                            "updatedAtMs": 1_700_000_009_000,
                        },
                    },
                    {
                        "id": SECOND_SOURCE_ID,
                        "displayName": "旅行归档",
                        "kind": "folder",
                        "similarityIndex": second_index,
                    },
                ],
                "thresholds": dict(active_slimming_thresholds),
                "factoryThresholds": dict(factory_slimming_thresholds),
                "sourceSimilarityIndexAvailable": True,
            }

        def handle_slimming_setup(route):
            slimming_setup_reads[0] += 1
            query = parse_qs(urlparse(route.request.url).query)
            fulfill_json(
                route,
                slimming_setup_snapshot(query.get("mediaKind", ["image"])[0]),
            )

        page.route("**/v1/library-slimming/setup?**", handle_slimming_setup)

        def handle_slimming_thresholds(route):
            payload = route.request.post_data_json
            submitted_slimming_thresholds.append(payload)
            active_slimming_thresholds.clear()
            active_slimming_thresholds.update(payload["thresholds"])
            fulfill_json(
                route,
                {
                    "thresholds": dict(active_slimming_thresholds),
                    "replayed": False,
                },
            )

        page.route(
            "**/v1/library-slimming/thresholds",
            handle_slimming_thresholds,
        )

        def handle_slimming_source_maintenance(route):
            nonlocal source_index_reads, source_index_building
            payload = route.request.post_data_json
            submitted_slimming_source_maintenance.append(payload)
            if payload["action"] == "initializeSimilarityIndex":
                source_index_building = True
                source_index_reads = 0
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "action": payload["action"],
                    "mediaKind": payload["mediaKind"],
                    "sourceIDs": sorted(set(payload["sourceIDs"])),
                    "setup": slimming_setup_snapshot(payload["mediaKind"]),
                    "replayed": False,
                },
                status=202,
            )

        page.route(
            "**/v1/library-slimming/source-maintenance",
            handle_slimming_source_maintenance,
        )

        def slimming_job(job_id, media_kind, mode="seeds"):
            state = slimming_job_states.get(job_id, "completed")
            return {
                "id": job_id,
                "mode": mode,
                "mediaKind": media_kind,
                "state": state,
                "attempts": slimming_job_attempts.get(job_id, 1),
                "maxAttempts": 10,
                "lastErrorCode": slimming_job_error_codes.get(job_id),
                "scanProgress": slimming_job_scan_progress.get(job_id),
                "memberCount": len(SLIMMING_ASSET_IDS),
                "seedCount": 2 if mode == "seeds" else 0,
                "clusterCount": 3 if job_id == SLIMMING_JOB_ID else 0,
                "hasResult": job_id == SLIMMING_JOB_ID,
                "createdAtMs": 1_700_000_000_000,
                "updatedAtMs": 1_700_000_001_000 if job_id == SLIMMING_JOB_ID else 1_699_999_999_000,
                "sourceNames": ["Apple Photos"],
                "availableActions": {
                    "running": ["pause"],
                    "paused": ["resume"],
                    "retryableFailed": ["resume"],
                }.get(state, []),
            }

        def handle_slimming_workspace(route):
            query = parse_qs(urlparse(route.request.url).query)
            media_kind = query.get("mediaKind", ["image"])[0]
            cluster_scope = query.get("clusterScope", ["pending"])[0]
            visible_slimming_asset_ids = [
                asset_id for asset_id in SLIMMING_ASSET_IDS
                if asset_id not in hidden_slimming_asset_ids
            ]
            jobs = [
                slimming_job(SLIMMING_JOB_ID, media_kind),
                slimming_job(SLIMMING_SECOND_JOB_ID, media_kind, mode="catalog"),
            ]
            if expanded_slimming_history_enabled:
                jobs.extend(
                    slimming_job(job_id, media_kind, mode="catalog")
                    for job_id in SLIMMING_HISTORY_JOB_IDS
                )
            jobs = [job for job in jobs if job["id"] not in deleted_slimming_job_ids]
            total_job_count = len(jobs)
            requested_job_id = query.get("jobID", [None])[0]
            selected_job_id = requested_job_id if any(
                job["id"] == requested_job_id for job in jobs
            ) else (jobs[0]["id"] if jobs else None)
            job_limit = max(1, int(query.get("jobLimit", ["100"])[0]))
            if selected_job_id:
                selected_job_index = next(
                    index for index, job in enumerate(jobs)
                    if job["id"] == selected_job_id
                )
                job_limit = max(job_limit, selected_job_index + 1)
            jobs = jobs[:job_limit]
            if expanded_slimming_pagination_enabled and selected_job_id == SLIMMING_JOB_ID:
                cluster_members = {
                    cluster_id: (
                        SLIMMING_PAGINATION_ASSET_IDS
                        if cluster_id == SLIMMING_PAGINATION_CLUSTER_IDS[0]
                        else SLIMMING_PAGINATION_ASSET_IDS[:2]
                    )
                    for cluster_id in SLIMMING_PAGINATION_CLUSTER_IDS
                }
                cluster_dispositions = {
                    cluster_id: None for cluster_id in SLIMMING_PAGINATION_CLUSTER_IDS
                }
            else:
                cluster_members = {
                    SLIMMING_CLUSTER_ID: visible_slimming_asset_ids,
                    SLIMMING_CONFIRMED_CLUSTER_ID: [],
                    SLIMMING_IGNORED_CLUSTER_ID: visible_slimming_asset_ids[:1],
                }
                cluster_dispositions = slimming_cluster_dispositions
            if expanded_slimming_marquee_enabled and selected_job_id == SLIMMING_JOB_ID:
                cluster_members[SLIMMING_CLUSTER_ID] = [
                    *visible_slimming_asset_ids,
                    *[
                        f"91000000-0000-4000-8000-{index:012d}"
                        for index in range(1, 97)
                    ],
                ]
            eligible_cluster_ids = [
                cluster_id for cluster_id, disposition in cluster_dispositions.items()
                if disposition is not None or len(cluster_members[cluster_id]) >= 2
            ]
            all_scoped_cluster_ids = [
                cluster_id for cluster_id, disposition in cluster_dispositions.items()
                if cluster_id in eligible_cluster_ids
                if (cluster_scope == "pending" and disposition is None)
                or disposition == cluster_scope
            ] if selected_job_id == SLIMMING_JOB_ID else []
            requested_cluster_id = query.get("clusterID", [None])[0]
            selected_cluster_id = requested_cluster_id \
                if requested_cluster_id in all_scoped_cluster_ids \
                else (all_scoped_cluster_ids[0] if all_scoped_cluster_ids else None)
            cluster_limit = max(1, int(query.get("clusterLimit", ["48"])[0]))
            scoped_cluster_ids = all_scoped_cluster_ids[:cluster_limit]
            clusters = [{
                "id": cluster_id,
                "kind": "nearDuplicateScene",
                "memberCount": len(cluster_members[cluster_id]),
                "representativeAssetID": (
                    cluster_members[cluster_id][0]
                    if cluster_members[cluster_id]
                    else SLIMMING_ASSET_IDS[0]
                ),
                "score": 0.94 - index * 0.02,
                "isSeedOnlyResult": False,
                "reviewDisposition": cluster_dispositions[cluster_id],
                "originalMemberCount": len(cluster_members[cluster_id]),
                "isHistoricalProcessedRecord": (
                    not expanded_slimming_pagination_enabled
                    and len(cluster_members[cluster_id]) < len(SLIMMING_ASSET_IDS)
                ),
            } for index, cluster_id in enumerate(scoped_cluster_ids)]
            member_limit = max(1, int(query.get("memberLimit", ["96"])[0]))
            selected_member_ids = cluster_members.get(selected_cluster_id, [])[:member_limit]
            fulfill_json(
                route,
                {
                    "mediaKind": media_kind,
                    "jobs": jobs,
                    "totalJobCount": total_job_count,
                    "selectedJobID": selected_job_id,
                    "clusters": clusters,
                    "selectedClusterID": selected_cluster_id,
                    "members": [{
                        "id": asset_id,
                        "sourceID": SOURCE_ID,
                        "sourceName": "Apple Photos",
                        "fileName": (
                            f"SLIM_{(SLIMMING_ASSET_IDS.index(asset_id) + 1) if asset_id in SLIMMING_ASSET_IDS else (index + 1):04}."
                            f"{'MOV' if media_kind == 'video' else 'JPG'}"
                        ),
                        "mediaType": "public.mpeg-4" if media_kind == "video" else "public.jpeg",
                        "availability": "available",
                        "contentRevision": 2,
                        "width": 1920,
                        "height": 1080,
                        "durationMs": 12_000 if media_kind == "video" else None,
                        "favorite": favorite_state(asset_id),
                    } for index, asset_id in enumerate(selected_member_ids)]
                    if selected_cluster_id else [],
                    "pendingAnalysisCount": 0,
                    "analyzedAssetCount": len(visible_slimming_asset_ids),
                    "policyVersion": "librarySlimming.v1",
                    "clusterScopeCounts": {
                        "pending": sum(
                            cluster_dispositions[cluster_id] is None
                            for cluster_id in eligible_cluster_ids
                        ) if selected_job_id == SLIMMING_JOB_ID else 0,
                        "confirmed": sum(
                            cluster_dispositions[cluster_id] == "confirmed"
                            for cluster_id in eligible_cluster_ids
                        ) if selected_job_id == SLIMMING_JOB_ID else 0,
                        "ignored": sum(
                            cluster_dispositions[cluster_id] == "ignored"
                            for cluster_id in eligible_cluster_ids
                        ) if selected_job_id == SLIMMING_JOB_ID else 0,
                    },
                },
            )

        page.route("**/v1/library-slimming/workspace?**", handle_slimming_workspace)

        def handle_slimming_cluster_review(route):
            payload = route.request.post_data_json
            submitted_slimming_cluster_reviews.append(payload)
            slimming_cluster_dispositions[payload["clusterID"]] = payload.get("disposition")
            fulfill_json(route, {
                "operationID": payload["operationID"],
                "jobID": payload["jobID"],
                "clusterID": payload["clusterID"],
                "disposition": payload.get("disposition"),
                "replayed": False,
            })

        page.route(
            "**/v1/library-slimming/cluster-review",
            handle_slimming_cluster_review,
        )

        def handle_slimming_job_action(route):
            payload = route.request.post_data_json
            job_id = route.request.url.split("/jobs/", 1)[1].split("/", 1)[0]
            if slimming_job_action_fail_next[0]:
                slimming_job_action_fail_next[0] = False
                fulfill_json(route, {"message": "合成瘦身任务动作失败"}, status=409)
                return
            submitted_slimming_job_actions.append({"jobID": job_id, **payload})
            if payload["action"] == "deleteRecord":
                deleted_slimming_job_ids.add(job_id)
            elif payload["action"] == "pause":
                slimming_job_states[job_id] = "paused"
            elif payload["action"] == "resume":
                slimming_job_states[job_id] = "running"
            fulfill_json(route, {
                "operationID": payload["operationID"],
                "jobID": job_id,
                "action": payload["action"],
                "deleted": payload["action"] == "deleteRecord",
                "replayed": False,
            })

        page.route(
            "**/v1/library-slimming/jobs/*/actions",
            handle_slimming_job_action,
        )

        def handle_slimming_removals(route):
            nonlocal active_slimming_removal
            if route.request.method == "POST":
                payload = route.request.post_data_json
                submitted_slimming_removals.append(payload)
                active_slimming_removal = {
                    "id": "77777777-4444-4444-4444-444444444444",
                    "operationID": payload["operationID"],
                    "jobID": payload["jobID"],
                    "clusterID": payload["clusterID"],
                    "mediaKind": payload["mediaKind"],
                    "assetIDs": payload["assetIDs"],
                    "mode": payload["mode"],
                    "phase": "awaitingMac",
                    "progress": None,
                    "audit": None,
                    "message": "请回到 Mac 核对并确认",
                    "updatedAtMs": 1_700_000_002_000,
                }
                fulfill_json(route, active_slimming_removal, status=202)
                return
            fulfill_json(
                route,
                {
                    "mediaKind": "video" if "mediaKind=video" in route.request.url else "image",
                    "requests": [active_slimming_removal] if active_slimming_removal else [],
                },
            )

        page.route("**/v1/library-slimming/removals", handle_slimming_removals)
        page.route("**/v1/library-slimming/removals?**", handle_slimming_removals)

        def handle_slimming_recycle(route):
            recycle_request_urls.append(route.request.url)
            if slimming_recycle_query_failures[0] > 0:
                slimming_recycle_query_failures[0] -= 1
                fulfill_json(
                    route,
                    {"code": "syntheticQueryFailure", "message": "模拟回收筛选失败"},
                    status=409,
                )
                return
            query = parse_qs(urlparse(route.request.url).query)
            media_kind = "video" if query.get("mediaKind") == ["video"] else "image"
            scope = query.get("scope", ["all"])[0]
            entry_specs = [
                {
                    "sourceID": SOURCE_ID,
                    "sourceDisplayName": "Apple Photos",
                    "sourceKind": "photos",
                    "state": "recycled",
                    "errorCode": None,
                    "problem": None,
                    "resolution": "photosManagedBySystem",
                    "availableActions": [],
                    "stateMessage": "可恢复",
                    "policyMessage": "恢复与永久删除由“照片”App 管理",
                    "explanationMessage": "请在系统“照片”App 的“最近删除”中恢复；恢复后 ImageAll 会自动对账。",
                },
                {
                    "sourceID": SECOND_SOURCE_ID,
                    "sourceDisplayName": "旅行归档",
                    "sourceKind": "file",
                    "state": "failed",
                    "errorCode": "sourceChanged",
                    "problem": "sourceChanged",
                    "resolution": "refreshSourceBeforeRetry",
                    "availableActions": [],
                    "stateMessage": "来源文件已变化，已停止处理以避免误删",
                    "policyMessage": "原文件未删除；刷新来源并重新分析后再试",
                    "explanationMessage": "目录中的文件与分析时记录不一致。请刷新来源、等待完成、重新分析后再试。",
                },
                {
                    "sourceID": SECOND_SOURCE_ID,
                    "sourceDisplayName": "旅行归档",
                    "sourceKind": "file",
                    "state": "failed",
                    "errorCode": "restoreConflict",
                    "problem": "locationConflict",
                    "resolution": "reinspectFileLocations",
                    "availableActions": ["retryInterruptedOperation"],
                    "stateMessage": "原位置与隔离区同时存在内容，需要核对",
                    "policyMessage": "两处内容均会保留，ImageAll 不会覆盖或删除",
                    "explanationMessage": "原位置与 ImageAll 隔离区同时存在内容。为避免覆盖或误删，两份都会保留。",
                },
                {
                    "sourceID": SECOND_SOURCE_ID,
                    "sourceDisplayName": "旅行归档",
                    "sourceKind": "file",
                    "state": "failed",
                    "errorCode": "mutationAuthorizationInvalid",
                    "problem": "sourceAuthorizationInvalid",
                    "resolution": "updateFolderAuthorization",
                    "availableActions": [],
                    "stateMessage": "原有文件夹回收权限已失效",
                    "policyMessage": "原文件未因本次失败而被修改",
                    "explanationMessage": "已保存的来源回收权限失效。请重新选择原来源更新权限。",
                },
                {
                    "sourceID": SOURCE_ID,
                    "sourceDisplayName": "Apple Photos",
                    "sourceKind": "photos",
                    "state": "failed",
                    "errorCode": "photosAuthorizationRequired",
                    "problem": "photosAuthorizationRequired",
                    "resolution": "requestPhotosAuthorization",
                    "availableActions": [],
                    "stateMessage": "需要 Apple Photos 完整读写权限",
                    "policyMessage": "未确认移入“最近删除”；可修正原因后重试",
                    "explanationMessage": "尚未取得 Apple Photos 完整读写权限，因此没有提交移入“最近删除”。",
                },
                {
                    "sourceID": SOURCE_ID,
                    "sourceDisplayName": "Apple Photos",
                    "sourceKind": "photos",
                    "state": "failed",
                    "errorCode": "photosMutationFailed.userCancelled.1",
                    "problem": "photosUserCancelled",
                    "resolution": "retryFromAnalysis",
                    "availableActions": [],
                    "stateMessage": "已取消系统删除确认，媒体未被删除",
                    "policyMessage": "未确认移入“最近删除”；可修正原因后重试",
                    "explanationMessage": "系统的删除确认已取消，媒体没有被 ImageAll 视为已移入“最近删除”。",
                },
                {
                    "sourceID": SECOND_SOURCE_ID,
                    "sourceDisplayName": "旅行归档",
                    "sourceKind": "file",
                    "state": "failed",
                    "errorCode": "mutationAuthorizationRequired",
                    "problem": "sourceAuthorizationRequired",
                    "resolution": "discardPreflightFailure",
                    "availableActions": ["discardPreflightFailure"],
                    "stateMessage": "尚未开始：需要更新文件夹回收权限",
                    "policyMessage": "原文件未因本次失败而被修改",
                    "explanationMessage": "文件操作尚未开始，原文件没有修改。",
                },
            ]
            entries = []
            if expanded_slimming_recycle_pagination_enabled:
                for index, (entry_id, asset_id) in enumerate(zip(
                    SLIMMING_RECYCLE_PAGINATION_IDS,
                    SLIMMING_RECYCLE_PAGINATION_ASSET_IDS,
                )):
                    photos = index % 3 == 0
                    entries.append({
                        "id": entry_id,
                        "assetID": asset_id,
                        "mediaKind": media_kind,
                        "fileName": f"RECYCLE_PAGE_{index + 1:04}.{'MOV' if media_kind == 'video' else 'JPG'}",
                        "sourceID": SOURCE_ID if photos else SECOND_SOURCE_ID,
                        "sourceDisplayName": "Apple Photos" if photos else "旅行归档",
                        "sourceKind": "photos" if photos else "file",
                        "state": "recycled",
                        "errorCode": None,
                        "problem": None,
                        "resolution": "photosManagedBySystem" if photos else "restoreOrPurge",
                        "availableActions": [] if photos else ["restore", "purge"],
                        "stateMessage": "可恢复",
                        "policyMessage": (
                            "恢复与永久删除由“照片”App 管理"
                            if photos else "文件夹媒体仍在 ImageAll 回收站保护期内"
                        ),
                        "explanationMessage": None,
                        "trashedAtMs": 1_700_000_000_000 + index,
                        "purgeAfterMs": RECYCLE_PURGE_AFTER_MS,
                        "favorite": favorite_state(asset_id),
                    })
            else:
                for index, (entry_id, spec) in enumerate(zip(SLIMMING_RECYCLE_IDS, entry_specs)):
                    asset_id = SLIMMING_ASSET_IDS[index % len(SLIMMING_ASSET_IDS)]
                    entries.append({
                        "id": entry_id,
                        "assetID": asset_id,
                        "mediaKind": media_kind,
                        "fileName": f"RECYCLE_{index + 1:04}.{'MOV' if media_kind == 'video' else 'JPG'}",
                        "trashedAtMs": 1_700_000_000_000,
                        "purgeAfterMs": RECYCLE_PURGE_AFTER_MS,
                        "favorite": favorite_state(asset_id),
                        **spec,
                    })
            if slimming_recycle_poll_revision > 0 and entries:
                entries[0]["policyMessage"] = "Mac 已更新这条 Photos 回收记录的说明"
            if slimming_recycle_poll_revision > 1 and len(entries) > 1:
                entries[1].update({
                    "errorCode": "restoreConflict",
                    "problem": "locationConflict",
                    "resolution": "reinspectFileLocations",
                    "availableActions": ["retryInterruptedOperation"],
                    "stateMessage": "原位置与隔离区同时存在内容，需要核对",
                    "policyMessage": "两处内容均会保留，ImageAll 不会覆盖或删除",
                    "explanationMessage": "原位置与 ImageAll 隔离区同时存在内容。",
                })
            if slimming_recycle_poll_revision > 2 and len(entries) > 1:
                entries.pop(1)
            source_id = query.get("sourceID", [None])[0]
            search = query.get("search", [""])[0].strip().casefold()
            filtered_entries = [
                entry for entry in entries
                if (not source_id or entry["sourceID"] == source_id)
                and (not search or search in entry["fileName"].casefold())
            ]
            scope_counts = {
                "all": len(filtered_entries),
                "photos": sum(entry["sourceKind"] == "photos" for entry in filtered_entries),
                "files": sum(entry["sourceKind"] == "file" for entry in filtered_entries),
                "attention": sum(entry["state"] != "recycled" for entry in filtered_entries),
            }
            if scope == "photos":
                visible_entries = [
                    entry for entry in filtered_entries if entry["sourceKind"] == "photos"
                ]
            elif scope == "files":
                visible_entries = [
                    entry for entry in filtered_entries if entry["sourceKind"] == "file"
                ]
            elif scope == "attention":
                visible_entries = [
                    entry for entry in filtered_entries if entry["state"] != "recycled"
                ]
            else:
                visible_entries = filtered_entries
            total_visible_count = len(visible_entries)
            limit = max(1, int(query.get("limit", ["60"])[0]))
            visible_entries = visible_entries[:limit]
            fulfill_json(
                route,
                {
                    "mediaKind": media_kind,
                    "entries": visible_entries,
                    "totalCount": total_visible_count,
                    "requests": [],
                    "scopeCounts": scope_counts,
                },
            )

        def handle_slimming_recycle_request(route):
            payload = route.request.post_data_json
            submitted_slimming_recycle_actions.append(payload)
            if slimming_recycle_action_failures[0] > 0:
                slimming_recycle_action_failures[0] -= 1
                fulfill_json(
                    route,
                    {"code": "syntheticFailure", "message": "模拟回收动作失败"},
                    status=409,
                )
                return
            fulfill_json(
                route,
                {
                    "id": f"cccccccc-4444-4444-4444-{len(submitted_slimming_recycle_actions):012d}",
                    "operationID": payload["operationID"],
                    "entryID": payload["entryID"],
                    "action": payload["action"],
                    "fileName": "RECYCLE",
                    "phase": "completed",
                    "message": "已完成回收恢复动作",
                    "updatedAtMs": 1_700_000_030_000 + len(submitted_slimming_recycle_actions),
                },
            )

        page.route("**/v1/library-slimming/recycle?**", handle_slimming_recycle)
        page.route("**/v1/library-slimming/recycle/requests", handle_slimming_recycle_request)

        page.route(
            "**/v1/library-slimming/identical-cleanup/requests?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "requests": []}),
        )

        page.goto(BASE_URL, wait_until="networkidle")
        assert page.locator("#inspectorPlaceholder").is_visible()
        assert page.locator("#inspectorPlaceholderTagEditor").is_visible()
        assert page.locator("#inspectorPlaceholderTitle").inner_text() == "未选择照片"
        assert page.locator("#inspectorPlaceholderText").inner_text() == (
            "选择一张或多张照片后，可左键打上标签、右键取消标签。"
        )
        assert page.locator("#inspectorPlaceholderTags [data-tag-reorder-surface=placeholder]").count() == 2
        placeholder_cat_chip = page.locator(
            f'#inspectorPlaceholderTags [data-tag-id="{CAT_TAG_ID}"]'
        )
        assert placeholder_cat_chip.get_attribute("aria-disabled") == "true"
        assert placeholder_cat_chip.get_attribute("draggable") == "true"
        placeholder_cat_chip.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        placeholder_help = page.locator("#persistentHelpDetail").inner_text()
        assert "选择照片后" in placeholder_help
        assert "拖动可调整顺序或分组" in placeholder_help
        placeholder_decision_count = len(submitted_tag_decisions)
        placeholder_cat_chip.dispatch_event("click")
        assert len(submitted_tag_decisions) == placeholder_decision_count
        assert page.evaluate("() => state.selectedAssetID === null")
        placeholder_group_toggle = page.locator(
            f'#inspectorPlaceholderTags [data-inspector-tag-group-toggle="{SUBJECT_GROUP_ID}"]'
        )
        placeholder_group_toggle.click()
        assert placeholder_group_toggle.get_attribute("aria-expanded") == "false"
        placeholder_group_toggle.click()
        assert placeholder_group_toggle.get_attribute("aria-expanded") == "true"
        assert page.locator("#favoritesNavigationButton").is_visible()
        assert page.locator("#retryFavoriteSyncButton").is_visible()
        assert page.locator("#retryFavoriteSyncCount").inner_text() == "1"
        page.locator("#commandButton").click()
        assert page.locator('[data-command-id="retryFavoriteSync"]').is_visible()
        page.keyboard.press("Escape")
        page.locator("#retryFavoriteSyncButton").click()
        page.locator("#retryFavoriteSyncButton").wait_for(state="hidden")
        assert len(submitted_favorite_retries) == 1
        page.locator("#commandButton").click()
        page.locator('[data-command-id="showFavorites"]').click()
        page.wait_for_function(
            "() => document.querySelectorAll('#assetGrid > .asset-card').length === 0"
        )
        assert any("favorite=favorited" in url for url in asset_request_urls)
        assert "红心收藏" in page.locator("#libraryTitle").inner_text()
        page.locator('#libraryNavigation [data-source-id=""]').click()
        page.wait_for_function(
            "() => document.querySelectorAll('#assetGrid > .asset-card').length === 2"
        )
        grid_cards = page.locator("#assetGrid > .asset-card")
        first_grid_main = grid_cards.nth(0).locator(":scope > .asset-card-main")
        second_grid_main = grid_cards.nth(1).locator(":scope > .asset-card-main")
        first_grid_favorite = grid_cards.nth(0).locator(":scope > .asset-card-favorite")
        second_grid_favorite = grid_cards.nth(1).locator(":scope > .asset-card-favorite")
        assert first_grid_main.get_attribute("tabindex") == "0"
        assert first_grid_favorite.get_attribute("tabindex") == "0"
        assert second_grid_main.get_attribute("tabindex") == "-1"
        assert second_grid_favorite.get_attribute("tabindex") == "-1"
        first_grid_main.focus()
        page.keyboard.press("Tab")
        assert page.evaluate(
            "() => document.activeElement?.classList.contains('asset-card-favorite')"
        )
        page.keyboard.press("Tab")
        assert not page.evaluate(
            "() => document.querySelector('#assetGrid').contains(document.activeElement)"
        )
        second_grid_main.focus()
        assert first_grid_main.get_attribute("tabindex") == "-1"
        assert first_grid_favorite.get_attribute("tabindex") == "-1"
        assert second_grid_main.get_attribute("tabindex") == "0"
        assert second_grid_favorite.get_attribute("tabindex") == "0"
        first_grid_main.focus()
        page.screenshot(path="/tmp/imageall-gallery-roving-focus.png", full_page=False)
        sidebar_help_snapshot = page.evaluate(
            """() => ({
              selectedSourceID: state.selectedSourceID,
              tagConditions: structuredClone(state.filters.tagConditions),
              loadedIDs: state.assets.map((asset) => asset.id),
              selectedIDs: [...state.selectedAssetIDs],
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        )
        source_row = page.locator(f'#sourceList [data-source-id="{SOURCE_ID}"]')
        source_row.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        page.wait_for_timeout(150)
        assert page.locator("#persistentHelpTitle").inner_text() == "Apple Photos"
        source_help_detail = page.locator("#persistentHelpDetail").inner_text()
        for expected in [
            "来源可用",
            "点击只显示“Apple Photos”",
            "Shift-F10 可排序，并查看同步、缓存、授权、管理和移除动作",
            "Option + 上/下可用键盘移动",
        ]:
            assert expected in source_help_detail, (expected, source_help_detail)
        assert source_row.get_attribute("title") is None
        page.screenshot(path="/tmp/imageall-sidebar-source-tag-help.png", full_page=False)
        source_row.focus()
        page.keyboard.press("Shift+F10")
        page.locator("#sourceContextMenu:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#sourceContextMenu').contains(document.activeElement)"
        )
        source_context_history = page.evaluate(
            """() => {
              const entry = history.state?.imageAllWorkspace;
              return {
                navigationLevel: entry?.navigationLevel,
                kind: entry?.context?.contextMenuKind,
                contextKeys: Object.keys(entry?.context || {}),
              };
            }"""
        )
        assert source_context_history["navigationLevel"] == "contextMenu"
        assert source_context_history["kind"] == "source"
        assert all(
            key in {"contextMenuKind", "contextMenuBaseLevel"}
            for key in source_context_history["contextKeys"]
            if key.startswith("contextMenu")
        )
        page.evaluate("() => history.back()")
        page.locator("#sourceContextMenu").wait_for(state="hidden")
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.sourceId === sourceID",
            arg=SOURCE_ID,
        )
        page.evaluate("() => history.forward()")
        page.locator("#sourceContextMenu:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#sourceContextMenu').contains(document.activeElement)"
        )
        assert page.evaluate(
            "() => ({ selectedSourceID: state.selectedSourceID, "
            "tagConditions: structuredClone(state.filters.tagConditions), "
            "loadedIDs: state.assets.map((asset) => asset.id), "
            "selectedIDs: [...state.selectedAssetIDs], "
            "scrollTop: document.querySelector('#libraryScroll').scrollTop })"
        ) == sidebar_help_snapshot
        page.keyboard.press("Escape")
        page.locator("#sourceContextMenu").wait_for(state="hidden")
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.sourceId === sourceID",
            arg=SOURCE_ID,
        )

        subject_sidebar_toggle = page.locator(
            f'[data-sidebar-tag-group-toggle="{SUBJECT_GROUP_ID}"]'
        )
        subject_sidebar_toggle.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert page.locator("#persistentHelpTitle").inner_text() == "标签分组 · 主体"
        sidebar_group_help = page.locator("#persistentHelpDetail").inner_text()
        assert "Home/End 在分组之间移动" in sidebar_group_help
        assert "Shift-F10 可重命名或删除分组" in sidebar_group_help

        sidebar_cat_chip = page.locator(f'[data-quick-tag-id="{CAT_TAG_ID}"]')
        sidebar_cat_chip.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert page.locator("#persistentHelpTitle").inner_text() == "猫"
        unfiltered_tag_help = page.locator("#persistentHelpDetail").inner_text()
        assert "当前：未筛选" in unfiltered_tag_help
        assert "Command-点击或 Command-Return 加入交集" in unfiltered_tag_help
        assert "Shift-F10 可排序、移动分组、筛选、重命名或归档" in unfiltered_tag_help
        sidebar_cat_chip.click()
        page.wait_for_function(
            "tagID => state.filters.tagConditions.some((item) => "
            "item.tagID === tagID && item.decision === 'accepted')",
            arg=CAT_TAG_ID,
        )
        page.mouse.move(2, 2)
        sidebar_cat_chip.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert "当前：并集筛选" in page.locator("#persistentHelpDetail").inner_text()
        sidebar_cat_chip.click()
        page.wait_for_function(
            "tagID => !state.filters.tagConditions.some((item) => item.tagID === tagID)",
            arg=CAT_TAG_ID,
        )
        page.wait_for_function(
            "() => !state.loadingAssets && !state.assetLoadPromise && !state.queuedAssetLoadOptions"
        )
        sidebar_cat_chip.focus()
        page.keyboard.press("Shift+F10")
        page.locator("#tagContextMenu:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#tagContextMenu').contains(document.activeElement)"
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "contextMenu"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.contextMenuKind"
        ) == "tag"
        page.evaluate("() => history.back()")
        page.locator("#tagContextMenu").wait_for(state="hidden")
        page.wait_for_function(
            "tagID => document.activeElement?.dataset.quickTagId === tagID",
            arg=CAT_TAG_ID,
        )
        page.evaluate("() => history.forward()")
        page.locator("#tagContextMenu:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#tagContextMenu').contains(document.activeElement)"
        )
        page.keyboard.press("Escape")
        page.locator("#tagContextMenu").wait_for(state="hidden")
        page.wait_for_function(
            "tagID => document.activeElement?.dataset.quickTagId === tagID",
            arg=CAT_TAG_ID,
        )
        page.locator("#tagNavigationSearch").fill("猫")
        page.mouse.move(2, 2)
        sidebar_cat_chip.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert "正在搜索标签" in page.locator("#persistentHelpDetail").inner_text()
        tag_search_asset_requests = len(asset_request_urls)
        page.locator("#tagNavigationSearch").press("Escape")
        assert page.locator("#tagNavigationSearch").input_value() == ""
        assert page.evaluate("() => document.activeElement?.id") == "tagNavigationSearch"
        assert len(asset_request_urls) == tag_search_asset_requests

        page.set_viewport_size({"width": 390, "height": 844})
        page.locator("#sidebarToggle").click()
        page.locator("#sourceSidebar.open").wait_for()
        sidebar_cat_chip.scroll_into_view_if_needed()
        page.mouse.move(389, 2)
        sidebar_cat_chip.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        page.wait_for_timeout(150)
        narrow_sidebar_help = page.locator("#persistentHelp").bounding_box()
        assert narrow_sidebar_help is not None
        assert narrow_sidebar_help["x"] >= 8, narrow_sidebar_help
        assert narrow_sidebar_help["x"] + narrow_sidebar_help["width"] <= 382, narrow_sidebar_help
        assert narrow_sidebar_help["y"] >= 8, narrow_sidebar_help
        assert narrow_sidebar_help["y"] + narrow_sidebar_help["height"] <= 836, narrow_sidebar_help
        page.screenshot(
            path="/tmp/imageall-sidebar-source-tag-help-390.png",
            full_page=False,
        )
        page.locator("#sidebarToggle").click()
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_timeout(100)
        assert page.evaluate(
            """() => ({
              selectedSourceID: state.selectedSourceID,
              tagConditions: structuredClone(state.filters.tagConditions),
              loadedIDs: state.assets.map((asset) => asset.id),
              selectedIDs: [...state.selectedAssetIDs],
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == sidebar_help_snapshot
        page.evaluate(
            """() => {
              setSelectionMode(true);
              const grid = document.querySelector('#assetGrid');
              const template = grid.querySelector(':scope > .asset-card');
              for (let index = 1; index <= 48; index += 1) {
                const clone = template.cloneNode(true);
                const assetID = `90000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
                clone.dataset.assetId = assetID;
                clone.dataset.marqueeFixture = 'library';
                clone.classList.remove('selected', 'batch-selected');
                clone.querySelector('.asset-card-main')?.setAttribute('aria-pressed', 'false');
                grid.append(clone);
              }
            }"""
        )
        library_marquee_scroll = drag_marquee_to_bottom_edge(
            page,
            "#libraryScroll",
            "#assetGrid",
        )
        library_marquee_selection = page.evaluate(
            "() => [...state.selectedAssetIDs]"
        )
        assert library_marquee_scroll > 80
        assert ASSET_IDS[0] in library_marquee_selection
        assert any(
            asset_id.startswith("90000000-0000-4000-8000-")
            for asset_id in library_marquee_selection
        )
        page.evaluate(
            """() => {
              document.querySelector('#libraryScroll').scrollTop = 0;
              setSelectionMode(false);
            }"""
        )
        first_card = page.locator("#assetGrid > .asset-card").first
        first_favorite = first_card.locator(":scope > .asset-card-favorite")
        first_card.hover()
        assert first_favorite.is_visible()
        assert first_favorite.get_attribute("data-favorite") == "false"
        initial_grid_scroll = page.locator("#libraryScroll").evaluate("element => element.scrollTop")
        first_favorite.click()
        page.wait_for_function(
            "() => document.querySelector('#assetGrid > .asset-card .asset-card-favorite')"
            "?.dataset.favorite === 'true'"
        )
        assert page.locator("#assetGrid > .asset-card.selected").count() == 0
        assert page.locator("#lightbox").is_hidden()
        assert page.locator("#libraryScroll").evaluate("element => element.scrollTop") == initial_grid_scroll
        first_favorite.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('#assetGrid > .asset-card .asset-card-favorite')"
            "?.dataset.favorite === 'false'"
        )
        assert page.locator("#assetGrid > .asset-card.selected").count() == 0
        assert page.locator("#lightbox").is_hidden()
        first_card.click()
        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert page.locator("#lightboxFavoriteButton").is_visible()
        assert page.locator("#lightboxFavoriteButton").is_enabled()
        assert page.locator("#lightboxFavoriteButton").get_attribute("data-favorite") == "false"
        page.locator("#lightboxFavoriteButton").focus()
        page.keyboard.press("Space")
        page.wait_for_function(
            "() => document.querySelector('#lightboxFavoriteButton')?.dataset.favorite === 'true'"
        )
        assert not page.locator("#lightbox").evaluate("element => element.classList.contains('hidden')")
        assert page.evaluate("() => document.activeElement?.id") == "lightboxFavoriteButton"
        assert submitted_favorites[-1]["assetIDs"] == [ASSET_IDS[0]]
        assert submitted_favorites[-1]["isFavorite"] is True
        page.screenshot(
            path="/tmp/imageall-lightbox-space-button-focus.png",
            full_page=True,
        )
        page.keyboard.press("Space")
        page.wait_for_function(
            "() => document.querySelector('#lightboxFavoriteButton')?.dataset.favorite === 'false'"
        )
        assert not page.locator("#lightbox").evaluate("element => element.classList.contains('hidden')")
        assert submitted_favorites[-1]["isFavorite"] is False
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")

        single_inline_input = page.locator("#inspectorInlineTagName")
        page.wait_for_function(
            "id => state.selectedAssetID === id && state.selectedDetail?.assetID === id",
            arg=ASSET_IDS[0],
        )
        assert page.locator("#inspectorSelectionHeading").is_visible()
        assert page.locator("#inspectorSelectionTitle").inner_text() == "已选择 1 张照片"
        assert page.locator("#inspectorFavoriteButton").inner_text().strip() == "♥ 加入红心"
        assert page.locator("#inspectorUnfavoriteButton").inner_text().strip() == "♡ 取消红心"
        assert page.locator("#inspectorDeleteButton").is_visible()
        single_inspector_layout = page.evaluate(
            """() => ({
              headingBottom: document.querySelector('#inspectorSelectionHeading')
                .getBoundingClientRect().bottom,
              previewTop: document.querySelector('#inspectorContent .preview-wrap')
                .getBoundingClientRect().top,
            })"""
        )
        assert single_inspector_layout["previewTop"] >= single_inspector_layout["headingBottom"] - 1
        page.screenshot(path="/tmp/imageall-single-inspector-action-strip.png", full_page=True)
        single_action_favorite_count = len(submitted_favorites)
        page.locator("#inspectorFavoriteButton").click()
        page.wait_for_function(
            "id => state.selectedDetail?.assetID === id "
            "&& state.selectedDetail.favorite?.isFavorite === true",
            arg=ASSET_IDS[0],
        )
        assert len(submitted_favorites) == single_action_favorite_count + 1
        assert submitted_favorites[-1]["isFavorite"] is True
        page.locator("#inspectorUnfavoriteButton").click()
        page.wait_for_function(
            "id => state.selectedDetail?.assetID === id "
            "&& state.selectedDetail.favorite?.isFavorite === false",
            arg=ASSET_IDS[0],
        )
        assert len(submitted_favorites) == single_action_favorite_count + 2
        assert submitted_favorites[-1]["isFavorite"] is False
        if inspector_actions_only:
            page.set_viewport_size({"width": 390, "height": 844})
            page.wait_for_timeout(120)
            narrow_single_inspector = page.evaluate(
                """() => {
                  const heading = document.querySelector('#inspectorSelectionHeading')
                    .getBoundingClientRect();
                  const actions = [...document.querySelectorAll(
                    '#inspectorSelectionHeading .inspector-single-actions .button'
                  )].map(button => button.getBoundingClientRect());
                  const close = document.querySelector('#closeInspectorButton')
                    .getBoundingClientRect();
                  return {
                    viewport: innerWidth,
                    pageScrollWidth: document.documentElement.scrollWidth,
                    heading: { left: heading.left, right: heading.right },
                    actions: actions.map(rect => ({ left: rect.left, right: rect.right })),
                    close: {
                      left: close.left,
                      right: close.right,
                      top: close.top,
                      bottom: close.bottom,
                    },
                  };
                }"""
            )
            assert narrow_single_inspector["pageScrollWidth"] <= 390, narrow_single_inspector
            assert narrow_single_inspector["heading"]["left"] >= 0, narrow_single_inspector
            assert narrow_single_inspector["heading"]["right"] <= 390, narrow_single_inspector
            assert all(
                bounds["left"] >= 0 and bounds["right"] <= 390
                for bounds in narrow_single_inspector["actions"]
            ), narrow_single_inspector
            assert page.locator("#closeInspectorButton").is_visible(), narrow_single_inspector
            assert narrow_single_inspector["close"]["left"] >= 0, narrow_single_inspector
            assert narrow_single_inspector["close"]["right"] <= 390, narrow_single_inspector
            page.screenshot(
                path="/tmp/imageall-single-inspector-action-strip-390.png",
                full_page=True,
            )
            assert not page_errors, page_errors
            assert not console_errors, console_errors
            assert not unexpected_dialogs, unexpected_dialogs
            context.close()
            browser.close()
            print(
                "single inspector action strip browser flow passed; "
                f"favorites={len(submitted_favorites)}"
            )
            return
        assert single_inline_input.is_visible()
        assert not page.locator("#newTagDialog").evaluate("element => element.open")
        single_inline_snapshot = page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs],
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
              loadedIDs: state.assets.map((asset) => asset.id),
            })"""
        )
        single_inline_input.fill("重试标签")
        single_inline_input.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('#inspectorInlineTagError')"
            "?.textContent.includes('模拟暂时冲突')"
        )
        assert len(submitted_created_tags) == 1
        retry_operation_id = submitted_created_tags[0]["operationID"]
        assert submitted_created_tags[0]["assetIDs"] == [ASSET_IDS[0]]
        assert single_inline_input.input_value() == "重试标签"
        single_inline_input.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('#inspectorInlineTagName').value === '' "
            "&& document.activeElement?.id === 'inspectorInlineTagName'"
        )
        assert len(submitted_created_tags) == 2
        assert submitted_created_tags[1]["operationID"] == retry_operation_id
        assert submitted_created_tags[1]["assetIDs"] == [ASSET_IDS[0]]
        page.wait_for_function(
            "tagID => document.querySelector("
            "`#inspectorTags [data-tag-chip-action][data-tag-id=\"${tagID}\"]`"
            ")?.dataset.decision === 'accepted'",
            arg=SINGLE_CREATED_TAG_ID,
        )
        assert page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs],
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
              loadedIDs: state.assets.map((asset) => asset.id),
            })"""
        ) == single_inline_snapshot
        assert not page.locator("#newTagDialog").evaluate("element => element.open")
        single_inline_input.fill("临时草稿")
        single_inline_input.press("Escape")
        assert single_inline_input.input_value() == ""
        assert len(submitted_created_tags) == 2
        page.screenshot(path="/tmp/imageall-inspector-inline-tag.png", full_page=True)

        page.locator("#selectionModeButton").click()
        cards = page.locator("#assetGrid > .asset-card")
        assert cards.count() == 2
        cards.nth(0).click()
        first_main = cards.nth(0).locator(":scope > .asset-card-main")
        first_main.focus()
        assert "Home End" in first_main.get_attribute("aria-keyshortcuts")
        assert "Shift 扩展选择" in first_main.get_attribute("data-help-detail")
        page.keyboard.press("End")
        assert page.evaluate(
            "id => state.selectedAssetIDs.size === 1 "
            "&& state.selectedAssetIDs.has(id) "
            "&& state.selectedAssetID === id",
            ASSET_IDS[1],
        )
        assert page.evaluate(
            "id => document.activeElement?.closest('[data-asset-id]')?.dataset.assetId === id "
            "&& document.querySelectorAll('#assetGrid .asset-card-main[tabindex=\"0\"]')"
            ".length === 1 "
            "&& document.querySelectorAll('#assetGrid .asset-card-favorite[tabindex=\"0\"]')"
            ".length === 1",
            ASSET_IDS[1],
        )
        page.keyboard.down("Shift")
        page.keyboard.press("Home")
        page.keyboard.up("Shift")
        assert set(page.evaluate("() => [...state.selectedAssetIDs]")) == set(ASSET_IDS)
        assert page.evaluate(
            "([primaryID, anchorID]) => state.selectedAssetID === primaryID "
            "&& state.selectionAnchorID === anchorID",
            [ASSET_IDS[0], ASSET_IDS[1]],
        )
        page.screenshot(
            path="/tmp/imageall-gallery-keyboard-range-selection.png",
            full_page=True,
        )
        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "IMG_0001.JPG" in page.locator("#lightboxTitle").inner_text()
        page.keyboard.press("Space")
        page.locator("#lightbox").wait_for(state="hidden")
        assert set(page.evaluate("() => [...state.selectedAssetIDs]")) == set(ASSET_IDS)
        assert page.evaluate(
            "([primaryID, anchorID]) => state.selectedAssetID === primaryID "
            "&& state.selectionAnchorID === anchorID",
            [ASSET_IDS[0], ASSET_IDS[1]],
        )
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('asset-card-main')"
        )
        page.keyboard.press("End")
        assert page.evaluate(
            "id => state.selectedAssetIDs.size === 1 "
            "&& state.selectedAssetIDs.has(id)",
            ASSET_IDS[1],
        )
        page.keyboard.press("PageUp")
        assert page.evaluate(
            "id => state.selectedAssetIDs.size === 1 "
            "&& state.selectedAssetIDs.has(id)",
            ASSET_IDS[0],
        )
        page.keyboard.press("PageDown")
        assert page.evaluate(
            "id => state.selectedAssetIDs.size === 1 "
            "&& state.selectedAssetIDs.has(id)",
            ASSET_IDS[1],
        )
        page.keyboard.press("Home")
        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "IMG_0001.JPG" in page.locator("#lightboxTitle").inner_text()
        page.keyboard.press("Space")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('asset-card-main')"
        )
        cards.nth(0).click()
        cards.nth(1).click(modifiers=["Meta"])
        assert "已选择 2 项" in page.locator("#selectionSummary").inner_text()
        gallery_double_click_snapshot = page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectedAssetID: state.selectedAssetID,
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        )
        cards.nth(0).locator(":scope > .asset-card-main").dblclick()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "IMG_0001.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectedAssetID: state.selectedAssetID,
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == gallery_double_click_snapshot
        assert page.evaluate("() => state.lightboxPreservesSelection") is True
        page.locator("#lightboxNextButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('IMG_0002.JPG')"
        )
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectedAssetID: state.selectedAssetID,
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == gallery_double_click_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectedAssetID: state.selectedAssetID,
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == gallery_double_click_snapshot
        page.evaluate("() => history.forward()")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "IMG_0002.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate(
            "() => state.lightboxPreservesSelection "
            "&& history.state?.imageAllWorkspace?.context?.galleryLightbox"
            "?.preserveSelection === true"
        )
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectedAssetID: state.selectedAssetID,
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == gallery_double_click_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('asset-card-main')"
        )
        page.locator("#selectionInspector:not(.hidden)").wait_for()
        page.locator("#selectionInspectorPrimary:not(.hidden)").wait_for()
        page.wait_for_function(
            "id => state.selectionPrimaryDetail?.assetID === id",
            arg=ASSET_IDS[1],
        )
        assert page.locator("#selectionInspectorPrimaryTitle").inner_text() == "IMG_0002.JPG"
        primary_metadata = page.locator("#selectionInspectorPrimaryMetadata").inner_text()
        assert "精选/IMG_0002.JPG" in primary_metadata
        assert "4032 × 3024" in primary_metadata
        page.locator("#selectionInspectorPrimaryPreview").click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "IMG_0002.JPG" in page.locator("#lightboxTitle").inner_text()
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        assert set(page.evaluate("() => [...state.selectedAssetIDs]")) == set(ASSET_IDS)
        assert page.locator("#selectionInspectorTags .inspector-tag-group").count() == 2
        cat_chip = page.locator(
            f'#selectionInspectorTags [data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]'
        )
        travel_chip = page.locator(
            f'#selectionInspectorTags [data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
        )
        page.wait_for_function(
            "([catID, travelID]) => "
            "document.querySelector(`#selectionInspectorTags [data-tag-id=\"${catID}\"]`)?.dataset.decision === 'accepted' "
            "&& document.querySelector(`#selectionInspectorTags [data-tag-chip-action][data-tag-id=\"${travelID}\"]`)?.dataset.decision === 'mixed' "
            "&& document.querySelector(`#selectionInspectorTags [data-tag-chip-action][data-tag-id=\"${travelID}\"]`)?.innerText.includes('混合')",
            arg=[CAT_TAG_ID, TRAVEL_TAG_ID],
        )
        assert cat_chip.get_attribute("data-decision") == "accepted"
        assert travel_chip.get_attribute("data-decision") == "mixed"
        assert "混合" in travel_chip.inner_text()
        cat_chip.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert page.locator("#persistentHelpTitle").inner_text() == "猫"
        cat_help_detail = page.locator("#persistentHelpDetail").inner_text()
        for expected in [
            "所选项目：全部确认",
            "左键把所选项目全部确认",
            "按 X 拒绝",
            "Option + 上/下调整顺序",
        ]:
            assert expected in cat_help_detail, (expected, cat_help_detail)
        assert cat_chip.get_attribute("title") is None
        page.wait_for_timeout(150)
        page.screenshot(path="/tmp/imageall-inspector-tag-help.png", full_page=False)
        cat_reject_button = page.locator(
            f'#selectionInspectorTags [data-action="reject"][data-tag-id="{CAT_TAG_ID}"]'
        )
        cat_reject_button.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert page.locator("#persistentHelpTitle").inner_text() == "猫 · 拒绝"
        assert "把全部所选项目设为“拒绝”" in page.locator(
            "#persistentHelpDetail"
        ).inner_text()
        subject_toggle = page.locator(
            f'#selectionInspectorTags [data-inspector-tag-group-toggle="{SUBJECT_GROUP_ID}"]'
        )
        subject_toggle.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert page.locator("#persistentHelpTitle").inner_text() == "标签分组 · 主体"
        subject_help_detail = page.locator("#persistentHelpDetail").inner_text()
        assert "Shift-F10 可重命名或删除分组" in subject_help_detail
        assert "Home/End 在分组之间移动" in subject_help_detail
        subject_toggle.focus()
        page.keyboard.press("Shift+F10")
        page.locator("#tagContextMenu:not(.hidden)").wait_for()
        assert page.locator('[data-tag-context-action="renameGroup"]').is_visible()
        assert page.locator('[data-tag-context-action="deleteGroup"]').is_visible()
        page.wait_for_function(
            "() => document.querySelector('#tagContextMenu').contains(document.activeElement)"
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.contextMenuKind"
        ) == "tag"
        page.evaluate("() => history.back()")
        page.locator("#tagContextMenu").wait_for(state="hidden")
        page.wait_for_function(
            "groupID => document.activeElement?.dataset.inspectorTagGroupToggle === groupID",
            arg=SUBJECT_GROUP_ID,
        )
        page.evaluate("() => history.forward()")
        page.locator("#tagContextMenu:not(.hidden)").wait_for()
        assert page.locator('[data-tag-context-action="renameGroup"]').is_visible()
        page.keyboard.press("Escape")
        page.locator("#tagContextMenu").wait_for(state="hidden")
        page.wait_for_function(
            "groupID => document.activeElement?.dataset.inspectorTagGroupToggle === groupID",
            arg=SUBJECT_GROUP_ID,
        )
        subject_toggle.click(button="right")
        page.locator("#tagContextMenu:not(.hidden)").wait_for()
        page.locator('[data-tag-context-action="renameGroup"]').click()
        page.locator("#tagManagerDialog").wait_for(state="visible")
        assert page.locator("#tagManagerGroupName").input_value() == "主体"
        assert page.evaluate("() => document.activeElement?.id") == "tagManagerGroupName"
        page.locator("#closeTagManagerButton").click()
        page.wait_for_function(
            "groupID => document.activeElement?.dataset.inspectorTagGroupToggle === groupID",
            arg=SUBJECT_GROUP_ID,
        )
        selection_inline_snapshot = page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
              loadedIDs: state.assets.map((asset) => asset.id),
            })"""
        )
        selection_inline_input = page.locator("#selectionInspectorInlineTagName")
        assert selection_inline_input.is_enabled()
        selection_inline_input.fill("家人")
        selection_inline_input.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('#selectionInspectorInlineTagName').value === '' "
            "&& document.activeElement?.id === 'selectionInspectorInlineTagName'"
        )
        assert len(submitted_created_tags) == 3
        assert submitted_created_tags[-1]["operationID"] != retry_operation_id
        assert set(submitted_created_tags[-1]["assetIDs"]) == set(ASSET_IDS)
        page.wait_for_function(
            "tagID => { const chip = document.querySelector("
            "`#selectionInspectorTags [data-tag-chip-action][data-tag-id=\"${tagID}\"]`"
            "); return chip?.dataset.decision === 'accepted' "
            "&& chip.innerText.includes('全部确认'); }",
            arg=SELECTION_CREATED_TAG_ID,
        )
        assert page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
              loadedIDs: state.assets.map((asset) => asset.id),
            })"""
        ) == selection_inline_snapshot
        assert not page.locator("#newTagDialog").evaluate("element => element.open")
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        inline_dimensions = page.evaluate(
            """() => {
              const form = document.querySelector('#selectionInspectorInlineTagForm').getBoundingClientRect();
              const input = document.querySelector('#selectionInspectorInlineTagName').getBoundingClientRect();
              const button = document.querySelector('#selectionInspectorNewTagButton').getBoundingClientRect();
              return {
                viewport: innerWidth,
                scroll: document.documentElement.scrollWidth,
                form: { left: form.left, right: form.right },
                input: { left: input.left, right: input.right },
                button: { left: button.left, right: button.right },
              };
            }"""
        )
        assert inline_dimensions["scroll"] <= inline_dimensions["viewport"], inline_dimensions
        for bounds in (
            inline_dimensions["form"],
            inline_dimensions["input"],
            inline_dimensions["button"],
        ):
            assert bounds["left"] >= 0 and bounds["right"] <= 390, inline_dimensions
        family_chip = page.locator(
            f'#selectionInspectorTags [data-tag-chip-action][data-tag-id="{SELECTION_CREATED_TAG_ID}"]'
        )
        selection_search_asset_requests = len(asset_request_urls)
        page.locator("#selectionTagSearch").fill("家")
        page.locator("#selectionTagSearch").press("Escape")
        assert page.locator("#selectionTagSearch").input_value() == ""
        assert page.evaluate("() => state.selectionTagSearchText") == ""
        assert page.evaluate("() => state.selectionMode") is True
        assert page.evaluate("() => document.activeElement?.id") == "selectionTagSearch"
        assert len(asset_request_urls) == selection_search_asset_requests
        family_chip.focus()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        page.wait_for_timeout(150)
        assert page.locator("#persistentHelpTitle").inner_text() == "家人"
        narrow_help_detail = page.locator("#persistentHelpDetail").inner_text()
        assert "所选项目：全部确认" in narrow_help_detail
        narrow_help_bounds = page.locator("#persistentHelp").bounding_box()
        assert narrow_help_bounds is not None
        assert narrow_help_bounds["x"] >= 8, narrow_help_bounds
        assert narrow_help_bounds["x"] + narrow_help_bounds["width"] <= 382, narrow_help_bounds
        assert narrow_help_bounds["y"] >= 8, narrow_help_bounds
        assert narrow_help_bounds["y"] + narrow_help_bounds["height"] <= 836, narrow_help_bounds
        page.screenshot(path="/tmp/imageall-selection-tag-help-390.png", full_page=False)
        page.locator("#selectionTagSearch").focus()
        page.mouse.move(2, 2)
        page.locator("#persistentHelp").wait_for(state="hidden")
        page.screenshot(path="/tmp/imageall-selection-inline-tag-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_timeout(100)
        scene_toggle = page.locator(
            f'#selectionInspectorTags [data-inspector-tag-group-toggle="{SCENE_GROUP_ID}"]'
        )
        scene_toggle.click()
        assert scene_toggle.get_attribute("aria-expanded") == "false"
        assert page.evaluate(
            "(groupID) => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
            ".collapsedInspectorTagGroupIDs.includes(groupID)",
            SCENE_GROUP_ID,
        )
        assert page.evaluate(
            "(groupID) => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
            ".collapsedTagGroupIDs.includes(groupID)",
            SCENE_GROUP_ID,
        )
        scene_toggle.click()
        page.evaluate(
            f"""() => {{
              const container = document.querySelector("#selectionInspectorTags");
              const subject = container.querySelector(
                '[data-inspector-tag-group-id="{SUBJECT_GROUP_ID}"]'
              );
              const scene = container.querySelector(
                '[data-inspector-tag-group-id="{SCENE_GROUP_ID}"]'
              );
              const cat = container.querySelector(
                '[data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]'
              );
              const travel = container.querySelector(
                '[data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
              );
              window.__stableSelectionInspectorTagFrame = {{
                container,
                subject,
                scene,
                cat,
                travel,
                catRow: cat.closest(".selection-tag-row"),
                travelRow: travel.closest(".selection-tag-row"),
                catActions: [...cat.closest(".selection-tag-row").querySelectorAll(
                  '[data-action][data-tag-id]'
                )],
                travelActions: [...travel.closest(".selection-tag-row").querySelectorAll(
                  '[data-action][data-tag-id]'
                )],
              }};
            }}"""
        )
        travel_chip.click()
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        stable_selection_inspector = page.evaluate(
            f"""() => {{
              const frame = window.__stableSelectionInspectorTagFrame;
              const container = document.querySelector("#selectionInspectorTags");
              const subject = container.querySelector(
                '[data-inspector-tag-group-id="{SUBJECT_GROUP_ID}"]'
              );
              const scene = container.querySelector(
                '[data-inspector-tag-group-id="{SCENE_GROUP_ID}"]'
              );
              const cat = container.querySelector(
                '[data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]'
              );
              const travel = container.querySelector(
                '[data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
              );
              return {{
                container: container === frame.container,
                subject: subject === frame.subject,
                scene: scene === frame.scene,
                cat: cat === frame.cat,
                travel: travel === frame.travel,
                catRow: cat.closest(".selection-tag-row") === frame.catRow,
                travelRow: travel.closest(".selection-tag-row") === frame.travelRow,
                catActions: frame.catActions.every((button) => button.isConnected),
                travelActions: frame.travelActions.every((button) => button.isConnected),
                focus: document.activeElement === travel,
              }};
            }}"""
        )
        assert all(stable_selection_inspector.values()), stable_selection_inspector
        assert submitted_tag_decisions[-1]["action"] == "accept"
        assert set(submitted_tag_decisions[-1]["assetIDs"]) == set(ASSET_IDS)
        travel_chip.click(button="right")
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        assert submitted_tag_decisions[-1]["action"] == "clear"
        assert not unexpected_dialogs, unexpected_dialogs

        # Mac exposes both favorite mutations directly in the main toolbar
        # whenever the current selection and available width permit it. The
        # existing batch bar remains the compact-width fallback, but the two
        # surfaces must never be visible as duplicate actions at once.
        page.locator("#appView").evaluate(
            "element => { element.dataset.toolbarDisplayMode = 'iconAndTitle'; }"
        )
        page.set_viewport_size({"width": 1280, "height": 960})
        page.wait_for_timeout(100)
        assert page.locator("#selectionFavoriteToolbarActions").is_hidden()
        assert page.locator("#batchFavoriteActions").is_visible()
        assert page.locator("#personalModelToolbarActions").is_hidden()
        assert page.locator("#batchPersonalModelActions").is_visible()
        page.locator("#personalModelButton").click()
        page.locator("#personalModelPopover:not(.hidden)").wait_for()
        assert page.locator("#preparePersonalSelectionButton").is_visible()
        assert page.locator("#findSimilarPersonalSelectionButton").is_visible()
        page.keyboard.press("Escape")
        page.locator("#personalModelPopover").wait_for(state="hidden")

        page.set_viewport_size({"width": 2200, "height": 960})
        page.wait_for_function(
            "() => getComputedStyle(document.querySelector("
            "'#selectionFavoriteToolbarActions')).display !== 'none' "
            "&& document.querySelector('#batchFavoriteActions')?.getClientRects().length === 0"
        )
        direct_favorite_group = page.locator("#selectionFavoriteToolbarActions")
        direct_favorite = page.locator("#toolbarFavoriteSelectedButton")
        direct_unfavorite = page.locator("#toolbarUnfavoriteSelectedButton")
        direct_prepare = page.locator("#toolbarPrepareSelectedFeaturesButton")
        direct_find_similar = page.locator("#toolbarFindSimilarSelectionButton")
        assert direct_favorite_group.is_visible()
        assert direct_favorite.is_visible()
        assert direct_unfavorite.is_visible()
        assert direct_favorite.inner_text().strip() == "♥\n加入红心"
        assert direct_unfavorite.inner_text().strip() == "♡\n取消红心"
        assert page.locator("#batchFavoriteActions").is_hidden()
        assert direct_prepare.is_visible()
        assert direct_find_similar.is_visible()
        assert direct_prepare.inner_text().strip() == "✦\n准备选中照片特征"
        assert direct_find_similar.inner_text().strip() == "▧\n在图库瘦身中查找"
        assert page.locator("#batchPersonalModelActions").is_hidden()
        toolbar_mode_asset_request_count = len(asset_request_urls)
        page.locator("#appView").evaluate(
            "element => { element.dataset.toolbarDisplayMode = 'iconOnly'; }"
        )
        assert direct_favorite.locator(".library-toolbar-label").is_hidden()
        assert direct_unfavorite.locator(".library-toolbar-label").is_hidden()
        assert direct_prepare.locator(".library-toolbar-label").is_hidden()
        assert direct_find_similar.locator(".library-toolbar-label").is_hidden()
        assert direct_favorite.evaluate(
            "button => Math.round(button.getBoundingClientRect().width)"
        ) == 29
        assert direct_unfavorite.evaluate(
            "button => Math.round(button.getBoundingClientRect().width)"
        ) == 29
        assert direct_prepare.evaluate(
            "button => Math.round(button.getBoundingClientRect().width)"
        ) == 29
        assert direct_find_similar.evaluate(
            "button => Math.round(button.getBoundingClientRect().width)"
        ) == 29
        page.locator("#appView").evaluate(
            "element => { element.dataset.toolbarDisplayMode = 'iconAndTitle'; }"
        )
        assert direct_favorite.locator(".library-toolbar-label").is_visible()
        assert direct_unfavorite.locator(".library-toolbar-label").is_visible()
        assert direct_prepare.locator(".library-toolbar-label").is_visible()
        assert direct_find_similar.locator(".library-toolbar-label").is_visible()
        assert len(asset_request_urls) == toolbar_mode_asset_request_count
        page.screenshot(
            path="/tmp/imageall-selection-favorite-toolbar-wide.png",
            full_page=False,
        )
        direct_snapshot = page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs],
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
              loadedIDs: state.assets.map((asset) => asset.id),
            })"""
        )
        favorite_request_count = len(submitted_favorites)
        direct_favorite.click()
        page.wait_for_function(
            "() => document.querySelectorAll("
            "'#assetGrid .asset-card-favorite[data-favorite=\"true\"]'"
            ").length === 2"
        )
        assert len(submitted_favorites) == favorite_request_count + 1
        assert submitted_favorites[-1]["isFavorite"] is True
        assert set(submitted_favorites[-1]["assetIDs"]) == set(ASSET_IDS)
        page.wait_for_function(
            "() => document.activeElement?.id === 'toolbarFavoriteSelectedButton'"
        )
        assert page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs],
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
              loadedIDs: state.assets.map((asset) => asset.id),
            })"""
        ) == direct_snapshot

        direct_unfavorite.click()
        page.wait_for_function(
            "() => document.querySelectorAll("
            "'#assetGrid .asset-card-favorite[data-favorite=\"true\"]'"
            ").length === 0"
        )
        assert len(submitted_favorites) == favorite_request_count + 2
        assert submitted_favorites[-1]["isFavorite"] is False
        page.wait_for_function(
            "() => document.activeElement?.id === 'toolbarUnfavoriteSelectedButton'"
        )
        direct_favorite.click()
        page.wait_for_function(
            "() => document.querySelectorAll("
            "'#assetGrid .asset-card-favorite[data-favorite=\"true\"]'"
            ").length === 2"
        )
        assert len(submitted_favorites) == favorite_request_count + 3
        assert submitted_favorites[-1]["isFavorite"] is True

        preparation_request_count = len(submitted_preparations)
        direct_prepare.click()
        page.locator("#embeddingPreparationStatus:not(.hidden)").wait_for()
        assert len(submitted_preparations) == preparation_request_count + 1
        assert submitted_preparations[-1]["mediaKind"] == "image"
        assert set(submitted_preparations[-1]["assetIDs"]) == set(ASSET_IDS)
        page.wait_for_function(
            "() => document.activeElement?.id === 'cancelEmbeddingPreparationButton'"
        )
        assert direct_prepare.get_attribute("aria-busy") == "true"
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('新准备 2')",
            timeout=5_000,
        )
        page.wait_for_function(
            "() => document.activeElement?.id === 'toolbarPrepareSelectedFeaturesButton'"
        )
        assert direct_prepare.get_attribute("aria-busy") == "false"
        assert page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs],
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
              loadedIDs: state.assets.map((asset) => asset.id),
            })"""
        ) == direct_snapshot

        slimming_request_count = len(submitted_slimming)
        direct_find_similar.click()
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        assert len(submitted_slimming) == slimming_request_count + 1
        assert submitted_slimming[-1]["mode"] == "seeds"
        assert set(submitted_slimming[-1]["seedAssetIDs"]) == set(ASSET_IDS)
        page.locator("#closeSlimmingButton").click()
        page.locator("#slimmingWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'toolbarFindSimilarSelectionButton'"
        )

        direct_prepare.focus()
        page.set_viewport_size({"width": 1280, "height": 960})
        page.wait_for_function(
            "() => document.activeElement?.id === 'prepareSelectedFeaturesButton'"
        )
        assert page.locator("#batchPersonalModelActions").is_visible()
        page.set_viewport_size({"width": 2200, "height": 960})
        page.wait_for_function(
            "() => document.querySelector('#toolbarPrepareSelectedFeaturesButton')"
            "?.getClientRects().length > 0 "
            "&& state.selectionFavoriteToolbarWasVisible"
        )

        # Shrinking while a direct action owns focus must move focus to the
        # equivalent compact action instead of leaving it on a hidden node.
        direct_favorite.focus()
        page.set_viewport_size({"width": 1280, "height": 960})
        page.wait_for_function(
            "() => document.activeElement?.id === 'favoriteSelectedButton'"
        )
        assert direct_favorite_group.is_hidden()
        assert page.locator("#batchFavoriteActions").is_visible()
        assert page.locator("#batchPersonalModelActions").is_visible()
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        assert direct_favorite_group.is_hidden()
        assert page.locator("#batchFavoriteActions").is_visible()
        assert page.locator("#batchPersonalModelActions").is_visible()
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        page.screenshot(
            path="/tmp/imageall-selection-favorite-toolbar-390.png",
            full_page=False,
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_timeout(100)

        page.locator("#prepareSelectedFeaturesButton").click()
        page.locator("#embeddingPreparationStatus:not(.hidden)").wait_for()
        assert submitted_preparations[-1]["mediaKind"] == "image"
        assert set(submitted_preparations[-1]["assetIDs"]) == set(ASSET_IDS)
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('新准备 2')",
            timeout=5_000,
        )
        assert page.locator("#embeddingPreparationStatus").is_hidden()

        page.locator("#generateSelectedSuggestionsButton").click()
        page.locator("#reviewWorkspace:not(.hidden)").wait_for()
        assert submitted_sample_suggestions[-1]["assetIDs"] == ASSET_IDS
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('写入 3 条建议')",
            timeout=5_000,
        )
        page.locator("#generateLibrarySuggestionsButton").click()
        assert submitted_sample_suggestions[-1]["assetIDs"] == []

        page.locator("#closeReviewButton").click()
        page.locator("#reviewWorkspace").wait_for(state="hidden")
        page.locator("#findSimilarSelectionButton").click()
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        slimming_desktop_presentation = page.evaluate(
            """() => {
              const workspace = document.querySelector('#slimmingWorkspace');
              const libraryPane = document.querySelector('#libraryPane');
              const workspaceRect = workspace.getBoundingClientRect();
              const libraryRect = libraryPane.getBoundingClientRect();
              return {
                appInert: document.querySelector('#appView').inert,
                role: workspace.getAttribute('role'),
                ariaModal: workspace.getAttribute('aria-modal'),
                integrated: workspace.classList.contains('integrated'),
                libraryTitle: document.querySelector('#libraryTitle').textContent.trim(),
                navigationCurrent: document.querySelector('#slimmingNavigationButton')
                  .getAttribute('aria-current'),
                sourceSidebarVisible: document.querySelector('#sourceSidebar').offsetParent !== null,
                inspectorVisible: document.querySelector('#inspector').offsetParent !== null,
                searchInert: document.querySelector('#searchForm').closest('[inert]') !== null,
                contained: workspaceRect.left >= libraryRect.left - 1
                  && workspaceRect.right <= libraryRect.right + 1
                  && workspaceRect.top >= libraryRect.top - 1
                  && workspaceRect.bottom <= libraryRect.bottom + 1,
              };
            }"""
        )
        assert slimming_desktop_presentation == {
            "appInert": False,
            "role": "region",
            "ariaModal": None,
            "integrated": True,
            "libraryTitle": "图库瘦身",
            "navigationCurrent": "page",
            "sourceSidebarVisible": True,
            "inspectorVisible": True,
            "searchInert": True,
            "contained": True,
        }, slimming_desktop_presentation
        slimming_workspace_inspector = page.locator(
            "#inspectorSlimmingWorkspace:not(.hidden)"
        )
        slimming_workspace_inspector.wait_for()
        assert "分析记录" in slimming_workspace_inspector.inner_text()
        assert "2 条" in slimming_workspace_inspector.inner_text()
        assert "从所选项目查找" in slimming_workspace_inspector.inner_text()
        assert "Apple Photos" in slimming_workspace_inspector.inner_text()
        assert "已完成" in slimming_workspace_inspector.inner_text()
        assert "3 张" in slimming_workspace_inspector.inner_text()
        assert "2 张" in slimming_workspace_inspector.inner_text()
        assert page.locator("#slimmingInspector").is_hidden()
        page.screenshot(path="/tmp/imageall-slimming-integrated.png", full_page=False)
        slimming_refresh_before = page.evaluate(
            """() => {
              const memberMain = document.querySelector(
                '#slimmingMemberGrid .slimming-member-main'
              );
              const memberCard = memberMain?.closest('[data-slimming-member-id]');
              const originalFetch = window.fetch.bind(window);
              memberMain?.focus({ preventScroll: true });
              window.__imageAllSlimmingRefreshJob = document.querySelector(
                `[data-slimming-job-id="${CSS.escape(state.slimming.selectedJobID)}"]`
              );
              window.__imageAllSlimmingRefreshCluster = document.querySelector(
                `[data-slimming-cluster-row-id="${CSS.escape(state.slimming.selectedClusterID)}"]`
              );
              window.__imageAllSlimmingRefreshMember = memberCard;
              window.__imageAllSlimmingRefreshImage = memberCard?.querySelector('img');
              window.__imageAllSlimmingRefreshRelease = null;
              window.fetch = (...args) => {
                const requestURL = String(args[0]?.url || args[0]);
                if (requestURL.includes('/v1/library-slimming/workspace?')) {
                  return new Promise((resolve, reject) => {
                    window.__imageAllSlimmingRefreshRelease = () => {
                      window.fetch = originalFetch;
                      originalFetch(...args).then(resolve, reject);
                    };
                  });
                }
                return originalFetch(...args);
              };
              return {
                jobID: state.slimming.selectedJobID,
                clusterID: state.slimming.selectedClusterID,
                memberID: memberCard?.dataset.slimmingMemberId || null,
              };
            }"""
        )
        page.evaluate("() => { void loadSlimmingWorkspace({ quiet: true }); }")
        page.wait_for_function(
            "() => state.slimming.loading "
            "&& typeof window.__imageAllSlimmingRefreshRelease === 'function'"
        )
        slimming_refresh_inflight = page.evaluate(
            """expected => {
              const member = document.querySelector(
                `[data-slimming-member-id="${CSS.escape(expected.memberID)}"]`
              );
              return {
                jobStable: document.querySelector(
                  `[data-slimming-job-id="${CSS.escape(expected.jobID)}"]`
                ) === window.__imageAllSlimmingRefreshJob,
                clusterStable: document.querySelector(
                  `[data-slimming-cluster-row-id="${CSS.escape(expected.clusterID)}"]`
                ) === window.__imageAllSlimmingRefreshCluster,
                memberStable: member === window.__imageAllSlimmingRefreshMember,
                imageStable: member?.querySelector('img')
                  === window.__imageAllSlimmingRefreshImage,
                focusedMemberID: document.activeElement?.closest(
                  '[data-slimming-member-id]'
                )?.dataset.slimmingMemberId || null,
              };
            }""",
            slimming_refresh_before,
        )
        assert slimming_refresh_inflight == {
            "jobStable": True,
            "clusterStable": True,
            "memberStable": True,
            "imageStable": True,
            "focusedMemberID": slimming_refresh_before["memberID"],
        }, slimming_refresh_inflight
        page.evaluate("() => window.__imageAllSlimmingRefreshRelease()")
        page.wait_for_function("() => !state.slimming.loading")
        slimming_refresh_after = page.evaluate(
            """expected => {
              const member = document.querySelector(
                `[data-slimming-member-id="${CSS.escape(expected.memberID)}"]`
              );
              return {
                jobStable: document.querySelector(
                  `[data-slimming-job-id="${CSS.escape(expected.jobID)}"]`
                ) === window.__imageAllSlimmingRefreshJob,
                clusterStable: document.querySelector(
                  `[data-slimming-cluster-row-id="${CSS.escape(expected.clusterID)}"]`
                ) === window.__imageAllSlimmingRefreshCluster,
                memberStable: member === window.__imageAllSlimmingRefreshMember,
                imageStable: member?.querySelector('img')
                  === window.__imageAllSlimmingRefreshImage,
                focusedMemberID: document.activeElement?.closest(
                  '[data-slimming-member-id]'
                )?.dataset.slimmingMemberId || null,
              };
            }""",
            slimming_refresh_before,
        )
        assert slimming_refresh_after == slimming_refresh_inflight, slimming_refresh_after
        page.evaluate(
            """jobID => {
              window.__imageAllSlimmingChangedJob = document.querySelector(
                `[data-slimming-job-id="${CSS.escape(jobID)}"]`
              );
            }""",
            SLIMMING_SECOND_JOB_ID,
        )
        slimming_job_states[SLIMMING_SECOND_JOB_ID] = "running"
        page.evaluate("loadSlimmingWorkspace({ quiet: true })")
        page.wait_for_function(
            "jobID => document.querySelector(`[data-slimming-job-id=\"${jobID}\"]`)"
            "?.innerText.includes('进行中')",
            arg=SLIMMING_SECOND_JOB_ID,
        )
        slimming_changed_refresh_after = page.evaluate(
            """expected => {
              const member = document.querySelector(
                `[data-slimming-member-id="${CSS.escape(expected.memberID)}"]`
              );
              return {
                changedJobStable: document.querySelector(
                  `[data-slimming-job-id="${CSS.escape(expected.changedJobID)}"]`
                ) === window.__imageAllSlimmingChangedJob,
                selectedJobStable: document.querySelector(
                  `[data-slimming-job-id="${CSS.escape(expected.jobID)}"]`
                ) === window.__imageAllSlimmingRefreshJob,
                clusterStable: document.querySelector(
                  `[data-slimming-cluster-row-id="${CSS.escape(expected.clusterID)}"]`
                ) === window.__imageAllSlimmingRefreshCluster,
                memberStable: member === window.__imageAllSlimmingRefreshMember,
                imageStable: member?.querySelector('img')
                  === window.__imageAllSlimmingRefreshImage,
                focusedMemberID: document.activeElement?.closest(
                  '[data-slimming-member-id]'
                )?.dataset.slimmingMemberId || null,
              };
            }""",
            {**slimming_refresh_before, "changedJobID": SLIMMING_SECOND_JOB_ID},
        )
        assert slimming_changed_refresh_after == {
            "changedJobStable": True,
            "selectedJobStable": True,
            "clusterStable": True,
            "memberStable": True,
            "imageStable": True,
            "focusedMemberID": slimming_refresh_before["memberID"],
        }, slimming_changed_refresh_after
        slimming_job_states[SLIMMING_SECOND_JOB_ID] = "completed"
        page.evaluate("loadSlimmingWorkspace({ quiet: true })")
        page.wait_for_function(
            "jobID => document.querySelector(`[data-slimming-job-id=\"${jobID}\"]`)"
            "?.innerText.includes('已完成')",
            arg=SLIMMING_SECOND_JOB_ID,
        )
        page.evaluate(
            """memberID => {
              const card = document.querySelector(
                `[data-slimming-member-id="${CSS.escape(memberID)}"]`
              );
              window.__imageAllSlimmingChangedMember = card;
              window.__imageAllSlimmingChangedMemberImage = card?.querySelector('img');
            }""",
            SLIMMING_ASSET_IDS[2],
        )
        favorite_states[SLIMMING_ASSET_IDS[2]] = True
        page.evaluate("loadSlimmingWorkspace({ quiet: true })")
        page.wait_for_function(
            "memberID => document.querySelector("
            "`[data-slimming-member-id=\"${memberID}\"] "
            "[data-slimming-member-favorite]`)?.dataset.favorite === 'true'",
            arg=SLIMMING_ASSET_IDS[2],
        )
        slimming_changed_member_after = page.evaluate(
            """expected => {
              const changedMember = document.querySelector(
                `[data-slimming-member-id="${CSS.escape(expected.changedMemberID)}"]`
              );
              return {
                memberStable: changedMember === window.__imageAllSlimmingChangedMember,
                imageStable: changedMember?.querySelector('img')
                  === window.__imageAllSlimmingChangedMemberImage,
                focusedMemberID: document.activeElement?.closest(
                  '[data-slimming-member-id]'
                )?.dataset.slimmingMemberId || null,
              };
            }""",
            {
                **slimming_refresh_before,
                "changedMemberID": SLIMMING_ASSET_IDS[2],
            },
        )
        assert slimming_changed_member_after == {
            "memberStable": True,
            "imageStable": True,
            "focusedMemberID": slimming_refresh_before["memberID"],
        }, slimming_changed_member_after
        favorite_states[SLIMMING_ASSET_IDS[2]] = False
        page.evaluate("loadSlimmingWorkspace({ quiet: true })")
        page.wait_for_function(
            "memberID => document.querySelector("
            "`[data-slimming-member-id=\"${memberID}\"] "
            "[data-slimming-member-favorite]`)?.dataset.favorite === 'false'",
            arg=SLIMMING_ASSET_IDS[2],
        )
        page.evaluate(
            """() => {
              const originalFetch = window.fetch.bind(window);
              window.fetch = (...args) => {
                const requestURL = String(args[0]?.url || args[0]);
                if (requestURL.includes('/v1/library-slimming/workspace?')) {
                  window.fetch = originalFetch;
                  return Promise.reject(new Error('图库瘦身结果暂时不可用'));
                }
                return originalFetch(...args);
              };
            }"""
        )
        page.evaluate("loadSlimmingWorkspace()")
        assert "图库瘦身结果暂时不可用" in page.locator("#toastMessage").inner_text()
        slimming_failed_refresh_after = page.evaluate(
            """expected => {
              const member = document.querySelector(
                `[data-slimming-member-id="${CSS.escape(expected.memberID)}"]`
              );
              return {
                jobStable: document.querySelector(
                  `[data-slimming-job-id="${CSS.escape(expected.jobID)}"]`
                ) === window.__imageAllSlimmingRefreshJob,
                clusterStable: document.querySelector(
                  `[data-slimming-cluster-row-id="${CSS.escape(expected.clusterID)}"]`
                ) === window.__imageAllSlimmingRefreshCluster,
                memberStable: member === window.__imageAllSlimmingRefreshMember,
                imageStable: member?.querySelector('img')
                  === window.__imageAllSlimmingRefreshImage,
                focusedMemberID: document.activeElement?.closest(
                  '[data-slimming-member-id]'
                )?.dataset.slimmingMemberId || null,
              };
            }""",
            slimming_refresh_before,
        )
        assert slimming_failed_refresh_after == slimming_refresh_inflight, (
            slimming_failed_refresh_after
        )
        page.screenshot(
            path="/tmp/imageall-slimming-refresh-continuity.png",
            full_page=True,
        )
        assert page.locator("#closeSlimmingButton").get_attribute("aria-label") == "返回图库"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "slimming"
        assert submitted_slimming[-1]["mode"] == "seeds"
        assert submitted_slimming[-1]["sourceIDs"] is None
        assert set(submitted_slimming[-1]["seedAssetIDs"]) == set(ASSET_IDS)
        page.locator("#closeSlimmingButton").focus()
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        assert page.locator("#commandContextLabel").inner_text() == "当前：图库瘦身"
        assert page.locator('[data-command-id="selectAll"]').count() == 1
        assert page.locator('[data-command-id="media:video"]').count() == 1
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.id === 'closeSlimmingButton'"
        )
        slimming_context_before_command = page.evaluate(
            "() => ({ jobID: state.slimming.selectedJobID, "
            "clusterID: state.slimming.selectedClusterID, mediaKind: state.slimming.mediaKind })"
        )
        page.keyboard.press("Meta+K")
        page.locator('[data-command-id="returnWorkspace"]').click()
        page.locator("#slimmingWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        page.wait_for_function("() => !state.slimming.loading")
        assert page.evaluate(
            "() => ({ jobID: state.slimming.selectedJobID, "
            "clusterID: state.slimming.selectedClusterID, mediaKind: state.slimming.mediaKind })"
        ) == slimming_context_before_command

        page.wait_for_function(
            "() => document.querySelector('#slimmingCatalogAnalyzeButton')?.disabled === false "
            "&& document.querySelector('#slimmingCatalogSourceButton')?.textContent.includes('全部来源（2）')"
        )
        assert "分析全部来源" in page.locator(
            "#slimmingCatalogAnalyzeButton"
        ).inner_text()
        page.locator("#slimmingCatalogSourceButton").click()
        source_popover = page.locator("#slimmingCatalogSourcePopover:not(.hidden)")
        source_popover.wait_for()
        catalog_sources = page.locator(
            "#slimmingCatalogSourceOptions [data-slimming-catalog-source-id]"
        )
        assert catalog_sources.count() == 2
        assert "全部 2 个" in page.locator(
            "#slimmingCatalogSourceSummary"
        ).inner_text()
        catalog_sources.nth(1).uncheck()
        page.wait_for_function(
            "() => document.querySelector('#slimmingCatalogSourceButton')"
            ".textContent.includes('Apple Photos') "
            "&& document.querySelector('#slimmingCatalogAnalyzeButton')"
            ".textContent.includes('分析所选来源')"
        )
        catalog_sources.nth(0).focus()
        source_popover.evaluate(
            "element => { element.style.maxHeight = '76px'; "
            "element.style.overflowY = 'auto'; element.scrollTop = 28; }"
        )
        slimming_source_scroll = source_popover.evaluate("element => element.scrollTop")
        slimming_source_reads = slimming_setup_reads[0]
        slimming_source_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert '"navigationLevel":"actionMenu"' in slimming_source_history_payload
        assert '"actionMenuKind":"slimmingSources"' in slimming_source_history_payload
        assert SOURCE_ID not in slimming_source_history_payload
        assert SECOND_SOURCE_ID not in slimming_source_history_payload
        assert "actionMenuFocusedSelector" not in slimming_source_history_payload
        assert "actionMenuScrollTop" not in slimming_source_history_payload
        page.evaluate("() => history.back()")
        source_popover.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingCatalogSourceButton'"
        )
        page.evaluate("() => history.forward()")
        source_popover.wait_for()
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.slimmingCatalogSourceId === sourceID",
            arg=SOURCE_ID,
        )
        assert source_popover.evaluate("element => element.scrollTop") == slimming_source_scroll
        assert slimming_setup_reads[0] == slimming_source_reads
        assert catalog_sources.nth(0).is_checked()
        assert not catalog_sources.nth(1).is_checked()
        page.keyboard.press("Escape")
        source_popover.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingCatalogSourceButton'"
        )
        with page.expect_request(
            lambda request: request.url.endswith("/v1/library-slimming/launch")
            and request.method == "POST"
        ):
            page.locator("#slimmingCatalogAnalyzeButton").click()
        page.wait_for_function(
            "() => document.querySelector('#slimmingCatalogAnalyzeButton')?.disabled === false"
        )
        assert submitted_slimming[-1]["mode"] == "catalog"
        assert submitted_slimming[-1]["sourceIDs"] == [SOURCE_ID]
        assert submitted_slimming[-1]["seedAssetIDs"] == []
        assert submitted_slimming[-1]["filter"] is None
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingCatalogAnalyzeButton'"
        )

        page.locator("#slimmingAnalysisOptionsButton").click()
        page.locator("#slimmingAnalysisOptionsPopover:not(.hidden)").wait_for()
        page.locator("#slimmingAnalysisOptionsContent:not(.hidden)").wait_for()
        assert page.locator("#slimmingCurrentFilterAnalysisButton").is_enabled()
        assert "按种子查找（2）" in page.locator(
            "#slimmingSeedAnalysisButton"
        ).inner_text()
        assert page.locator("#openSlimmingSetupButton").is_visible()
        page.locator("#openSlimmingSetupButton").focus()
        options_popover = page.locator("#slimmingAnalysisOptionsPopover")
        options_popover.evaluate(
            "element => { element.style.maxHeight = '132px'; "
            "element.style.overflowY = 'auto'; element.scrollTop = 52; }"
        )
        slimming_options_scroll = options_popover.evaluate("element => element.scrollTop")
        slimming_options_reads = slimming_setup_reads[0]
        slimming_options_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert '"navigationLevel":"actionMenu"' in slimming_options_history_payload
        assert '"actionMenuKind":"slimmingOptions"' in slimming_options_history_payload
        assert "openSlimmingSetupButton" not in slimming_options_history_payload
        assert "actionMenuFocusedSelector" not in slimming_options_history_payload
        assert "actionMenuScrollTop" not in slimming_options_history_payload
        page.evaluate("() => history.back()")
        options_popover.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingAnalysisOptionsButton'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#slimmingAnalysisOptionsContent:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'openSlimmingSetupButton'"
        )
        assert options_popover.evaluate("element => element.scrollTop") == slimming_options_scroll
        assert slimming_setup_reads[0] == slimming_options_reads
        with page.expect_request(
            lambda request: request.url.endswith("/v1/library-slimming/launch")
            and request.method == "POST"
        ):
            page.locator("#slimmingCurrentFilterAnalysisButton").click()
        page.wait_for_function(
            "() => !state.slimming.quickLaunchMode "
            "&& document.querySelector('#slimmingAnalysisOptionsPopover').classList.contains('hidden')"
        )
        assert submitted_slimming[-1]["mode"] == "currentFilter"
        assert submitted_slimming[-1]["sourceIDs"] is None
        assert submitted_slimming[-1]["seedAssetIDs"] == []
        assert submitted_slimming[-1]["filter"]["mediaKinds"] == ["image"]

        page.locator("#slimmingAnalysisOptionsButton").click()
        page.locator("#slimmingAnalysisOptionsContent:not(.hidden)").wait_for()
        with page.expect_request(
            lambda request: request.url.endswith("/v1/library-slimming/launch")
            and request.method == "POST"
        ):
            page.locator("#slimmingSeedAnalysisButton").click()
        page.wait_for_function("() => !state.slimming.quickLaunchMode")
        assert submitted_slimming[-1]["mode"] == "seeds"
        assert set(submitted_slimming[-1]["seedAssetIDs"]) == set(ASSET_IDS)
        assert submitted_slimming[-1]["sourceIDs"] is None

        page.locator("#slimmingAnalysisOptionsButton").click()
        page.locator("#slimmingAnalysisOptionsPopover:not(.hidden)").wait_for()
        page.locator("#slimmingAnalysisOptionsContent:not(.hidden)").wait_for()
        page.locator("#openSlimmingSetupButton").click()
        page.locator("#slimmingSetupDialog[open]").wait_for()
        page.locator("#slimmingSetupConfiguration:not(.hidden)").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "slimmingSetup"
        slimming_setup_reads_after_open = slimming_setup_reads[0]
        catalog_slimming_mode = page.locator('[data-slimming-mode="catalog"]')
        page.evaluate(
            """() => {
              const modes = document.querySelector('#slimmingModeOptions');
              const catalog = modes.querySelector('[data-slimming-mode="catalog"]');
              const currentFilter = modes.querySelector(
                '[data-slimming-mode="currentFilter"]'
              );
              const seeds = modes.querySelector('[data-slimming-mode="seeds"]');
              catalog.focus({ preventScroll: true });
              window.__slimmingSetupModeContinuityFrame = {
                catalog,
                currentFilter,
                seeds,
              };
            }"""
        )
        catalog_slimming_mode_bounds = catalog_slimming_mode.bounding_box()
        assert catalog_slimming_mode_bounds is not None
        page.mouse.move(
            catalog_slimming_mode_bounds["x"]
            + catalog_slimming_mode_bounds["width"] / 2,
            catalog_slimming_mode_bounds["y"]
            + catalog_slimming_mode_bounds["height"] / 2,
        )
        page.mouse.click(
            catalog_slimming_mode_bounds["x"]
            + catalog_slimming_mode_bounds["width"] / 2,
            catalog_slimming_mode_bounds["y"]
            + catalog_slimming_mode_bounds["height"] / 2,
        )
        slimming_setup_mode_continuity = page.evaluate(
            """() => {
              const frame = window.__slimmingSetupModeContinuityFrame;
              const modes = document.querySelector('#slimmingModeOptions');
              const catalog = modes.querySelector('[data-slimming-mode="catalog"]');
              const currentFilter = modes.querySelector(
                '[data-slimming-mode="currentFilter"]'
              );
              const seeds = modes.querySelector('[data-slimming-mode="seeds"]');
              return {
                catalog: catalog === frame.catalog,
                currentFilter: currentFilter === frame.currentFilter,
                seeds: seeds === frame.seeds,
                focused: document.activeElement === catalog,
                hovered: catalog?.matches(':hover') || false,
                selected: catalog?.getAttribute('aria-checked') === 'true',
              };
            }"""
        )
        assert slimming_setup_mode_continuity == {
            "catalog": True,
            "currentFilter": True,
            "seeds": True,
            "focused": True,
            "hovered": True,
            "selected": True,
        }, slimming_setup_mode_continuity
        page.locator("#slimmingRecallMode").select_option("allCandidates")
        assert page.locator("#slimmingRecallTopK").is_disabled()
        assert page.locator(
            f'[data-slimming-source-id="{SOURCE_ID}"]'
        ).is_checked()
        assert not page.locator(
            f'[data-slimming-source-id="{SECOND_SOURCE_ID}"]'
        ).is_checked()
        second_slimming_setup_source = page.locator(
            f'[data-slimming-source-id="{SECOND_SOURCE_ID}"]'
        )
        slimming_setup_source_frame = page.evaluate(
            """sourceIDs => {
              const options = document.querySelector('#slimmingSourceOptions');
              options.style.maxHeight = '46px';
              options.scrollTop = options.scrollHeight;
              const firstInput = options.querySelector(
                `[data-slimming-source-id="${sourceIDs[0]}"]`
              );
              const secondInput = options.querySelector(
                `[data-slimming-source-id="${sourceIDs[1]}"]`
              );
              secondInput.focus({ preventScroll: true });
              window.__slimmingSetupSourceContinuityFrame = {
                firstRow: firstInput.closest('label'),
                firstInput,
                secondRow: secondInput.closest('label'),
                secondInput,
                secondName: secondInput.nextElementSibling,
              };
              return { scrollTop: options.scrollTop };
            }""",
            [SOURCE_ID, SECOND_SOURCE_ID],
        )
        assert slimming_setup_source_frame["scrollTop"] > 0, slimming_setup_source_frame
        second_slimming_setup_source_bounds = second_slimming_setup_source.bounding_box()
        assert second_slimming_setup_source_bounds is not None
        page.mouse.move(
            second_slimming_setup_source_bounds["x"]
            + second_slimming_setup_source_bounds["width"] / 2,
            second_slimming_setup_source_bounds["y"]
            + second_slimming_setup_source_bounds["height"] / 2,
        )
        page.mouse.click(
            second_slimming_setup_source_bounds["x"]
            + second_slimming_setup_source_bounds["width"] / 2,
            second_slimming_setup_source_bounds["y"]
            + second_slimming_setup_source_bounds["height"] / 2,
        )
        slimming_setup_source_continuity = page.evaluate(
            """({ sourceIDs, expectedScrollTop }) => {
              const frame = window.__slimmingSetupSourceContinuityFrame;
              const options = document.querySelector('#slimmingSourceOptions');
              const firstInput = options.querySelector(
                `[data-slimming-source-id="${sourceIDs[0]}"]`
              );
              const secondInput = options.querySelector(
                `[data-slimming-source-id="${sourceIDs[1]}"]`
              );
              return {
                firstRow: firstInput?.closest('label') === frame.firstRow,
                firstInput: firstInput === frame.firstInput,
                secondRow: secondInput?.closest('label') === frame.secondRow,
                secondInput: secondInput === frame.secondInput,
                secondName: secondInput?.nextElementSibling === frame.secondName,
                focused: document.activeElement === secondInput,
                hovered: secondInput?.matches(':hover') || false,
                scroll: options.scrollTop === expectedScrollTop,
                checked: secondInput?.checked || false,
              };
            }""",
            {
                "sourceIDs": [SOURCE_ID, SECOND_SOURCE_ID],
                "expectedScrollTop": slimming_setup_source_frame["scrollTop"],
            },
        )
        assert slimming_setup_source_continuity == {
            "firstRow": True,
            "firstInput": True,
            "secondRow": True,
            "secondInput": True,
            "secondName": True,
            "focused": True,
            "hovered": True,
            "scroll": True,
            "checked": True,
        }, slimming_setup_source_continuity
        page.evaluate(
            "document.querySelector('#slimmingSourceOptions').style.removeProperty('max-height')"
        )
        second_slimming_setup_source.uncheck()
        slimming_setup_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "Apple Photos" not in slimming_setup_history_payload
        assert "旅行归档" not in slimming_setup_history_payload
        assert "allCandidates" not in slimming_setup_history_payload
        slimming_setup_history_frame = page.evaluate(
            """sourceID => {
              const options = document.querySelector('#slimmingSourceOptions');
              options.style.maxHeight = '46px';
              options.scrollTop = options.scrollHeight;
              const input = options.querySelector(
                `[data-slimming-source-id="${sourceID}"]`
              );
              input.focus({ preventScroll: true });
              return { scrollTop: options.scrollTop };
            }""",
            SECOND_SOURCE_ID,
        )
        assert slimming_setup_history_frame["scrollTop"] > 0, slimming_setup_history_frame
        page.evaluate("() => history.back()")
        page.locator("#slimmingSetupDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingAnalysisOptionsButton'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#slimmingSetupDialog[open]").wait_for()
        assert slimming_setup_reads[0] == slimming_setup_reads_after_open
        assert page.locator(
            '[data-slimming-mode="catalog"]'
        ).get_attribute("aria-checked") == "true"
        assert page.locator("#slimmingRecallMode").input_value() == "allCandidates"
        assert page.locator(
            f'[data-slimming-source-id="{SOURCE_ID}"]'
        ).is_checked()
        assert not page.locator(
            f'[data-slimming-source-id="{SECOND_SOURCE_ID}"]'
        ).is_checked()
        slimming_setup_history_continuity = page.evaluate(
            """({ sourceIDs, expectedScrollTop }) => {
              const sourceFrame = window.__slimmingSetupSourceContinuityFrame;
              const modeFrame = window.__slimmingSetupModeContinuityFrame;
              const options = document.querySelector('#slimmingSourceOptions');
              const firstInput = options.querySelector(
                `[data-slimming-source-id="${sourceIDs[0]}"]`
              );
              const secondInput = options.querySelector(
                `[data-slimming-source-id="${sourceIDs[1]}"]`
              );
              const modes = document.querySelector('#slimmingModeOptions');
              return {
                catalogMode: modes.querySelector('[data-slimming-mode="catalog"]')
                  === modeFrame.catalog,
                currentFilterMode: modes.querySelector(
                  '[data-slimming-mode="currentFilter"]'
                ) === modeFrame.currentFilter,
                seedsMode: modes.querySelector('[data-slimming-mode="seeds"]')
                  === modeFrame.seeds,
                firstRow: firstInput?.closest('label') === sourceFrame.firstRow,
                firstInput: firstInput === sourceFrame.firstInput,
                secondRow: secondInput?.closest('label') === sourceFrame.secondRow,
                secondInput: secondInput === sourceFrame.secondInput,
                secondName: secondInput?.nextElementSibling === sourceFrame.secondName,
                focused: document.activeElement === secondInput,
                scroll: options.scrollTop === expectedScrollTop,
                checked: secondInput?.checked || false,
              };
            }""",
            {
                "sourceIDs": [SOURCE_ID, SECOND_SOURCE_ID],
                "expectedScrollTop": slimming_setup_history_frame["scrollTop"],
            },
        )
        assert slimming_setup_history_continuity == {
            "catalogMode": True,
            "currentFilterMode": True,
            "seedsMode": True,
            "firstRow": True,
            "firstInput": True,
            "secondRow": True,
            "secondInput": True,
            "secondName": True,
            "focused": True,
            "scroll": True,
            "checked": False,
        }, slimming_setup_history_continuity
        page.evaluate(
            "document.querySelector('#slimmingSourceOptions').style.removeProperty('max-height')"
        )
        assert page.locator("#launchSlimmingButton").is_enabled(), page.evaluate(
            "() => ({ online: state.online, setup: { "
            "loading: state.slimming.setup.loading, saving: state.slimming.setup.saving, "
            "launching: state.slimming.setup.launching, mode: state.slimming.setup.mode, "
            "selectedSourceIDs: [...state.slimming.setup.selectedSourceIDs], "
            "thresholds: state.slimming.setup.thresholds } })"
        )
        page.screenshot(
            path="/tmp/imageall-slimming-setup-continuity-wide.png",
            full_page=True,
        )
        slimming_launch_count_before_setup = len(submitted_slimming)
        slimming_generation_before_setup_launch = page.evaluate(
            "() => state.slimming.requestGeneration"
        )
        page.locator("#launchSlimmingButton").click()
        page.locator("#slimmingSetupDialog").wait_for(state="hidden")
        assert len(submitted_slimming) == slimming_launch_count_before_setup + 1, {
            "setup": page.evaluate(
                "() => ({ error: state.slimming.setup.error, "
                "loading: state.slimming.setup.loading, saving: state.slimming.setup.saving, "
                "launching: state.slimming.setup.launching, "
                "operationID: state.slimming.setup.launchOperationID })"
            ),
            "pageErrors": page_errors,
            "thresholdWrites": submitted_slimming_thresholds,
        }
        page.wait_for_function(
            "generation => state.slimming.requestGeneration > generation "
            "&& !state.slimming.loading && !state.slimming.appending",
            arg=slimming_generation_before_setup_launch,
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) != "slimmingSetup"
        assert submitted_slimming[-1]["mode"] == "catalog"
        assert submitted_slimming[-1]["sourceIDs"] == [SOURCE_ID]

        page.locator("#slimmingAnalysisOptionsButton").click()
        page.locator("#slimmingAnalysisOptionsPopover:not(.hidden)").wait_for()
        page.locator("#slimmingAnalysisOptionsContent:not(.hidden)").wait_for()
        slimming_context_before_thresholds = page.evaluate(
            "() => ({ jobID: state.slimming.selectedJobID, "
            "clusterID: state.slimming.selectedClusterID, "
            "selectedMemberIDs: [...state.slimming.selectedMemberIDs], "
            "navigatorScroll: document.querySelector('#slimmingNavigatorPane').scrollTop, "
            "memberScroll: document.querySelector('.slimming-member-pane').scrollTop })"
        )
        page.locator("#openSlimmingThresholdEditorButton").click()
        page.locator("#slimmingThresholdDialog[open]").wait_for()
        page.locator("#slimmingThresholdDialogContent:not(.hidden)").wait_for()
        assert page.locator("#slimmingAnalysisOptionsPopover").is_hidden()
        assert page.locator("#slimmingThresholdRecallTopK").input_value() == "32"
        assert page.locator("#slimmingThresholdL2Distance").input_value() == "0.4"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "slimmingThreshold"
        slimming_threshold_reads_after_open = slimming_setup_reads[0]
        page.locator("#slimmingThresholdRecallMode").select_option("allCandidates")
        page.locator("#slimmingThresholdL2Mode").select_option("unlimited")
        assert page.locator("#slimmingThresholdRecallTopK").is_disabled()
        assert page.locator("#slimmingThresholdDialogExtremeWarning").is_visible()
        slimming_threshold_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "allCandidates" not in slimming_threshold_history_payload
        assert "unlimited" not in slimming_threshold_history_payload
        page.evaluate("() => history.back()")
        page.locator("#slimmingThresholdDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingAnalysisOptionsButton'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#slimmingThresholdDialog[open]").wait_for()
        assert slimming_setup_reads[0] == slimming_threshold_reads_after_open
        assert page.locator("#slimmingThresholdRecallMode").input_value() == "allCandidates"
        assert page.locator("#slimmingThresholdL2Mode").input_value() == "unlimited"
        assert page.locator("#applySlimmingThresholdDialogButton").is_enabled(), page.evaluate(
            "() => ({ online: state.online, editor: state.slimming.thresholdEditor })"
        )
        with page.expect_request(
            lambda request: request.url.endswith("/v1/library-slimming/thresholds")
            and request.method == "PUT"
        ):
            page.locator("#applySlimmingThresholdDialogButton").click()
        page.wait_for_function("() => !state.slimming.thresholdEditor.saving")
        assert not page.locator("#slimmingThresholdDialogError").inner_text()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('阈值已更新')"
        )
        assert submitted_slimming_thresholds[-1]["thresholds"][
            "featurePrintRecallMode"
        ] == "allCandidates"
        assert page.locator("#slimmingThresholdDialog").get_attribute("open") == ""
        page.locator("#resetSlimmingThresholdDialogButton").click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('恢复默认阈值')"
        )
        assert submitted_slimming_thresholds[-1]["thresholds"] == factory_slimming_thresholds
        page.keyboard.press("Escape")
        page.locator("#slimmingThresholdDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingAnalysisOptionsButton'"
        )
        assert page.evaluate(
            "() => ({ jobID: state.slimming.selectedJobID, "
            "clusterID: state.slimming.selectedClusterID, "
            "selectedMemberIDs: [...state.slimming.selectedMemberIDs], "
            "navigatorScroll: document.querySelector('#slimmingNavigatorPane').scrollTop, "
            "memberScroll: document.querySelector('.slimming-member-pane').scrollTop })"
        ) == slimming_context_before_thresholds
        page.locator("#slimmingAnalysisOptionsButton").click()
        page.locator("#slimmingAnalysisOptionsContent:not(.hidden)").wait_for()
        assert page.locator("#slimmingCurrentJobSection").is_visible()
        assert "从所选项目查找" in page.locator(
            "#slimmingCurrentJobSummary"
        ).inner_text()
        assert "已完成" in page.locator("#slimmingCurrentJobState").inner_text()
        assert page.locator(
            '#slimmingCurrentJobActions [data-action="deleteRecord"]'
        ).is_visible()
        current_delete = page.locator(
            '#slimmingCurrentJobActions [data-action="deleteRecord"]'
        )
        current_delete.click()
        page.locator("#confirmDialog[open]").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "confirmation"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.confirmationBaseLevel"
        ) == "actionMenu"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.actionMenuKind"
        ) == "slimmingOptions"
        assert "不会读取、移动或删除任何原始媒体" in page.locator(
            "#confirmDialogMessage"
        ).inner_text()
        page.locator("#cancelConfirmButton").click()
        assert page.locator("#slimmingAnalysisOptionsPopover").is_visible()
        assert page.locator("#slimmingWorkspace").is_visible()
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobActionId === jobID "
            "&& document.activeElement?.dataset.action === 'deleteRecord'",
            arg=SLIMMING_JOB_ID,
        )
        page.evaluate("() => history.forward()")
        page.locator("#confirmDialog[open]").wait_for()
        assert page.locator("#slimmingAnalysisOptionsPopover").is_visible()
        page.keyboard.press("Escape")
        page.locator("#confirmDialog").wait_for(state="hidden")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobActionId === jobID "
            "&& document.activeElement?.dataset.action === 'deleteRecord'",
            arg=SLIMMING_JOB_ID,
        )

        page.keyboard.press("Escape")
        page.locator("#slimmingAnalysisOptionsPopover").wait_for(state="hidden")
        page.evaluate("() => toggleSlimmingNavigator()")
        assert page.locator("#slimmingAnalysisBody").evaluate(
            "element => element.classList.contains('navigator-hidden')"
        )
        slimming_job_states[SLIMMING_JOB_ID] = "running"
        page.evaluate("async () => { await loadSlimmingWorkspace({ quiet: true }); }")
        page.evaluate("() => openSlimmingAnalysisOptions()")
        page.wait_for_function(
            "() => document.querySelector('#slimmingCurrentJobState')?.textContent === '进行中'"
        )
        pause_current = page.locator(
            '#slimmingCurrentJobActions [data-action="pause"]'
        )
        assert pause_current.is_visible()
        assert page.locator(
            '#slimmingCurrentJobActions [data-action="deleteRecord"]'
        ).count() == 0
        page.evaluate(
            f"""() => {{
              window.__stableSlimmingJobActions = {{
                navigatorPrimary: document.querySelector(
                  '#slimmingJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                  + '[data-action="pause"]'
                ),
                optionsPrimary: document.querySelector(
                  '#slimmingCurrentJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                  + '[data-action="pause"]'
                ),
                scrollTop: document.querySelector("#slimmingAnalysisOptionsContent").scrollTop,
              }};
            }}"""
        )
        pause_current.click()
        page.wait_for_function(
            "() => document.querySelector('#slimmingCurrentJobState')?.textContent === '已暂停'"
        )
        assert submitted_slimming_job_actions[-1]["jobID"] == SLIMMING_JOB_ID
        assert submitted_slimming_job_actions[-1]["action"] == "pause"
        assert page.locator("#slimmingAnalysisOptionsPopover").is_visible()
        assert page.locator("#slimmingAnalysisBody").evaluate(
            "element => element.classList.contains('navigator-hidden')"
        )
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobActionId === jobID "
            "&& document.activeElement?.dataset.action === 'resume'",
            arg=SLIMMING_JOB_ID,
        )
        stable_slimming_job_actions = page.evaluate(
            f"""() => {{
              const frame = window.__stableSlimmingJobActions;
              const navigatorPrimary = document.querySelector(
                '#slimmingJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                + '[data-action="resume"]'
              );
              const optionsPrimary = document.querySelector(
                '#slimmingCurrentJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                + '[data-action="resume"]'
              );
              return {{
                navigatorPrimary: navigatorPrimary === frame.navigatorPrimary,
                optionsPrimary: optionsPrimary === frame.optionsPrimary,
                focus: document.activeElement === frame.optionsPrimary,
                scroll: document.querySelector("#slimmingAnalysisOptionsContent").scrollTop
                  === frame.scrollTop,
              }};
            }}"""
        )
        assert all(stable_slimming_job_actions.values()), stable_slimming_job_actions

        paused_delete = page.locator(
            '#slimmingCurrentJobActions [data-action="deleteRecord"]'
        )
        paused_delete.click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#cancelConfirmButton").click()
        assert page.locator("#slimmingAnalysisOptionsPopover").is_visible()
        assert page.locator("#slimmingWorkspace").is_visible()
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobActionId === jobID "
            "&& document.activeElement?.dataset.action === 'deleteRecord'",
            arg=SLIMMING_JOB_ID,
        )
        page.evaluate(
            f"""() => {{
              window.__failedSlimmingJobActionFrame = {{
                navigatorPrimary: document.querySelector(
                  '#slimmingJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                  + '[data-action="resume"]'
                ),
                navigatorDelete: document.querySelector(
                  '#slimmingJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                  + '[data-action="deleteRecord"]'
                ),
                optionsPrimary: document.querySelector(
                  '#slimmingCurrentJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                  + '[data-action="resume"]'
                ),
                optionsDelete: document.querySelector(
                  '#slimmingCurrentJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                  + '[data-action="deleteRecord"]'
                ),
                scrollTop: document.querySelector("#slimmingAnalysisOptionsContent").scrollTop,
              }};
            }}"""
        )
        failed_resource_count = len(failed_resources)
        console_error_count = len(console_errors)
        slimming_job_action_fail_next[0] = True
        page.locator('#slimmingCurrentJobActions [data-action="resume"]').click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent"
            ".includes('合成瘦身任务动作失败')"
        )
        page.wait_for_function(
            "() => !document.querySelector("
            "'#slimmingCurrentJobActions [data-action=\"resume\"]'"
            ").disabled"
        )
        failed_slimming_job_action = page.evaluate(
            f"""() => {{
              const frame = window.__failedSlimmingJobActionFrame;
              const navigatorPrimary = document.querySelector(
                '#slimmingJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                + '[data-action="resume"]'
              );
              const optionsPrimary = document.querySelector(
                '#slimmingCurrentJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                + '[data-action="resume"]'
              );
              return {{
                navigatorPrimary: navigatorPrimary === frame.navigatorPrimary,
                navigatorDelete: document.querySelector(
                  '#slimmingJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                  + '[data-action="deleteRecord"]'
                ) === frame.navigatorDelete,
                optionsPrimary: optionsPrimary === frame.optionsPrimary,
                optionsDelete: document.querySelector(
                  '#slimmingCurrentJobActions [data-slimming-job-action-id="{SLIMMING_JOB_ID}"]'
                  + '[data-action="deleteRecord"]'
                ) === frame.optionsDelete,
                focus: document.activeElement === frame.optionsPrimary,
                scroll: document.querySelector("#slimmingAnalysisOptionsContent").scrollTop
                  === frame.scrollTop,
              }};
            }}"""
        )
        assert all(failed_slimming_job_action.values()), failed_slimming_job_action
        assert slimming_job_states[SLIMMING_JOB_ID] == "paused"
        assert submitted_slimming_job_actions[-1]["action"] == "pause"
        assert len(failed_resources) == failed_resource_count + 1
        assert failed_resources[-1][0] == 409
        failed_resources.pop()
        assert len(console_errors) == console_error_count + 1
        assert "409" in console_errors[-1]
        console_errors.pop()
        page.locator('#slimmingCurrentJobActions [data-action="resume"]').click()
        page.wait_for_function(
            "() => document.querySelector('#slimmingCurrentJobState')?.textContent === '进行中'"
        )
        assert submitted_slimming_job_actions[-1]["action"] == "resume"
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobActionId === jobID "
            "&& document.activeElement?.dataset.action === 'pause'",
            arg=SLIMMING_JOB_ID,
        )

        slimming_job_states[SLIMMING_JOB_ID] = "completed"
        page.evaluate("async () => { await loadSlimmingWorkspace({ quiet: true }); }")
        page.keyboard.press("Escape")
        page.locator("#slimmingAnalysisOptionsPopover").wait_for(state="hidden")
        page.evaluate("() => toggleSlimmingNavigator()")
        assert not page.locator("#slimmingAnalysisBody").evaluate(
            "element => element.classList.contains('navigator-hidden')"
        )
        slimming_job_states[SLIMMING_JOB_ID] = "running"
        page.evaluate("async () => { await loadSlimmingWorkspace({ quiet: true }); }")
        navigator_pause = page.locator(
            '#slimmingJobActions [data-action="pause"]'
        )
        page.evaluate(
            """() => {
              window.__navigatorSlimmingPrimary = document.querySelector(
                '#slimmingJobActions [data-action="pause"]'
              );
              window.__navigatorSlimmingScrollTop =
                document.querySelector("#slimmingNavigatorPane").scrollTop;
            }"""
        )
        navigator_pause.click()
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobActionId === jobID "
            "&& document.activeElement?.dataset.action === 'resume'",
            arg=SLIMMING_JOB_ID,
        )
        assert page.evaluate(
            """() => document.querySelector('#slimmingJobActions [data-action="resume"]')
              === window.__navigatorSlimmingPrimary
              && document.activeElement === window.__navigatorSlimmingPrimary
              && document.querySelector("#slimmingNavigatorPane").scrollTop
                === window.__navigatorSlimmingScrollTop"""
        )
        page.locator('#slimmingJobActions [data-action="resume"]').click()
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobActionId === jobID "
            "&& document.activeElement?.dataset.action === 'pause'",
            arg=SLIMMING_JOB_ID,
        )
        assert page.evaluate(
            """() => document.querySelector('#slimmingJobActions [data-action="pause"]')
              === window.__navigatorSlimmingPrimary
              && document.activeElement === window.__navigatorSlimmingPrimary"""
        )
        slimming_job_states[SLIMMING_JOB_ID] = "retryableFailed"
        slimming_job_attempts[SLIMMING_JOB_ID] = 2
        slimming_job_error_codes[SLIMMING_JOB_ID] = "synthetic_retryable"
        page.evaluate("async () => { await loadSlimmingWorkspace({ quiet: true }); }")
        page.locator("#slimmingJobStatus:not(.hidden)").wait_for()
        page.locator("#slimmingJobStatus [data-open-job-activity-id]").focus()
        page.evaluate(
            """() => {
              const status = document.querySelector("#slimmingJobStatus");
              window.__stableSlimmingJobStatus = {
                copy: status.querySelector(".slimming-job-status-copy"),
                heading: status.querySelector(".slimming-job-status-copy strong"),
                detail: status.querySelector(".slimming-job-status-copy span"),
                actions: status.querySelector(".slimming-job-status-actions"),
                activity: status.querySelector("[data-open-job-activity-id]"),
                resume: status.querySelector('[data-action="resume"]'),
                diagnosis: status.querySelector(".slimming-job-diagnosis"),
                code: status.querySelector(".slimming-job-diagnosis code"),
              };
            }"""
        )
        slimming_job_attempts[SLIMMING_JOB_ID] = 3
        slimming_job_error_codes[SLIMMING_JOB_ID] = "synthetic_retryable_changed"
        page.evaluate("async () => { await loadSlimmingWorkspace({ quiet: true }); }")
        stable_slimming_job_status = page.evaluate(
            """() => {
              const frame = window.__stableSlimmingJobStatus;
              const status = document.querySelector("#slimmingJobStatus");
              return {
                copy: status.querySelector(".slimming-job-status-copy") === frame.copy,
                heading: status.querySelector(".slimming-job-status-copy strong")
                  === frame.heading,
                detail: status.querySelector(".slimming-job-status-copy span")
                  === frame.detail,
                actions: status.querySelector(".slimming-job-status-actions")
                  === frame.actions,
                activity: status.querySelector("[data-open-job-activity-id]")
                  === frame.activity,
                resume: status.querySelector('[data-action="resume"]') === frame.resume,
                diagnosis: status.querySelector(".slimming-job-diagnosis")
                  === frame.diagnosis,
                code: status.querySelector(".slimming-job-diagnosis code") === frame.code,
                focus: document.activeElement === frame.activity,
                detailUpdated: frame.detail.textContent.includes("尝试 3/10"),
                codeUpdated: frame.code.textContent === "synthetic_retryable_changed",
              };
            }"""
        )
        assert all(stable_slimming_job_status.values()), stable_slimming_job_status
        page.evaluate(
            """() => {
              const status = document.querySelector("#slimmingJobStatus");
              window.__failedSlimmingJobStatus = {
                copy: status.querySelector(".slimming-job-status-copy"),
                actions: status.querySelector(".slimming-job-status-actions"),
                activity: status.querySelector("[data-open-job-activity-id]"),
                resume: status.querySelector('[data-action="resume"]'),
                diagnosis: status.querySelector(".slimming-job-diagnosis"),
                code: status.querySelector(".slimming-job-diagnosis code"),
              };
            }"""
        )
        status_resume = page.locator('#slimmingJobStatus [data-action="resume"]')
        status_resume.focus()
        failed_resource_count = len(failed_resources)
        console_error_count = len(console_errors)
        slimming_job_action_fail_next[0] = True
        status_resume.click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent"
            ".includes('合成瘦身任务动作失败')"
        )
        failed_slimming_job_status = page.evaluate(
            """() => {
              const frame = window.__failedSlimmingJobStatus;
              const status = document.querySelector("#slimmingJobStatus");
              return {
                copy: status.querySelector(".slimming-job-status-copy") === frame.copy,
                actions: status.querySelector(".slimming-job-status-actions")
                  === frame.actions,
                activity: status.querySelector("[data-open-job-activity-id]")
                  === frame.activity,
                resume: status.querySelector('[data-action="resume"]') === frame.resume,
                diagnosis: status.querySelector(".slimming-job-diagnosis")
                  === frame.diagnosis,
                code: status.querySelector(".slimming-job-diagnosis code") === frame.code,
                focus: document.activeElement === frame.resume,
              };
            }"""
        )
        assert all(failed_slimming_job_status.values()), failed_slimming_job_status
        assert slimming_job_states[SLIMMING_JOB_ID] == "retryableFailed"
        assert len(failed_resources) == failed_resource_count + 1
        assert failed_resources[-1][0] == 409
        failed_resources.pop()
        assert len(console_errors) == console_error_count + 1
        assert "409" in console_errors[-1]
        console_errors.pop()
        slimming_job_scan_progress[SLIMMING_JOB_ID] = {
            "phase": "loadingEmbeddings",
            "completedUnitCount": 2,
            "totalUnitCount": 10,
        }
        status_resume.click()
        page.wait_for_function(
            "() => document.querySelector('#slimmingJobStatus')"
            ".classList.contains('running')"
        )
        resumed_slimming_job_status = page.evaluate(
            """() => {
              const frame = window.__failedSlimmingJobStatus;
              const status = document.querySelector("#slimmingJobStatus");
              return {
                copy: status.querySelector(".slimming-job-status-copy") === frame.copy,
                actions: status.querySelector(".slimming-job-status-actions")
                  === frame.actions,
                activity: status.querySelector("[data-open-job-activity-id]")
                  === frame.activity,
                focus: document.activeElement === frame.activity,
                resumeRemoved: !status.querySelector('[data-action="resume"]'),
                diagnosisRemoved: !status.querySelector(".slimming-job-diagnosis"),
                guardVisible: Boolean(status.querySelector(".slimming-job-guard")),
              };
            }"""
        )
        assert all(resumed_slimming_job_status.values()), resumed_slimming_job_status
        assert submitted_slimming_job_actions[-1]["action"] == "resume"
        page.evaluate(
            """() => {
              const progress = document.querySelector(
                '#slimmingJobStatus .slimming-scan-progress'
              );
              window.__stableSlimmingJobStatusProgress = {
                progress,
                track: progress.querySelector('.slimming-scan-progress-track'),
                fill: progress.querySelector('.slimming-scan-progress-track > span'),
                copy: progress.querySelector(':scope > span:not(.slimming-scan-progress-track)'),
                activity: document.querySelector(
                  '#slimmingJobStatus [data-open-job-activity-id]'
                ),
              };
            }"""
        )
        slimming_job_scan_progress[SLIMMING_JOB_ID] = {
            "phase": "clustering",
            "completedUnitCount": 7,
            "totalUnitCount": 10,
        }
        page.evaluate("async () => { await loadSlimmingWorkspace({ quiet: true }); }")
        stable_slimming_job_status_progress = page.evaluate(
            """() => {
              const frame = window.__stableSlimmingJobStatusProgress;
              const progress = document.querySelector(
                '#slimmingJobStatus .slimming-scan-progress'
              );
              return {
                progress: progress === frame.progress,
                track: progress.querySelector('.slimming-scan-progress-track') === frame.track,
                fill: progress.querySelector('.slimming-scan-progress-track > span') === frame.fill,
                copy: progress.querySelector(
                  ':scope > span:not(.slimming-scan-progress-track)'
                ) === frame.copy,
                activity: document.querySelector(
                  '#slimmingJobStatus [data-open-job-activity-id]'
                ) === frame.activity,
                focus: document.activeElement === frame.activity,
                textUpdated: frame.copy.textContent === "聚类分析 7/10",
                widthUpdated: frame.fill.style.width === "70%",
              };
            }"""
        )
        assert all(stable_slimming_job_status_progress.values()), (
            stable_slimming_job_status_progress
        )
        slimming_job_states[SLIMMING_JOB_ID] = "completed"
        slimming_job_attempts[SLIMMING_JOB_ID] = 1
        slimming_job_error_codes[SLIMMING_JOB_ID] = None
        slimming_job_scan_progress[SLIMMING_JOB_ID] = None
        page.evaluate("async () => { await loadSlimmingWorkspace({ quiet: true }); }")
        navigator_delete = page.locator(
            '#slimmingJobActions [data-action="deleteRecord"]'
        )
        page.evaluate(
            """() => {
              window.__navigatorSlimmingDelete = document.querySelector(
                '#slimmingJobActions [data-action="deleteRecord"]'
              );
            }"""
        )
        navigator_delete.click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#cancelConfirmButton").click()
        page.wait_for_function(
            "() => document.activeElement === window.__navigatorSlimmingDelete"
        )
        assert page.evaluate(
            """() => document.querySelector(
              '#slimmingJobActions [data-action="deleteRecord"]'
            ) === window.__navigatorSlimmingDelete"""
        )
        page.evaluate("() => openSlimmingAnalysisOptions()")
        page.locator("#slimmingAnalysisOptionsContent:not(.hidden)").wait_for()
        maintenance_sources = page.locator(
            "#slimmingMaintenanceSourceOptions [data-slimming-maintenance-source-id]"
        )
        assert maintenance_sources.count() == 2
        assert "1 / 2" in page.locator("#slimmingMaintenanceSourceSummary").inner_text()
        assert maintenance_sources.nth(0).is_checked()
        assert not maintenance_sources.nth(1).is_checked()
        page.locator("#refreshSlimmingSourcesButton").click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('刷新 1 个来源')"
        )
        assert submitted_slimming_source_maintenance[-1]["action"] == "refreshCatalog"
        assert submitted_slimming_source_maintenance[-1]["sourceIDs"] == [SOURCE_ID]
        page.locator("#slimmingIndexSourceSelect").select_option(SECOND_SOURCE_ID)
        assert "未初始化" in page.locator("#slimmingSourceIndexStatus").inner_text()
        page.locator("#initializeSlimmingSourceIndexButton").click()
        assert submitted_slimming_source_maintenance[-1]["action"] == "initializeSimilarityIndex"
        assert submitted_slimming_source_maintenance[-1]["sourceIDs"] == [SECOND_SOURCE_ID]
        page.wait_for_function(
            "() => document.querySelector('#slimmingSourceIndexStatus')"
            ".textContent.includes('就绪 80/80 · 12 簇')",
            timeout=6_000,
        )
        assert page.locator("#initializeSlimmingSourceIndexButton").inner_text() == "重新构建来源索引"
        page.keyboard.press("Escape")
        assert page.locator("#slimmingAnalysisOptionsPopover").is_hidden()
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingAnalysisOptionsButton'"
        )

        slimming_jobs = page.locator("#slimmingJobList [data-slimming-job-id]")
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingJobList [data-slimming-job-id]').length === 2"
        )
        assert slimming_jobs.nth(0).get_attribute("aria-selected") == "true"
        second_job = page.locator(
            f'[data-slimming-job-id="{SLIMMING_SECOND_JOB_ID}"]'
        )
        second_job.focus()
        second_job.press("Shift+F10")
        job_context_menu = page.locator("#slimmingJobContextMenu:not(.hidden)")
        job_context_menu.wait_for()
        assert page.locator(
            f'[data-slimming-job-id="{SLIMMING_JOB_ID}"]'
        ).get_attribute("aria-selected") == "true"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "contextMenu"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.contextMenuKind"
        ) == "slimmingJob"
        page.evaluate("() => history.back()")
        job_context_menu.wait_for(state="hidden")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobId === jobID",
            arg=SLIMMING_SECOND_JOB_ID,
        )
        page.evaluate("() => history.forward()")
        job_context_menu.wait_for()
        page.wait_for_function(
            "() => document.querySelector('#slimmingJobContextMenu').contains(document.activeElement)"
        )
        page.keyboard.press("Escape")
        assert job_context_menu.is_hidden()
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobId === jobID",
            arg=SLIMMING_SECOND_JOB_ID,
        )

        second_job.click(button="right")
        job_context_menu.locator('[data-slimming-job-context-action="deleteRecord"]').click()
        confirmation = page.locator("#confirmDialog[open]")
        confirmation.wait_for()
        assert confirmation.get_attribute("data-tone") == "danger"
        assert "不会读取、移动或删除任何原始媒体" in page.locator(
            "#confirmDialogMessage"
        ).inner_text()
        page.locator("#cancelConfirmButton").click()
        assert slimming_jobs.count() == 2
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobId === jobID",
            arg=SLIMMING_SECOND_JOB_ID,
        )
        second_job.click(button="right")
        job_context_menu.locator('[data-slimming-job-context-action="deleteRecord"]').click()
        confirmation.wait_for()
        page.locator("#confirmActionButton").click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingJobList [data-slimming-job-id]').length === 1"
        )
        assert submitted_slimming_job_actions[-1]["jobID"] == SLIMMING_SECOND_JOB_ID
        assert submitted_slimming_job_actions[-1]["action"] == "deleteRecord"
        assert page.locator(
            f'[data-slimming-job-id="{SLIMMING_JOB_ID}"]'
        ).get_attribute("aria-selected") == "true"

        pending_scope = page.locator('[data-slimming-cluster-scope="pending"]')
        confirmed_scope = page.locator('[data-slimming-cluster-scope="confirmed"]')
        ignored_scope = page.locator('[data-slimming-cluster-scope="ignored"]')
        assert pending_scope.get_attribute("aria-pressed") == "true"
        assert pending_scope.locator(".slimming-cluster-scope-count").inner_text() == "1"
        assert confirmed_scope.locator(".slimming-cluster-scope-count").inner_text() == "1"
        assert ignored_scope.locator(".slimming-cluster-scope-count").inner_text() == "1"
        page.locator(
            f'[data-slimming-cluster-review-id="{SLIMMING_CLUSTER_ID}"]'
            '[data-slimming-cluster-review="confirmed"]'
        ).click()
        page.wait_for_function(
            "() => document.querySelector('[data-slimming-cluster-scope=\"pending\"]')"
            ".querySelector('.slimming-cluster-scope-count').textContent === '0'"
        )
        assert submitted_slimming_cluster_reviews[-1]["clusterID"] == SLIMMING_CLUSTER_ID
        assert submitted_slimming_cluster_reviews[-1]["disposition"] == "confirmed"
        assert page.locator("#slimmingClusterList .slimming-cluster-row").count() == 0

        confirmed_scope.click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingClusterList .slimming-cluster-row').length === 2"
        )
        assert page.locator("#slimmingSelectedClusterReviewStatus").inner_text() == "✓ 已确认"
        page.screenshot(path="/tmp/imageall-slimming-cluster-confirmed.png", full_page=True)
        page.locator("#slimmingReprocessClusterButton").click()
        page.wait_for_function(
            "() => !state.slimming.loading && "
            "document.querySelectorAll('#slimmingClusterList .slimming-cluster-row').length === 1 && "
            "document.querySelector('.slimming-cluster-history-mark')"
        )
        assert submitted_slimming_cluster_reviews[-1]["disposition"] is None
        assert page.locator("#slimmingMemberEmpty strong").inner_text() == "历史处理记录"
        assert "成员当前均已回收" in page.locator("#slimmingMemberEmpty p").inner_text()
        assert page.locator("#slimmingSelectedClusterReviewStatus").inner_text() == "✓ 已确认"
        page.screenshot(path="/tmp/imageall-slimming-historical-reviewed-cluster.png", full_page=True)
        page.locator("#slimmingReprocessClusterButton").click()
        page.wait_for_function(
            "() => !state.slimming.loading && "
            "document.querySelectorAll('#slimmingClusterList .slimming-cluster-row').length === 0"
        )
        assert "当前不足两项" in page.locator("#toastMessage").inner_text()
        pending_scope.click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingClusterList .slimming-cluster-row').length === 1"
        )
        assert page.locator(
            f'[data-slimming-cluster-id="{SLIMMING_CLUSTER_ID}"]'
        ).get_attribute("aria-pressed") == "true"
        pending_scope.focus()
        pending_scope.press("End")
        page.wait_for_function(
            f"() => !state.slimming.loading && "
            "document.querySelector('[data-slimming-cluster-scope=\"ignored\"]')"
            ".getAttribute('aria-pressed') === 'true' && "
            f"document.querySelector('[data-slimming-cluster-row-id=\"{SLIMMING_IGNORED_CLUSTER_ID}\"]')"
        )
        assert page.locator("#slimmingClusterList .slimming-cluster-row").count() == 1
        ignored_scope.press("Home")
        page.wait_for_function(
            f"() => !state.slimming.loading && "
            "document.querySelector('[data-slimming-cluster-scope=\"pending\"]')"
            ".getAttribute('aria-pressed') === 'true' && "
            f"document.querySelector('[data-slimming-cluster-row-id=\"{SLIMMING_CLUSTER_ID}\"]')"
        )
        page.screenshot(path="/tmp/imageall-slimming-cluster-review-queues.png", full_page=True)

        assert page.evaluate(
            "ids => replacementSlimmingPreviewAssetID(ids, [ids[0], ids[2]], ids[1])",
            SLIMMING_ASSET_IDS,
        ) == SLIMMING_ASSET_IDS[2]
        assert page.evaluate(
            "ids => replacementSlimmingPreviewAssetID(ids, [ids[0], ids[1]], ids[2])",
            SLIMMING_ASSET_IDS,
        ) == SLIMMING_ASSET_IDS[1]
        assert page.evaluate(
            "ids => replacementSlimmingPreviewAssetID(ids, [], ids[1])",
            SLIMMING_ASSET_IDS,
        ) is None

        slimming_cards = page.locator("#slimmingMemberGrid > .slimming-member-card")
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card').length === 3"
        )
        assert slimming_cards.count() == 3
        first_slimming_main = slimming_cards.nth(0).locator(
            ":scope > .slimming-member-main"
        )
        second_slimming_main = slimming_cards.nth(1).locator(
            ":scope > .slimming-member-main"
        )
        first_slimming_favorite = slimming_cards.nth(0).locator(
            ":scope > .slimming-member-favorite"
        )
        second_slimming_favorite = slimming_cards.nth(1).locator(
            ":scope > .slimming-member-favorite"
        )
        assert first_slimming_main.get_attribute("tabindex") == "0"
        assert first_slimming_favorite.get_attribute("tabindex") == "0"
        assert second_slimming_main.get_attribute("tabindex") == "-1"
        assert second_slimming_favorite.get_attribute("tabindex") == "-1"
        first_slimming_main.focus()
        page.keyboard.press("Tab")
        assert page.evaluate(
            "() => document.activeElement?.classList.contains('slimming-member-favorite')"
        )
        page.keyboard.press("Tab")
        assert not page.evaluate(
            "() => document.querySelector('#slimmingMemberGrid')"
            ".contains(document.activeElement)"
        )
        second_slimming_main.focus()
        assert first_slimming_main.get_attribute("tabindex") == "-1"
        assert first_slimming_favorite.get_attribute("tabindex") == "-1"
        assert second_slimming_main.get_attribute("tabindex") == "0"
        assert second_slimming_favorite.get_attribute("tabindex") == "0"
        first_slimming_main.focus()
        page.screenshot(path="/tmp/imageall-slimming-roving-focus.png", full_page=False)
        page.keyboard.press("ArrowRight")
        assert page.evaluate(
            "id => state.slimming.selectedMemberIDs.size === 1 "
            "&& state.slimming.selectedMemberIDs.has(id)",
            SLIMMING_ASSET_IDS[1],
        )
        assert page.evaluate(
            "id => document.activeElement?.closest('[data-slimming-member-id]')"
            "?.dataset.slimmingMemberId === id "
            "&& document.querySelectorAll('#slimmingMemberGrid "
            ".slimming-member-main[tabindex=\"0\"]')"
            ".length === 1 "
            "&& document.querySelectorAll('#slimmingMemberGrid "
            ".slimming-member-favorite[tabindex=\"0\"]')"
            ".length === 1",
            SLIMMING_ASSET_IDS[1],
        )
        page.keyboard.down("Shift")
        page.keyboard.press("ArrowRight")
        page.keyboard.up("Shift")
        assert set(page.evaluate("() => [...state.slimming.selectedMemberIDs]")) == set(
            SLIMMING_ASSET_IDS[1:]
        )
        page.keyboard.press("Home")
        assert page.evaluate(
            "id => state.slimming.selectedMemberIDs.size === 1 "
            "&& state.slimming.selectedMemberIDs.has(id)",
            SLIMMING_ASSET_IDS[0],
        )
        page.keyboard.press("End")
        assert page.evaluate(
            "id => state.slimming.selectedMemberIDs.has(id)",
            SLIMMING_ASSET_IDS[2],
        )
        page.keyboard.press("PageUp")
        assert page.evaluate(
            "id => state.slimming.selectedMemberIDs.has(id)",
            SLIMMING_ASSET_IDS[0],
        )
        page.keyboard.press("PageDown")
        assert page.evaluate(
            "id => state.slimming.selectedMemberIDs.has(id)",
            SLIMMING_ASSET_IDS[2],
        )
        page.keyboard.press("Home")
        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "SLIM_0001.JPG" in page.locator("#lightboxTitle").inner_text()
        page.keyboard.press("Space")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberMain === 'true'"
        )
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        assert page.evaluate(
            """() => {
              const workspace = document.querySelector('#slimmingWorkspace');
              return document.querySelector('#appView').inert
                && workspace.getAttribute('role') === 'dialog'
                && workspace.getAttribute('aria-modal') === 'true'
                && !workspace.classList.contains('integrated');
            }"""
        )
        assert page.locator("#slimmingInspector").is_visible()
        slimming_selection_mode = page.locator("#slimmingSelectionModeButton")
        slimming_select_all = page.locator("#slimmingSelectAllButton")
        assert slimming_selection_mode.is_visible()
        slimming_selection_mode.click()
        assert slimming_selection_mode.get_attribute("aria-pressed") == "true"
        assert slimming_selection_mode.inner_text() == "完成"
        assert slimming_select_all.is_visible()
        slimming_select_all.click()
        assert page.evaluate("() => state.slimming.selectedMemberIDs.size") == 3
        assert slimming_select_all.is_disabled()
        slimming_space_preview_snapshot = page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        )
        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "SLIM_0001.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate("() => state.lightboxPreservesSelection") is True
        page.locator("#lightboxNextButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('SLIM_0002.JPG')"
        )
        assert page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        ) == slimming_space_preview_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        assert page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        ) == slimming_space_preview_snapshot
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberMain === 'true'"
        )
        assert page.evaluate(
            "() => document.activeElement.closest('[data-slimming-member-id]')"
            ".dataset.slimmingMemberId"
        ) == SLIMMING_ASSET_IDS[0]
        slimming_cards.nth(1).locator(":scope > .slimming-member-main").click()
        assert page.evaluate("() => state.slimming.selectedMemberIDs.size") == 2
        assert slimming_select_all.is_enabled()
        slimming_double_click_snapshot = page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        )
        slimming_cards.nth(1).locator(":scope > .slimming-member-main").dblclick()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "SLIM_0002.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        ) == slimming_double_click_snapshot
        assert page.evaluate("() => state.lightboxPreservesSelection") is True
        page.locator("#lightboxNextButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('SLIM_0003.JPG')"
        )
        assert page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        ) == slimming_double_click_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        assert page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        ) == slimming_double_click_snapshot
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberMain === 'true'"
        )
        # The context target is not selected, so the saved anchor is stale.
        # Space must fall back to the first still-selected member in visual order.
        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "SLIM_0001.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate("() => state.lightboxPreservesSelection") is True
        assert page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        ) == slimming_double_click_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.closest('[data-slimming-member-id]')"
            f"?.dataset.slimmingMemberId === '{SLIMMING_ASSET_IDS[0]}'"
        )
        slimming_select_all.click()
        assert page.evaluate("() => state.slimming.selectedMemberIDs.size") == 3
        page.screenshot(
            path="/tmp/imageall-slimming-touch-selection-active-390.png",
            full_page=True,
        )
        slimming_selection_mode.click()
        assert slimming_selection_mode.get_attribute("aria-pressed") == "false"
        assert slimming_selection_mode.inner_text() == "选择"
        assert slimming_select_all.is_hidden()
        assert page.evaluate("() => state.slimming.selectedMemberIDs.size") == 1
        slimming_selection_mode.click()
        slimming_cards.nth(1).locator(":scope > .slimming-member-main").click()
        assert page.evaluate("() => state.slimming.selectedMemberIDs.size") == 2
        page.keyboard.press("Escape")
        assert page.locator("#slimmingWorkspace").is_visible()
        assert slimming_selection_mode.get_attribute("aria-pressed") == "false"
        assert page.evaluate("() => state.slimming.selectedMemberIDs.size") == 1
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingSelectionModeButton'"
        )
        slimming_selection_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth, "
            "buttonRight: document.querySelector('#slimmingSelectionModeButton')"
            ".getBoundingClientRect().right })"
        )
        assert slimming_selection_dimensions["scroll"] <= slimming_selection_dimensions["viewport"]
        assert slimming_selection_dimensions["buttonRight"] <= slimming_selection_dimensions["viewport"]
        page.screenshot(
            path="/tmp/imageall-slimming-touch-selection-390.png",
            full_page=True,
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_timeout(100)
        expanded_slimming_marquee_enabled = True
        page.evaluate(
            """() => {
              // Keep this synthetic geometry fixture isolated from any workspace
              // refresh legitimately still settling after the preceding actions.
              state.slimming.requestGeneration += 1;
              state.slimming.loading = false;
              state.slimming.appending = null;
              window.__slimmingMarqueeMembers = state.slimming.members;
              window.__slimmingMarqueeMinWidth = document.documentElement.style.getPropertyValue(
                '--slimming-member-min-width'
              );
              document.documentElement.style.setProperty('--slimming-member-min-width', '220px');
              const template = state.slimming.members[0];
              const extras = [];
              for (let index = 1; index <= 96; index += 1) {
                const id = `91000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
                extras.push({
                  ...template,
                  id,
                  fileName: `MARQUEE_${String(index).padStart(3, '0')}.JPG`,
                  favorite: template.favorite ? { ...template.favorite, assetID: id } : null,
                });
              }
              state.slimming.members = [...state.slimming.members, ...extras];
              const cluster = state.slimming.clusters.find(
                item => item.id === state.slimming.selectedClusterID
              );
              window.__slimmingMarqueeMemberCount = cluster?.memberCount;
              if (cluster) cluster.memberCount = state.slimming.members.length;
              state.slimming.selectedMemberIDs.clear();
              state.slimming.selectionAnchorID = null;
              renderSlimmingMembers();
            }"""
        )
        slimming_marquee_container = page.evaluate(
            "() => slimmingMemberScrollContainer() === elements.slimmingMemberGrid "
            "? '#slimmingMemberGrid' : '.slimming-member-pane'"
        )
        slimming_marquee_scroll = drag_marquee_to_bottom_edge(
            page,
            slimming_marquee_container,
            "#slimmingMemberGrid",
        )
        slimming_marquee_selection = page.evaluate(
            "() => [...state.slimming.selectedMemberIDs]"
        )
        assert slimming_marquee_scroll > 80
        assert SLIMMING_ASSET_IDS[0] in slimming_marquee_selection
        assert any(
            asset_id.startswith("91000000-0000-4000-8000-")
            for asset_id in slimming_marquee_selection
        )
        page.evaluate(
            """() => {
              elements.slimmingMemberGrid.scrollTop = 0;
              elements.slimmingMemberGrid.closest('.slimming-member-pane').scrollTop = 0;
              state.slimming.selectedMemberIDs.clear();
              state.slimming.selectionAnchorID = null;
              renderSlimmingMemberSelection();
            }"""
        )
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        assert page.evaluate(
            "() => slimmingMemberScrollContainer().classList.contains('slimming-member-pane')"
        )
        slimming_narrow_marquee_scroll = drag_marquee_to_bottom_edge(
            page,
            ".slimming-member-pane",
            "#slimmingMemberGrid",
        )
        slimming_narrow_marquee_selection = page.evaluate(
            "() => [...state.slimming.selectedMemberIDs]"
        )
        slimming_narrow_marquee_metrics = page.locator(".slimming-member-pane").evaluate(
            "element => ({ scrollTop: element.scrollTop, clientHeight: element.clientHeight, "
            "scrollHeight: element.scrollHeight, gridHeight: "
            "document.querySelector('#slimmingMemberGrid').getBoundingClientRect().height, "
            "stateMemberCount: state.slimming.members.length, cardCount: "
            "document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card').length })"
        )
        assert slimming_narrow_marquee_scroll > 80, slimming_narrow_marquee_metrics
        assert SLIMMING_ASSET_IDS[0] in slimming_narrow_marquee_selection
        assert any(
            asset_id.startswith("91000000-0000-4000-8000-")
            for asset_id in slimming_narrow_marquee_selection
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_timeout(100)
        page.evaluate(
            """() => {
              const cluster = state.slimming.clusters.find(
                item => item.id === state.slimming.selectedClusterID
              );
              state.slimming.members = window.__slimmingMarqueeMembers;
              if (cluster) cluster.memberCount = window.__slimmingMarqueeMemberCount;
              delete window.__slimmingMarqueeMembers;
              delete window.__slimmingMarqueeMemberCount;
              if (window.__slimmingMarqueeMinWidth) {
                document.documentElement.style.setProperty(
                  '--slimming-member-min-width',
                  window.__slimmingMarqueeMinWidth
                );
              } else {
                document.documentElement.style.removeProperty('--slimming-member-min-width');
              }
              delete window.__slimmingMarqueeMinWidth;
              state.slimming.selectedMemberIDs.clear();
              state.slimming.selectionAnchorID = null;
              slimmingMemberScrollContainer().scrollTop = 0;
              renderSlimmingMembers();
            }"""
        )
        expanded_slimming_marquee_enabled = False
        slimming_cards = page.locator("#slimmingMemberGrid > .slimming-member-card")
        first_slimming_main = slimming_cards.nth(0).locator(":scope > .slimming-member-main")
        second_slimming_main = slimming_cards.nth(1).locator(":scope > .slimming-member-main")
        page.keyboard.press("Meta+K")
        page.locator('[data-command-id="selectAll"]').click()
        page.wait_for_function(
            "() => state.slimming.selectedMemberIDs.size === state.slimming.members.length"
        )
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).count() == slimming_cards.count()
        page.keyboard.press("Meta+K")
        assert page.locator('[data-command-id="recycleSlimmingSelection"]').count() == 1
        assert page.locator('[data-command-id="releaseSlimmingSelection"]').count() == 1
        page.screenshot(path="/tmp/imageall-slimming-command-actions.png", full_page=True)
        with page.expect_response("**/v1/favorites"):
            page.locator('[data-command-id="favoriteSelection"]').click()
        page.wait_for_function(
            "() => state.slimming.members.every(member => member.favorite?.isFavorite === true)"
        )
        assert set(submitted_favorites[-1]["assetIDs"]) == set(SLIMMING_ASSET_IDS)
        assert submitted_favorites[-1]["isFavorite"] is True
        page.keyboard.press("Meta+K")
        with page.expect_response("**/v1/favorites"):
            page.locator('[data-command-id="unfavoriteSelection"]').click()
        page.wait_for_function(
            "() => state.slimming.members.every(member => member.favorite?.isFavorite === false)"
        )
        assert submitted_favorites[-1]["isFavorite"] is False
        first_slimming_main.click()
        second_slimming_main.click(modifiers=["Shift"])
        page.keyboard.press("Meta+K")
        with page.expect_response("**/v1/favorites"):
            page.locator('[data-command-id="favoriteSelection"]').click()
        page.wait_for_function(
            "ids => ids.every(id => favoriteStateForAssetID(id)?.isFavorite === true)",
            arg=ASSET_IDS,
        )
        assert submitted_favorites[-1]["assetIDs"] == ASSET_IDS
        assert submitted_favorites[-1]["isFavorite"] is True
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        assert "已选择 2 项" in page.locator("#slimmingSelectionSummary").inner_text()

        context_favorite_before = slimming_cards.nth(0).locator(
            ":scope > .slimming-member-favorite"
        ).get_attribute("data-favorite")
        first_slimming_main.click(button="right")
        slimming_context_menu = page.locator("#slimmingMemberContextMenu:not(.hidden)")
        slimming_context_menu.wait_for()
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        protected_recycle_action = slimming_context_menu.locator(
            '[data-slimming-member-context-action="recoverableRecycle"]'
        )
        protected_delete_action = slimming_context_menu.locator(
            '[data-slimming-member-context-action="releaseSourceSpace"]'
        )
        assert "(0)" in protected_recycle_action.inner_text()
        assert "(0)" in protected_delete_action.inner_text()
        assert protected_recycle_action.is_disabled()
        assert protected_delete_action.is_disabled()
        assert "保留 2 项红心" in page.locator("#slimmingSelectionSummary").inner_text()
        slimming_context_menu.locator(
            '[data-slimming-member-context-action="favorite"]'
        ).click()
        page.wait_for_function(
            "before => document.querySelector('#slimmingMemberGrid .slimming-member-favorite')"
            "?.dataset.favorite !== before",
            arg=context_favorite_before,
        )
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        assert slimming_context_menu.is_hidden()
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberMain === 'true'"
        )

        first_slimming_main.press("Shift+F10")
        slimming_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberContextAction === 'preview'"
        )
        mixed_selection_recycle_action = slimming_context_menu.locator(
            '[data-slimming-member-context-action="recoverableRecycle"]'
        )
        assert "(1)" in mixed_selection_recycle_action.inner_text()
        assert not mixed_selection_recycle_action.is_disabled()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.contextMenuKind"
        ) == "slimmingMember"
        page.evaluate("() => history.back()")
        slimming_context_menu.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberMain === 'true'"
        )
        page.evaluate("() => history.forward()")
        slimming_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberContextAction === 'preview'"
        )
        page.screenshot(path="/tmp/imageall-slimming-context-menu.png", full_page=True)
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.slimmingMemberContextAction"
            " === 'releaseSourceSpace'"
        )
        page.keyboard.press("Home")
        assert page.evaluate(
            "() => document.activeElement?.dataset.slimmingMemberContextAction"
            " === 'preview'"
        )
        slimming_context_preview = page.locator(
            '[data-slimming-member-context-action="preview"]'
        )
        assert "单图查看" in slimming_context_preview.inner_text()
        slimming_context_preview_snapshot = page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        )
        slimming_context_preview.click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "SLIM_0001.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        ) == slimming_context_preview_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberMain === 'true'"
        )
        assert page.evaluate(
            """() => ({
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              scrollTop: document.querySelector('#slimmingAnalysisBody').scrollTop,
            })"""
        ) == slimming_context_preview_snapshot

        first_slimming_favorite = slimming_cards.nth(0).locator(
            ":scope > .slimming-member-favorite"
        )
        slimming_cards.nth(0).hover()
        assert first_slimming_favorite.is_visible()
        slimming_favorite_before = first_slimming_favorite.get_attribute("data-favorite")
        slimming_scroll_before = page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        )
        first_slimming_favorite.click()
        page.wait_for_function(
            "before => document.querySelector('#slimmingMemberGrid .slimming-member-favorite')"
            "?.dataset.favorite !== before",
            arg=slimming_favorite_before,
        )
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        assert page.locator("#lightbox").is_hidden()
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        ) == slimming_scroll_before
        assert page.evaluate(
            "() => document.activeElement?.classList.contains('slimming-member-favorite')"
        )
        first_slimming_favorite.press("Enter")
        page.wait_for_function(
            "before => document.querySelector('#slimmingMemberGrid .slimming-member-favorite')"
            "?.dataset.favorite === before",
            arg=slimming_favorite_before,
        )
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        first_slimming_favorite.click()
        page.wait_for_function(
            "before => document.querySelector('#slimmingMemberGrid .slimming-member-favorite')"
            "?.dataset.favorite === before",
            arg=context_favorite_before,
        )

        grid_box = page.locator("#slimmingMemberGrid").bounding_box()
        first_box = slimming_cards.nth(0).bounding_box()
        assert grid_box and first_box
        page.mouse.move(grid_box["x"] + 2, grid_box["y"] + 2)
        page.mouse.down()
        page.mouse.move(
            first_box["x"] + first_box["width"] * 0.6,
            first_box["y"] + first_box["height"] * 0.6,
            steps=5,
        )
        assert not page.locator("#slimmingMarqueeSelection").evaluate(
            "element => element.classList.contains('hidden')"
        )
        page.mouse.up()
        assert page.locator("#slimmingMarqueeSelection").is_hidden()
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 1

        selected_ids_before_context = page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all("cards => cards.map(card => card.dataset.slimmingMemberId)")
        second_slimming_main.click(button="right")
        slimming_context_menu.wait_for()
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selected_ids_before_context
        single_favorite_recycle_action = slimming_context_menu.locator(
            '[data-slimming-member-context-action="recoverableRecycle"]'
        )
        assert "(0)" in single_favorite_recycle_action.inner_text()
        assert single_favorite_recycle_action.is_disabled()
        page.keyboard.press("Escape")

        selection_before_layout = page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all("cards => cards.map(card => card.dataset.slimmingMemberId)")
        slimming_scroll_before_layout = page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        )
        slimming_member_width_before_navigator = page.locator(
            "#slimmingMemberGrid"
        ).evaluate("element => element.getBoundingClientRect().width")
        slimming_navigator_button = page.locator("#slimmingNavigatorButton")
        assert slimming_navigator_button.get_attribute("aria-pressed") == "true"
        slimming_navigator_metrics = page.evaluate(
            """() => {
              const navigator = document.querySelector('#slimmingNavigatorPane');
              const jobs = navigator.querySelector('.slimming-job-pane');
              const clusters = navigator.querySelector('.slimming-cluster-pane');
              const navRect = navigator.getBoundingClientRect();
              const jobRect = jobs.getBoundingClientRect();
              const clusterRect = clusters.getBoundingClientRect();
              const scopeRects = [...document.querySelectorAll(
                '#slimmingClusterScopes [data-slimming-cluster-scope]'
              )].map(button => {
                const rect = button.getBoundingClientRect();
                return { x: rect.x, top: rect.top, bottom: rect.bottom, width: rect.width };
              });
              return {
                width: navRect.width,
                jobX: jobRect.x,
                jobWidth: jobRect.width,
                clusterX: clusterRect.x,
                clusterWidth: clusterRect.width,
                scopeRects,
                bodyColumns: getComputedStyle(document.querySelector('#slimmingAnalysisBody'))
                  .gridTemplateColumns,
              };
            }"""
        )
        assert 196 <= slimming_navigator_metrics["width"] <= 244, slimming_navigator_metrics
        assert abs(
            slimming_navigator_metrics["jobX"] - slimming_navigator_metrics["clusterX"]
        ) < 1, slimming_navigator_metrics
        assert abs(
            slimming_navigator_metrics["jobWidth"]
            - slimming_navigator_metrics["clusterWidth"]
        ) < 1, slimming_navigator_metrics
        assert len(slimming_navigator_metrics["bodyColumns"].split()) == 2, (
            slimming_navigator_metrics
        )
        assert len(slimming_navigator_metrics["scopeRects"]) == 3
        assert all(
            abs(rect["x"] - slimming_navigator_metrics["scopeRects"][0]["x"]) < 1
            and abs(rect["width"] - slimming_navigator_metrics["scopeRects"][0]["width"]) < 1
            for rect in slimming_navigator_metrics["scopeRects"]
        ), slimming_navigator_metrics
        assert all(
            current["top"] >= previous["bottom"]
            for previous, current in zip(
                slimming_navigator_metrics["scopeRects"],
                slimming_navigator_metrics["scopeRects"][1:],
            )
        ), slimming_navigator_metrics
        assert page.locator("#slimmingClusterScopeTitle").inner_text() == "待处理"
        page.screenshot(path="/tmp/imageall-slimming-single-navigator.png", full_page=True)
        slimming_inspector = page.locator("#slimmingInspector")
        assert slimming_inspector.get_attribute("open") is None
        assert slimming_inspector.is_hidden()
        grid_geometry_before_inspector = page.locator("#slimmingMemberGrid").evaluate(
            "element => { const rect = element.getBoundingClientRect(); "
            "return { top: rect.top, height: rect.height, scrollTop: element.scrollTop }; }"
        )
        selection_before_inspector = page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all("cards => cards.map(card => card.dataset.slimmingMemberId)")
        assert page.locator("#inspectorSlimmingWorkspace").is_visible()
        assert page.locator("#inspectorSlimmingWorkspaceContent").is_visible()
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => { const rect = element.getBoundingClientRect(); "
            "return { top: rect.top, height: rect.height, scrollTop: element.scrollTop }; }"
        ) == grid_geometry_before_inspector
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selection_before_inspector
        page.screenshot(path="/tmp/imageall-slimming-inspector-column.png", full_page=True)
        slimming_navigator_button.click()
        assert page.locator("#slimmingAnalysisBody").evaluate(
            "element => element.classList.contains('navigator-hidden')"
        )
        assert page.locator("#slimmingAnalysisBody > #slimmingNavigatorPane").is_hidden()
        assert page.locator("#slimmingNavigatorPane > .slimming-job-pane").is_hidden()
        assert page.locator("#slimmingNavigatorPane > .slimming-cluster-pane").is_hidden()
        assert slimming_navigator_button.get_attribute("aria-label") == "显示分析记录"
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.getBoundingClientRect().width"
        ) > slimming_member_width_before_navigator
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selection_before_layout
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        ) == slimming_scroll_before_layout
        assert page.evaluate(
            "() => document.activeElement?.id === 'slimmingNavigatorButton'"
        )
        slimming_navigator_button.click()
        assert slimming_navigator_button.get_attribute("aria-pressed") == "true"
        assert page.locator("#slimmingAnalysisBody > #slimmingNavigatorPane").is_visible()
        assert page.locator("#slimmingNavigatorPane > .slimming-job-pane").is_visible()
        assert page.locator("#slimmingNavigatorPane > .slimming-cluster-pane").is_visible()
        slimming_density_metrics = page.locator("#slimmingGridDensityButton").evaluate(
            "element => ({ width: element.offsetWidth, height: element.offsetHeight, "
            "display: getComputedStyle(element).display, "
            "computedWidth: getComputedStyle(element).width, "
            "minWidth: getComputedStyle(element).minWidth, "
            "visibility: getComputedStyle(element).visibility, "
            "parentDisplay: getComputedStyle(element.parentElement).display, "
            "parentWidth: element.parentElement.offsetWidth, "
            "controlsWidth: element.closest('#slimmingThumbnailLayoutControls')?.offsetWidth, "
            "workspaceWidth: document.querySelector('#slimmingWorkspace')?.offsetWidth, "
            "controls: element.closest('#slimmingThumbnailLayoutControls')?.className })"
        )
        assert slimming_density_metrics["width"] > 0, slimming_density_metrics
        assert slimming_density_metrics["height"] > 0, slimming_density_metrics
        page.locator("#slimmingGridDensityButton").click()
        page.locator("#slimmingGridDensityPopover:not(.hidden)").wait_for()
        slimming_density_history = page.evaluate(
            """() => {
              const entry = history.state?.imageAllWorkspace;
              return {
                route: entry?.route,
                navigationLevel: entry?.navigationLevel,
                baseLevel: entry?.context?.layoutMenuBaseLevel,
                kind: entry?.context?.layoutMenuKind,
                serialized: JSON.stringify(entry),
              };
            }"""
        )
        assert slimming_density_history["route"] == "slimming"
        assert slimming_density_history["navigationLevel"] == "layoutMenu"
        assert slimming_density_history["baseLevel"] == "workspace"
        assert slimming_density_history["kind"] == "slimmingGridDensity"
        assert "layoutMenuFocusedValue" not in slimming_density_history["serialized"]
        assert "layoutMenuReturnFocus" not in slimming_density_history["serialized"]
        page.evaluate("() => history.back()")
        page.locator("#slimmingGridDensityPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingGridDensityButton'"
        )
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selection_before_layout
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        ) == slimming_scroll_before_layout
        page.evaluate("() => history.forward()")
        page.locator("#slimmingGridDensityPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.gridDensity === '3'"
        )
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        page.locator(
            '#slimmingGridDensityPopover:not(.hidden) [data-grid-density="8"]'
        ).click()
        page.locator("#slimmingGridDensityPopover").wait_for(state="hidden")
        assert page.locator("#gridDensityButton").get_attribute("aria-label") \
            == "缩略图大小：巨大"
        assert page.evaluate(
            "() => getComputedStyle(document.documentElement)"
            ".getPropertyValue('--slimming-member-min-width').trim() === '620px'"
        )
        page.locator("#slimmingGridDensityButton").click()
        page.locator(
            '#slimmingGridDensityPopover:not(.hidden) [data-grid-density="3"]'
        ).click()
        assert page.evaluate(
            "() => getComputedStyle(document.documentElement)"
            ".getPropertyValue('--slimming-member-min-width').trim() === '132px'"
        )
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selection_before_layout
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        ) == slimming_scroll_before_layout

        removal_count_before_cancel = len(submitted_slimming_removals)
        page.keyboard.press("Delete")
        page.wait_for_timeout(200)
        assert page.locator("#confirmDialog").get_attribute("open") is None
        assert len(submitted_slimming_removals) == removal_count_before_cancel
        page.keyboard.press("Meta+K")
        with page.expect_response("**/v1/favorites"):
            page.locator('[data-command-id="unfavoriteSelection"]').click()
        page.wait_for_function(
            "() => [...state.slimming.selectedMemberIDs].every("
            "id => favoriteStateForAssetID(id)?.isFavorite === false)"
        )
        page.keyboard.press("Delete")
        page.locator("#confirmDialog[open]").wait_for()
        assert page.locator("#confirmDialog").get_attribute("data-tone") == "danger"
        assert "立即处理选中的" in page.locator("#confirmDialogTitle").inner_text()
        page.locator("#cancelConfirmButton").click()
        assert len(submitted_slimming_removals) == removal_count_before_cancel
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selection_before_layout
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        ) == slimming_scroll_before_layout

        page.set_viewport_size({"width": 390, "height": 844})
        page.keyboard.press("Delete")
        page.locator("#confirmDialog[open]").wait_for()
        confirmation_bounds = page.locator("#confirmDialog").bounding_box()
        assert confirmation_bounds is not None
        assert confirmation_bounds["x"] >= 0, confirmation_bounds
        assert confirmation_bounds["x"] + confirmation_bounds["width"] <= 390, (
            confirmation_bounds
        )
        for selector in ["#cancelConfirmButton", "#confirmActionButton"]:
            bounds = page.locator(selector).bounding_box()
            assert bounds is not None
            assert bounds["x"] >= confirmation_bounds["x"], bounds
            assert bounds["x"] + bounds["width"] <= (
                confirmation_bounds["x"] + confirmation_bounds["width"]
            ), bounds
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        page.screenshot(path="/tmp/imageall-confirmation-dialog-390.png", full_page=True)
        page.locator("#cancelConfirmButton").click()
        page.set_viewport_size({"width": 1440, "height": 960})

        page.locator("#slimmingThumbnailAspectButton").click()
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.classList.contains('original-aspect')"
        )
        for selector in [
            "#thumbnailAspectButton",
            "#reviewThumbnailAspectButton",
            "#slimmingThumbnailAspectButton",
        ]:
            control = page.locator(selector)
            assert control.get_attribute("data-aspect-mode") == "original"
            assert control.get_attribute("aria-label") == "缩略图比例：原比例"
            assert control.locator(".thumbnail-aspect-label").text_content() == "原比例"
            assert control.get_attribute("aria-pressed") is None
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selection_before_layout
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        ) == slimming_scroll_before_layout

        page.evaluate(
            "assetID => openLightbox('slimming', assetID)",
            SLIMMING_ASSET_IDS[1],
        )
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert page.locator("#lightboxZoomControls").is_visible()
        assert page.locator("#lightboxDeleteButton").is_visible()
        page.set_viewport_size({"width": 390, "height": 844})
        preview_action_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth, "
            "toolbarRight: document.querySelector('.lightbox-toolbar-actions')"
            ".getBoundingClientRect().right, deleteWidth: "
            "document.querySelector('#lightboxDeleteButton').getBoundingClientRect().width, "
            "deleteLabelDisplay: getComputedStyle("
            "document.querySelector('#lightboxDeleteButton > span:last-child')).display })"
        )
        assert preview_action_dimensions["scroll"] <= preview_action_dimensions["viewport"], (
            preview_action_dimensions
        )
        assert preview_action_dimensions["toolbarRight"] <= preview_action_dimensions["viewport"], (
            preview_action_dimensions
        )
        assert preview_action_dimensions["deleteWidth"] == 32, preview_action_dimensions
        assert preview_action_dimensions["deleteLabelDisplay"] == "none", preview_action_dimensions
        page.screenshot(path="/tmp/imageall-slimming-preview-actions-390.png", full_page=True)
        page.keyboard.press("Escape")
        assert page.locator("#lightbox").is_hidden()
        page.set_viewport_size({"width": 1440, "height": 960})

        slimming_cluster_before_refresh = page.evaluate(
            "() => state.slimming.selectedClusterID"
        )
        page.evaluate(
            "assetID => openLightbox('slimming', assetID)",
            SLIMMING_ASSET_IDS[1],
        )
        page.locator("#lightbox:not(.hidden)").wait_for()
        slimming_preview_before_refresh = page.evaluate(
            """() => {
              setLightboxScale(1.8);
              state.lightboxViewportOffsetX = 30;
              state.lightboxViewportOffsetY = -20;
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
            "assetID => history.state?.imageAllWorkspace?.context?.slimmingLightbox?.assetID === assetID",
            arg=SLIMMING_ASSET_IDS[1],
            timeout=2_500,
        )
        page.reload(wait_until="networkidle")
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        page.locator("#lightbox:not(.hidden)").wait_for()
        page.wait_for_function(
            "expected => document.querySelector('#lightboxTitle')?.textContent.includes('SLIM_0002') "
            "&& state.lightboxViewportScale === expected.scale "
            "&& state.lightboxViewportOffsetX === expected.offsetX "
            "&& state.lightboxViewportOffsetY === expected.offsetY",
            arg=slimming_preview_before_refresh,
        )
        assert page.evaluate("() => visibleWorkspaceRoute()") == "slimming"
        assert page.locator("#lightboxBackLabel").inner_text() == "返回分析"
        assert page.evaluate(
            "() => state.slimming.selectedClusterID"
        ) == slimming_cluster_before_refresh
        history_after_slimming_preview_refresh = page.evaluate(
            "() => JSON.stringify(history.state)"
        )
        assert "SLIM_0002" not in history_after_slimming_preview_refresh
        assert "/v1/assets/" not in history_after_slimming_preview_refresh
        page.screenshot(path="/tmp/imageall-slimming-preview-refresh-continuity.png", full_page=True)
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")

        page.locator('[data-slimming-media-kind="video"]').click()
        page.locator("#slimmingMemberGrid .slimming-member-video-badge").first.wait_for()
        assert page.locator("#slimmingMemberGrid .slimming-member-video-badge").count() == 3
        assert "0:12" in page.locator("#slimmingMemberGrid .slimming-member-video-badge").first.inner_text()
        page.screenshot(path="/tmp/imageall-slimming-analysis-favorites.png", full_page=True)
        video_cards = page.locator("#slimmingMemberGrid > .slimming-member-card")
        video_cards.nth(0).locator(":scope > .slimming-member-main").click()
        video_cards.nth(1).locator(":scope > .slimming-member-main").click(modifiers=["Shift"])
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        page.evaluate(
            "assetID => openLightbox('slimming', assetID)",
            SLIMMING_ASSET_IDS[1],
        )
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "SLIM_0002" in page.locator("#lightboxTitle").inner_text()
        lightbox_delete = page.locator("#lightboxDeleteButton")
        assert lightbox_delete.is_visible()
        assert lightbox_delete.is_disabled()
        assert "红心保护" in lightbox_delete.get_attribute("aria-label")
        with page.expect_response("**/v1/favorites"):
            page.locator("#lightboxFavoriteButton").click()
        page.wait_for_function(
            "id => favoriteStateForAssetID(id)?.isFavorite === false",
            arg=SLIMMING_ASSET_IDS[1],
        )
        page.wait_for_function(
            "() => !document.querySelector('#lightboxDeleteButton').disabled"
        )
        assert lightbox_delete.is_enabled()
        assert "SLIM_0002" in lightbox_delete.get_attribute("aria-label")
        preview_removal_count_before_cancel = len(submitted_slimming_removals)
        lightbox_delete.click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "当前预览" in page.locator("#confirmDialogTitle").inner_text()
        page.locator("#cancelConfirmButton").click()
        assert len(submitted_slimming_removals) == preview_removal_count_before_cancel
        page.keyboard.press("Delete")
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#cancelConfirmButton").click()
        assert len(submitted_slimming_removals) == preview_removal_count_before_cancel
        assert page.locator("#lightbox").is_visible()
        assert "SLIM_0002" in page.locator("#lightboxTitle").inner_text()
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        lightbox_delete.click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#confirmActionButton").click()
        page.locator("#slimmingMemberGrid .slimming-member-pending-overlay").wait_for()
        assert submitted_slimming_removals[-1]["assetIDs"] == [SLIMMING_ASSET_IDS[1]]
        assert submitted_slimming_removals[-1]["mode"] == "releaseSourceSpace"
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        pending_favorite = video_cards.nth(1).locator(":scope > .slimming-member-favorite")
        assert pending_favorite.is_disabled()
        assert "等待 Mac 确认回收" in pending_favorite.get_attribute("title")
        assert "等待 Mac 确认" in page.locator(
            "#slimmingMemberGrid .slimming-member-pending-overlay"
        ).inner_text()
        hidden_slimming_asset_ids.add(SLIMMING_ASSET_IDS[1])
        active_slimming_removal["phase"] = "completed"
        active_slimming_removal["audit"] = {
            "hiddenAssetIDs": [SLIMMING_ASSET_IDS[1]],
            "failedAssetIDs": [],
            "authorizationRequiredAssetIDs": [],
            "authorizationDeniedPhotosAssetIDs": [],
        }
        active_slimming_removal["message"] = "已安全完成"
        active_slimming_removal["updatedAtMs"] += 1
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle')?.textContent.includes('SLIM_0003')",
            timeout=5_000,
        )
        assert page.locator("#lightbox").is_visible()
        assert page.locator("#lightboxPosition").inner_text() == "2 / 2"
        assert page.locator(
            f'#slimmingMemberGrid [data-slimming-member-id="{SLIMMING_ASSET_IDS[2]}"]'
        ).evaluate("element => element.classList.contains('selected')")
        page.screenshot(path="/tmp/imageall-slimming-preview-delete-replacement.png", full_page=True)
        page.keyboard.press("Escape")
        assert page.locator("#lightbox").is_hidden()

        page.locator('[data-slimming-view="recycle"]').click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 7"
        )
        recycle_scope_buttons = page.locator(
            "#slimmingRecycleScopes [data-slimming-recycle-scope]"
        )
        assert recycle_scope_buttons.count() == 4
        assert page.locator(
            '[data-slimming-recycle-scope-count="all"]'
        ).inner_text() == "7"
        assert page.locator(
            '[data-slimming-recycle-scope-count="photos"]'
        ).inner_text() == "3"
        assert page.locator(
            '[data-slimming-recycle-scope-count="files"]'
        ).inner_text() == "4"
        assert page.locator(
            '[data-slimming-recycle-scope-count="attention"]'
        ).inner_text() == "6"
        assert page.locator("#slimmingRecycleSummary").inner_text() == (
            "当前 7 个视频项目，其中 6 项需要关注"
        )
        assert page.locator("#slimmingRecycleSourceBanner").is_hidden()
        recycle_card_layout = page.locator(
            "#slimmingRecycleList .slimming-recycle-row"
        ).evaluate_all(
            "cards => cards.slice(0, 2).map(card => { "
            "const rect = card.getBoundingClientRect(); "
            "return { x: rect.x, y: rect.y, width: rect.width, height: rect.height }; })"
        )
        assert len(recycle_card_layout) == 2
        assert all(380 <= card["width"] <= 640 for card in recycle_card_layout), (
            recycle_card_layout
        )
        assert abs(recycle_card_layout[0]["y"] - recycle_card_layout[1]["y"]) < 1, (
            recycle_card_layout
        )
        assert recycle_card_layout[1]["x"] > recycle_card_layout[0]["x"]
        assert page.locator(
            "#slimmingRecycleList .slimming-recycle-row"
        ).first.locator(":scope > .slimming-recycle-policy").count() == 1
        page.screenshot(path="/tmp/imageall-slimming-recycle-mac-layout.png", full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        mobile_recycle_layout = page.evaluate(
            """() => {
              const cards = [...document.querySelectorAll(
                '#slimmingRecycleList .slimming-recycle-row'
              )].slice(0, 2).map(card => {
                const rect = card.getBoundingClientRect();
                return { x: rect.x, y: rect.y, right: rect.right, width: rect.width };
              });
              const header = document.querySelector('.slimming-recycle-header')
                .getBoundingClientRect();
              return {
                viewport: innerWidth,
                scrollWidth: document.documentElement.scrollWidth,
                headerLeft: header.left,
                headerRight: header.right,
                cards,
              };
            }"""
        )
        assert mobile_recycle_layout["scrollWidth"] <= mobile_recycle_layout["viewport"], (
            mobile_recycle_layout
        )
        assert mobile_recycle_layout["headerLeft"] >= 0
        assert mobile_recycle_layout["headerRight"] <= mobile_recycle_layout["viewport"]
        assert len(mobile_recycle_layout["cards"]) == 2
        assert abs(
            mobile_recycle_layout["cards"][0]["x"]
            - mobile_recycle_layout["cards"][1]["x"]
        ) < 1
        assert mobile_recycle_layout["cards"][1]["y"] > mobile_recycle_layout["cards"][0]["y"]
        page.screenshot(path="/tmp/imageall-slimming-recycle-mac-layout-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_timeout(100)

        recycle_query_continuity_before = page.evaluate(
            """() => {
              const row = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              const originalFetch = window.fetch.bind(window);
              window.__imageAllRecycleQueryRow = row;
              window.__imageAllRecycleQueryThumbnail = row.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              window.__imageAllRecycleQueryRelease = null;
              window.fetch = (...args) => {
                const requestURL = String(args[0]?.url || args[0]);
                if (requestURL.includes('/v1/library-slimming/recycle?')
                    && requestURL.includes('search=RECYCLE')) {
                  return new Promise((resolve, reject) => {
                    window.__imageAllRecycleQueryRelease = () => {
                      window.fetch = originalFetch;
                      originalFetch(...args).then(resolve, reject);
                    };
                  });
                }
                return originalFetch(...args);
              };
              return {
                rowID: row.dataset.slimmingRecycleRowId,
                scrollTop: document.querySelector('#slimmingRecycleBody').scrollTop,
              };
            }"""
        )
        page.locator("#slimmingRecycleSearchInput").fill("RECYCLE")
        page.wait_for_function(
            "() => state.slimming.recycle.loading "
            "&& typeof window.__imageAllRecycleQueryRelease === 'function'"
        )
        assert page.evaluate(
            """expected => {
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.rowID)}"]`
              );
              return row === window.__imageAllRecycleQueryRow
                && row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleQueryThumbnail
                && document.querySelector('#slimmingRecycleBody').scrollTop
                  === expected.scrollTop
                && document.activeElement?.id === 'slimmingRecycleSearchInput';
            }""",
            recycle_query_continuity_before,
        )
        page.evaluate("() => window.__imageAllRecycleQueryRelease()")
        page.wait_for_function("() => !state.slimming.recycle.loading")
        assert page.evaluate(
            """expected => {
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.rowID)}"]`
              );
              return row === window.__imageAllRecycleQueryRow
                && row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleQueryThumbnail
                && document.activeElement?.id === 'slimmingRecycleSearchInput';
            }""",
            recycle_query_continuity_before,
        )

        slimming_recycle_query_failures[0] = 1
        recycle_failed_media_query_count = len(recycle_request_urls)
        image_media_tab = page.locator('[data-slimming-media-kind="image"]')
        image_media_tab.click()
        page.wait_for_function("() => !state.slimming.recycle.loading")
        page.wait_for_function(
            "() => document.querySelector('#toast')?.textContent.includes('模拟回收筛选失败')"
        )
        assert len(recycle_request_urls) == recycle_failed_media_query_count + 1
        assert page.evaluate("() => state.slimming.mediaKind") == "video"
        assert page.locator(
            '[data-slimming-media-kind="video"]'
        ).get_attribute("aria-pressed") == "true"
        assert page.evaluate(
            """expected => {
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.rowID)}"]`
              );
              return row === window.__imageAllRecycleQueryRow
                && row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleQueryThumbnail
                && document.activeElement?.dataset.slimmingMediaKind === 'image';
            }""",
            recycle_query_continuity_before,
        )

        slimming_recycle_query_failures[0] = 1
        recycle_failed_query_count = len(recycle_request_urls)
        page.locator("#slimmingRecycleSourceSelect").focus()
        page.locator("#slimmingRecycleSourceSelect").select_option(SOURCE_ID)
        page.wait_for_function("() => !state.slimming.recycle.loading")
        page.wait_for_function(
            "() => document.querySelector('#toast')?.textContent.includes('模拟回收筛选失败')"
        )
        assert len(recycle_request_urls) == recycle_failed_query_count + 1
        assert page.locator("#slimmingRecycleSourceSelect").input_value() == ""
        assert page.locator("#slimmingRecycleSourceBanner").is_hidden()
        assert page.locator("#slimmingRecycleSearchInput").input_value() == "RECYCLE"
        recycle_failed_query_after = page.evaluate(
            """expected => {
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.rowID)}"]`
              );
              return {
                rowStable: row === window.__imageAllRecycleQueryRow,
                thumbnailStable: row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleQueryThumbnail,
                focusedControlID: document.activeElement?.id || null,
              };
            }""",
            recycle_query_continuity_before,
        )
        assert recycle_failed_query_after == {
            "rowStable": True,
            "thumbnailStable": True,
            "focusedControlID": "slimmingRecycleSourceSelect",
        }, recycle_failed_query_after

        recycle_combined_query_count = len(recycle_request_urls)
        page.locator("#slimmingRecycleSearchInput").fill("RECYCLE_0001")
        page.locator("#slimmingRecycleSourceSelect").focus()
        page.locator("#slimmingRecycleSourceSelect").select_option(SOURCE_ID)
        page.wait_for_function("() => !state.slimming.recycle.loading")
        page.wait_for_timeout(300)
        assert len(recycle_request_urls) == recycle_combined_query_count + 1
        assert "search=RECYCLE_0001" in recycle_request_urls[-1]
        assert f"sourceID={SOURCE_ID}" in recycle_request_urls[-1]
        assert page.locator(
            "#slimmingRecycleList .slimming-recycle-row"
        ).count() == 1

        page.locator("#slimmingRecycleSearchInput").fill("RECYCLE")
        page.wait_for_timeout(300)
        attention_scope = page.locator('[data-slimming-recycle-scope="attention"]')
        attention_scope.click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 2"
        )
        assert page.locator(
            "#slimmingRecycleList .slimming-recycle-row",
            has_text="RECYCLE_0005",
        ).count() == 1
        assert page.locator("#slimmingRecycleSourceSelect").input_value() == SOURCE_ID
        assert page.locator("#slimmingRecycleSearchInput").input_value() == "RECYCLE"
        assert page.locator("#slimmingRecycleSourceBanner").is_visible()
        assert page.locator("#slimmingRecycleSourceBannerName").inner_text() == (
            page.locator("#slimmingRecycleSourceSelect option:checked").inner_text()
        )
        assert page.locator("#clearSlimmingRecycleSearchButton").is_visible()
        assert page.locator("#slimmingRecycleSearchResultCount").inner_text() == "2"
        assert any(
            "scope=attention" in url
            and f"sourceID={SOURCE_ID}" in url
            and "search=RECYCLE" in url
            for url in recycle_request_urls
        )
        page.locator("#toast").wait_for(state="hidden", timeout=5_000)
        page.screenshot(
            path="/tmp/imageall-slimming-recycle-query-continuity.png",
            full_page=False,
        )

        recycle_escape_requests = len(recycle_request_urls)
        page.locator("#slimmingRecycleSearchInput").press("Escape")
        page.wait_for_function("() => !state.slimming.recycle.loading")
        assert page.locator("#slimmingRecycleSearchInput").input_value() == ""
        assert page.evaluate("() => state.slimming.recycle.searchText") == ""
        assert page.evaluate("() => document.activeElement?.id") == "slimmingRecycleSearchInput"
        assert page.locator("#slimmingWorkspace").is_visible()
        assert page.locator("#slimmingRecycleSourceSelect").input_value() == SOURCE_ID
        assert len(recycle_request_urls) == recycle_escape_requests + 1
        assert "search=" not in recycle_request_urls[-1]
        page.locator("#slimmingRecycleSearchInput").fill("RECYCLE")
        page.wait_for_timeout(300)

        photos_scope = page.locator('[data-slimming-recycle-scope="photos"]')
        photos_scope.click()
        page.wait_for_function(
            "() => document.querySelector('#slimmingRecycleList .slimming-recycle-row')"
            "?.innerText.includes('RECYCLE_0001')"
        )
        photos_scope.press("ArrowRight")
        page.wait_for_function(
            "() => document.querySelector('[data-slimming-recycle-scope="
            "\"files\"]')?.getAttribute('aria-pressed') === 'true'"
        )
        page.keyboard.press("End")
        page.wait_for_function(
            "() => document.querySelector('[data-slimming-recycle-scope="
            "\"attention\"]')?.getAttribute('aria-pressed') === 'true'"
        )
        page.keyboard.press("Home")
        page.wait_for_function(
            "() => document.querySelector('[data-slimming-recycle-scope="
            "\"all\"]')?.getAttribute('aria-pressed') === 'true'"
        )
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 3"
        )
        page.locator("#clearSlimmingRecycleSearchButton").click()
        page.wait_for_function("() => !state.slimming.recycle.loading")
        assert page.locator("#slimmingRecycleSearchInput").input_value() == ""
        assert page.evaluate(
            "() => document.activeElement?.id === 'slimmingRecycleSearchInput'"
        )
        page.locator("#clearSlimmingRecycleSourceButton").click()
        page.wait_for_function("() => !state.slimming.recycle.loading")
        assert page.locator("#slimmingRecycleSourceSelect").input_value() == ""
        assert page.locator("#slimmingRecycleSourceBanner").is_hidden()
        assert page.evaluate(
            "() => document.activeElement?.id === 'slimmingRecycleSourceSelect'"
        )
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 7"
        )

        page.locator("#slimmingRecycleSearchInput").fill("NO_MATCH")
        page.locator("#slimmingRecycleEmpty:not(.hidden)").wait_for()
        assert page.locator("#slimmingRecycleEmptyTitle").inner_text() == "没有匹配的媒体"
        assert "NO_MATCH" in page.locator("#slimmingRecycleEmptyMessage").inner_text()
        assert page.locator("#slimmingRecycleEmptyAction").inner_text() == "清除搜索"
        page.locator("#slimmingRecycleEmptyAction").click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 7"
        )
        assert page.locator("#slimmingRecycleSearchInput").input_value() == ""
        assert page.evaluate(
            "() => document.activeElement?.id === 'slimmingRecycleSearchInput'"
        )

        assert page.locator("#slimmingRecycleList .slimming-recycle-video-badge").count() == 7
        assert page.locator("#slimmingRecycleList").evaluate(
            "element => element.classList.contains('original-aspect')"
        )
        assert page.locator("#slimmingThumbnailLayoutControls").evaluate(
            "element => element.classList.contains('recycle-view')"
        )
        recycle_rows = page.locator("#slimmingRecycleList .slimming-recycle-row")
        recycle_thumbnail = recycle_rows.nth(0).locator(
            ".slimming-recycle-thumbnail-card"
        )
        recycle_favorite = recycle_rows.nth(0).locator(".slimming-recycle-favorite")
        first_recycle_buttons = recycle_rows.nth(0).locator("button")
        second_recycle_thumbnail = recycle_rows.nth(1).locator(
            ".slimming-recycle-thumbnail-card"
        )
        recycle_countdown_copy = page.evaluate(
            """() => {
              const originalNow = Date.now;
              Date.now = () => 1_700_000_000_000;
              try {
                return {
                  photosDays: slimmingRecycleCountdown({
                    sourceKind: 'photos',
                    purgeAfterMs: 1_700_000_000_000 + 3 * 24 * 60 * 60 * 1_000,
                  }),
                  photosExpired: slimmingRecycleCountdown({
                    sourceKind: 'photos',
                    purgeAfterMs: 1_699_999_999_999,
                  }),
                  folderHours: slimmingRecycleCountdown({
                    sourceKind: 'file',
                    purgeAfterMs: 1_700_000_000_000 + 5 * 60 * 60 * 1_000,
                  }),
                  photosPolicy: slimmingRecyclePolicyCopy({
                    sourceKind: 'photos',
                    state: 'recycled',
                  }),
                  folderPolicy: slimmingRecyclePolicyCopy({
                    sourceKind: 'file',
                    state: 'recycled',
                  }),
                  restoredState: slimmingRecycleStateCopy({ state: 'restored' }),
                  purgedState: slimmingRecycleStateCopy({ state: 'purged' }),
                };
              } finally {
                Date.now = originalNow;
              }
            }"""
        )
        assert recycle_countdown_copy == {
            "photosDays": "ImageAll 将在 3 天后清理此记录",
            "photosExpired": "ImageAll 即将清理此记录",
            "folderHours": "5 小时后永久删除",
            "photosPolicy": "恢复与永久删除由“照片”App 管理",
            "folderPolicy": "可恢复到原位置",
            "restoredState": "媒体已经恢复",
            "purgedState": "媒体已经永久清理",
        }
        first_recycle_meta = recycle_rows.nth(0).locator(".slimming-recycle-meta")
        first_recycle_detail = recycle_rows.nth(0).locator(".slimming-recycle-detail")
        assert "Apple Photos · Apple Photos" not in first_recycle_meta.inner_text()
        assert "移入" in first_recycle_meta.inner_text()
        assert "ImageAll 将在" in first_recycle_detail.inner_text()
        assert "清理此记录" in first_recycle_detail.inner_text()
        assert first_recycle_detail.locator(".slimming-recycle-detail-icon").inner_text() == "◷"
        assert "button-primary" in recycle_rows.nth(0).get_by_role(
            "button", name="恢复说明", exact=True
        ).get_attribute("class")
        second_recycle_detail = recycle_rows.nth(1).locator(".slimming-recycle-detail")
        assert "来源文件已变化" in second_recycle_detail.inner_text()
        assert second_recycle_detail.locator(".slimming-recycle-detail-icon").inner_text() == "!"
        assert "尝试处理" in recycle_rows.nth(1).locator(
            ".slimming-recycle-meta"
        ).inner_text()
        assert "button-primary" in recycle_rows.nth(1).get_by_role(
            "button", name="刷新来源", exact=True
        ).get_attribute("class")
        assert "button-primary" not in recycle_rows.nth(1).get_by_role(
            "button", name="说明", exact=True
        ).get_attribute("class")
        assert recycle_thumbnail.get_attribute("tabindex") == "0"
        assert all(
            first_recycle_buttons.nth(index).get_attribute("tabindex") == "0"
            for index in range(first_recycle_buttons.count())
        )
        assert second_recycle_thumbnail.get_attribute("tabindex") == "-1"
        second_recycle_buttons = recycle_rows.nth(1).locator("button")
        assert all(
            second_recycle_buttons.nth(index).get_attribute("tabindex") == "-1"
            for index in range(second_recycle_buttons.count())
        )
        recycle_keyboard_snapshot = {
            "requests": len(recycle_request_urls),
            "favorites": len(submitted_favorites),
            "actions": len(submitted_slimming_recycle_actions),
            "removals": len(submitted_slimming_removals),
        }
        recycle_thumbnail.focus()
        for _ in range(first_recycle_buttons.count()):
            page.keyboard.press("Tab")
            assert page.evaluate(
                "() => document.querySelector('#slimmingRecycleList .slimming-recycle-row')"
                ".contains(document.activeElement)"
            )
        page.keyboard.press("Tab")
        assert not page.evaluate(
            "() => document.querySelector('#slimmingRecycleList')"
            ".contains(document.activeElement)"
        )
        second_recycle_thumbnail.focus()
        assert page.evaluate(
            "id => state.slimming.recycle.focusEntryID === id "
            "&& document.querySelectorAll('#slimmingRecycleList "
            ".slimming-recycle-thumbnail-card[tabindex=\"0\"]')"
            ".length === 1",
            SLIMMING_RECYCLE_IDS[1],
        )
        page.keyboard.press("ArrowRight")
        assert page.evaluate(
            "id => state.slimming.recycle.focusEntryID === id "
            "&& document.activeElement?.dataset.slimmingRecycleThumbnailEntryId === id",
            SLIMMING_RECYCLE_IDS[2],
        )
        recycle_rows.nth(2).locator(".slimming-recycle-favorite").focus()
        page.keyboard.press("ArrowRight")
        assert page.evaluate(
            "id => state.slimming.recycle.focusEntryID === id "
            "&& document.activeElement?.dataset.slimmingRecycleThumbnailEntryId === id",
            SLIMMING_RECYCLE_IDS[3],
        )
        page.keyboard.press("Home")
        assert page.evaluate(
            "id => document.activeElement?.dataset.slimmingRecycleThumbnailEntryId === id",
            SLIMMING_RECYCLE_IDS[0],
        )
        recycle_page_step = page.evaluate(
            "() => renderedGridPageItemCount("
            "document.querySelector('#slimmingRecycleBody'), "
            "document.querySelector('#slimmingRecycleList'), "
            "':scope > .slimming-recycle-row')"
        )
        page.keyboard.press("PageDown")
        assert page.evaluate(
            "id => document.activeElement?.dataset.slimmingRecycleThumbnailEntryId === id",
            SLIMMING_RECYCLE_IDS[min(len(SLIMMING_RECYCLE_IDS) - 1, recycle_page_step)],
        )
        page.keyboard.press("End")
        assert page.evaluate(
            "id => document.activeElement?.dataset.slimmingRecycleThumbnailEntryId === id",
            SLIMMING_RECYCLE_IDS[-1],
        )
        page.keyboard.press("Home")
        assert page.evaluate(
            "id => state.slimming.recycle.focusEntryID === id "
            "&& document.activeElement?.dataset.slimmingRecycleThumbnailEntryId === id "
            "&& document.querySelectorAll('#slimmingRecycleList [tabindex=\"0\"]')"
            ".length === document.querySelectorAll("
            "'#slimmingRecycleList .slimming-recycle-row:first-child "
            ".slimming-recycle-thumbnail-card, "
            "#slimmingRecycleList .slimming-recycle-row:first-child button:not(:disabled)'"
            ").length",
            SLIMMING_RECYCLE_IDS[0],
        )
        assert recycle_keyboard_snapshot == {
            "requests": len(recycle_request_urls),
            "favorites": len(submitted_favorites),
            "actions": len(submitted_slimming_recycle_actions),
            "removals": len(submitted_slimming_removals),
        }
        recycle_poll_request_count = len(recycle_request_urls)
        recycle_poll_write_snapshot = {
            "favorites": len(submitted_favorites),
            "actions": len(submitted_slimming_recycle_actions),
            "sourceActions": len(submitted_source_management),
            "removals": len(submitted_slimming_removals),
        }
        recycle_poll_before = page.evaluate(
            """entryID => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(entryID)}"]`
              );
              const action = row.querySelector('[data-slimming-recycle-recovery-action]');
              body.scrollTop = Math.min(90, Math.max(0, body.scrollHeight - body.clientHeight));
              action.focus();
              window.__imageAllRecyclePollRow = row;
              window.__imageAllRecyclePollImage = row.querySelector('img');
              return {
                scrollTop: body.scrollTop,
                focusedAction: action.dataset.slimmingRecycleRecoveryAction,
              };
            }""",
            SLIMMING_RECYCLE_IDS[1],
        )
        assert page.evaluate("() => loadSlimmingRecycle({ quiet: true })") is True
        assert len(recycle_request_urls) == recycle_poll_request_count + 1
        assert page.evaluate(
            """expected => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.entryID)}"]`
              );
              return row === window.__imageAllRecyclePollRow
                && row.querySelector('img') === window.__imageAllRecyclePollImage
                && body.scrollTop === expected.scrollTop;
            }""",
            {
                "entryID": SLIMMING_RECYCLE_IDS[1],
                "scrollTop": recycle_poll_before["scrollTop"],
            },
        )
        assert page.evaluate(
            "entryID => document.activeElement?.closest('[data-slimming-recycle-row-id]')"
            "?.dataset.slimmingRecycleRowId === entryID "
            "&& document.activeElement?.dataset.slimmingRecycleRecoveryAction "
            "=== 'rescan'",
            SLIMMING_RECYCLE_IDS[1],
        )
        slimming_recycle_poll_revision = 1
        recycle_poll_changed_before = page.evaluate(
            """entryID => {
              const body = document.querySelector('#slimmingRecycleBody');
              const rows = document.querySelectorAll(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              const focusedRow = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(entryID)}"]`
              );
              const action = focusedRow.querySelector(
                '[data-slimming-recycle-recovery-action]'
              );
              action.focus();
              window.__imageAllRecycleChangedRow = rows[0];
              window.__imageAllRecycleChangedThumbnail = rows[0].querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              window.__imageAllRecycleFocusedRow = focusedRow;
              window.__imageAllRecycleFocusedThumbnail = focusedRow.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              return body.scrollTop;
            }""",
            SLIMMING_RECYCLE_IDS[1],
        )
        assert page.evaluate("() => loadSlimmingRecycle({ quiet: true })") is True
        assert "Mac 已更新" in recycle_rows.nth(0).locator(
            ".slimming-recycle-policy"
        ).inner_text()
        assert page.evaluate(
            """expected => {
              const body = document.querySelector('#slimmingRecycleBody');
              const changedRow = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.changedID)}"]`
              );
              const focusedRow = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.focusedID)}"]`
              );
              return changedRow === window.__imageAllRecycleChangedRow
                && changedRow.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleChangedThumbnail
                && focusedRow === window.__imageAllRecycleFocusedRow
                && focusedRow.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleFocusedThumbnail
                && body.scrollTop === expected.scrollTop;
            }""",
            {
                "changedID": SLIMMING_RECYCLE_IDS[0],
                "focusedID": SLIMMING_RECYCLE_IDS[1],
                "scrollTop": recycle_poll_changed_before,
            },
        )
        assert page.evaluate(
            "entryID => document.activeElement?.closest('[data-slimming-recycle-row-id]')"
            "?.dataset.slimmingRecycleRowId === entryID "
            "&& document.activeElement?.dataset.slimmingRecycleRecoveryAction "
            "=== 'rescan'",
            SLIMMING_RECYCLE_IDS[1],
        )
        slimming_recycle_poll_revision = 2
        page.evaluate(
            """entryID => {
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(entryID)}"]`
              );
              window.__imageAllRecycleFocusedChangedRow = row;
              window.__imageAllRecycleFocusedChangedThumbnail = row.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              row.querySelector('[data-slimming-recycle-recovery-action="rescan"]').focus();
            }""",
            SLIMMING_RECYCLE_IDS[1],
        )
        assert page.evaluate("() => loadSlimmingRecycle({ quiet: true })") is True
        assert "原位置与隔离区" in recycle_rows.nth(1).locator(
            ".slimming-recycle-detail"
        ).inner_text()
        assert recycle_rows.nth(1).locator(
            '[data-slimming-recycle-recovery-action="rescan"]'
        ).count() == 0
        assert recycle_rows.nth(1).get_by_role(
            "button", name="重新检查", exact=True
        ).count() == 1
        assert page.evaluate(
            """entryID => {
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(entryID)}"]`
              );
              return row === window.__imageAllRecycleFocusedChangedRow
                && row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleFocusedChangedThumbnail
                && document.activeElement
                  === row.querySelector('.slimming-recycle-thumbnail-card');
            }""",
            SLIMMING_RECYCLE_IDS[1],
        )
        slimming_recycle_poll_revision = 3
        page.evaluate(
            """() => {
              window.__imageAllRecycleStructureRow = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
            }"""
        )
        assert page.evaluate("() => loadSlimmingRecycle({ quiet: true })") is True
        assert page.locator(
            f'[data-slimming-recycle-row-id="{SLIMMING_RECYCLE_IDS[1]}"]'
        ).count() == 0
        assert page.evaluate(
            """firstID => {
              const firstRow = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              return firstRow !== window.__imageAllRecycleStructureRow
                && firstRow.dataset.slimmingRecycleRowId === firstID
                && document.activeElement
                  === firstRow.querySelector('.slimming-recycle-thumbnail-card');
            }""",
            SLIMMING_RECYCLE_IDS[0],
        )
        slimming_recycle_poll_revision = 0
        assert page.evaluate("() => loadSlimmingRecycle({ quiet: true })") is True
        assert recycle_poll_write_snapshot == {
            "favorites": len(submitted_favorites),
            "actions": len(submitted_slimming_recycle_actions),
            "sourceActions": len(submitted_source_management),
            "removals": len(submitted_slimming_removals),
        }
        page.screenshot(
            path="/tmp/imageall-slimming-recycle-roving-focus.png",
            full_page=False,
        )
        recycle_rows.nth(0).hover()
        assert recycle_favorite.is_visible()
        assert "不会暂停系统“照片”的永久删除" in recycle_favorite.get_attribute("title")
        recycle_before = recycle_favorite.get_attribute("data-favorite")
        recycle_scroll_before = page.locator("#slimmingRecycleBody").evaluate(
            "element => element.scrollTop"
        )
        recycle_context_snapshot = page.evaluate(
            """() => ({
              scope: state.slimming.recycle.scope,
              sourceID: state.slimming.recycle.sourceID,
              searchText: state.slimming.recycle.searchText,
              entryIDs: state.slimming.recycle.entries.map(entry => entry.id),
              scrollTop: document.querySelector('#slimmingRecycleBody').scrollTop,
            })"""
        )
        recycle_context_favorite_count = len(submitted_favorites)
        recycle_context_action_count = len(submitted_slimming_recycle_actions)
        recycle_context_removal_count = len(submitted_slimming_removals)
        recycle_context_menu = page.locator("#slimmingRecycleContextMenu:not(.hidden)")
        recycle_context_action = page.locator("#slimmingRecycleFavoriteContextAction")

        recycle_thumbnail.click(button="right")
        recycle_context_menu.wait_for()
        assert page.locator("#slimmingRecycleContextMenuTitle").inner_text() == "RECYCLE_0001.MOV"
        assert page.locator("#slimmingRecycleContextMenuNote").is_visible()
        assert page.locator("#slimmingRecycleContextMenuNote").inner_text() == (
            "Apple Photos 的“最近删除”由系统管理，红心不能暂停系统永久删除。"
        )
        assert recycle_context_action.get_attribute("data-favorite") == recycle_before
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingRecycleFavoriteContextAction'"
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.contextMenuKind"
        ) == "slimmingRecycle"
        page.evaluate("() => history.back()")
        recycle_context_menu.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('slimming-recycle-thumbnail-card')"
        )
        page.evaluate("() => history.forward()")
        recycle_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingRecycleFavoriteContextAction'"
        )
        assert page.evaluate(
            "() => ({ scope: state.slimming.recycle.scope, "
            "sourceID: state.slimming.recycle.sourceID, "
            "searchText: state.slimming.recycle.searchText, "
            "entryIDs: state.slimming.recycle.entries.map(entry => entry.id), "
            "scrollTop: document.querySelector('#slimmingRecycleBody').scrollTop })"
        ) == recycle_context_snapshot
        assert len(submitted_favorites) == recycle_context_favorite_count
        assert len(submitted_slimming_recycle_actions) == recycle_context_action_count
        assert len(submitted_slimming_removals) == recycle_context_removal_count
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('slimming-recycle-thumbnail-card')"
        )

        recycle_rows.nth(1).locator(".slimming-recycle-thumbnail-card").click(button="right")
        recycle_context_menu.wait_for()
        assert page.locator("#slimmingRecycleContextMenuNote").is_hidden()
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingRecycleFavoriteContextAction'"
        )
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('slimming-recycle-thumbnail-card')"
        )

        recycle_thumbnail.press("Shift+F10")
        recycle_context_menu.wait_for()
        with page.expect_response("**/v1/favorites"):
            recycle_context_action.click()
        page.wait_for_function(
            "before => document.querySelector('#slimmingRecycleList .slimming-recycle-favorite')"
            "?.dataset.favorite !== before",
            arg=recycle_before,
        )
        assert submitted_favorites[-1]["assetIDs"] == [SLIMMING_ASSET_IDS[0]]
        assert submitted_favorites[-1]["isFavorite"] is (recycle_before != "true")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('slimming-recycle-thumbnail-card')"
        )
        recycle_thumbnail.click(button="right")
        assert recycle_context_action.inner_text() == (
            "取消红心" if recycle_before != "true" else "加入红心"
        )
        with page.expect_response("**/v1/favorites"):
            recycle_context_action.click()
        page.wait_for_function(
            "before => document.querySelector('#slimmingRecycleList .slimming-recycle-favorite')"
            "?.dataset.favorite === before",
            arg=recycle_before,
        )

        recycle_bounds = recycle_thumbnail.bounding_box()
        assert recycle_bounds is not None
        recycle_long_press_point = {
            "x": recycle_bounds["x"] + min(44, recycle_bounds["width"] / 2),
            "y": recycle_bounds["y"] + min(44, recycle_bounds["height"] / 2),
        }
        page.evaluate(
            """point => document.querySelector(
              '#slimmingRecycleList .slimming-recycle-thumbnail-card'
            ).dispatchEvent(new PointerEvent('pointerdown', {
              bubbles: true,
              pointerId: 94,
              pointerType: 'touch',
              button: 0,
              clientX: point.x,
              clientY: point.y,
              isPrimary: true,
            }))""",
            recycle_long_press_point,
        )
        page.wait_for_timeout(580)
        recycle_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingRecycleFavoriteContextAction'"
        )
        page.evaluate(
            """point => document.elementFromPoint(point.x, point.y)?.dispatchEvent(
              new PointerEvent('pointerup', {
                bubbles: true,
                pointerId: 94,
                pointerType: 'touch',
                button: 0,
                clientX: point.x,
                clientY: point.y,
                isPrimary: true,
              })
            )""",
            recycle_long_press_point,
        )
        page.screenshot(
            path="/tmp/imageall-slimming-recycle-long-press-menu.png",
            full_page=True,
        )
        page.keyboard.press("Escape")
        page.wait_for_timeout(950)
        assert page.evaluate(
            """() => ({
              scope: state.slimming.recycle.scope,
              sourceID: state.slimming.recycle.sourceID,
              searchText: state.slimming.recycle.searchText,
              entryIDs: state.slimming.recycle.entries.map(entry => entry.id),
              scrollTop: document.querySelector('#slimmingRecycleBody').scrollTop,
            })"""
        ) == recycle_context_snapshot
        assert len(submitted_favorites) == recycle_context_favorite_count + 2
        assert len(submitted_slimming_recycle_actions) == recycle_context_action_count
        assert len(submitted_slimming_removals) == recycle_context_removal_count

        recycle_favorite.click()
        page.wait_for_function(
            "before => document.querySelector('#slimmingRecycleList .slimming-recycle-favorite')"
            "?.dataset.favorite !== before",
            arg=recycle_before,
        )
        assert recycle_rows.count() == 7
        assert page.locator("#lightbox").is_hidden()
        assert page.locator("#slimmingRecycleBody").evaluate(
            "element => element.scrollTop"
        ) == recycle_scroll_before
        assert page.evaluate(
            "() => document.activeElement?.classList.contains('slimming-recycle-favorite')"
        )
        recycle_favorite.press("Enter")
        page.wait_for_function(
            "before => document.querySelector('#slimmingRecycleList .slimming-recycle-favorite')"
            "?.dataset.favorite === before",
            arg=recycle_before,
        )

        refresh_row = page.locator(
            f'[data-slimming-recycle-row-id="{SLIMMING_RECYCLE_IDS[1]}"]'
        )
        assert "来源文件已变化，已停止处理以避免误删" in refresh_row.inner_text()
        assert "原文件未删除；刷新来源并重新分析后再试" in refresh_row.inner_text()
        assert refresh_row.get_by_role("button", name="刷新来源").is_visible()
        explanation_button = refresh_row.get_by_role("button", name="说明")
        explanation_button.click()
        page.locator("#slimmingRecycleExplanationDialog[open]").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "slimmingRecycleExplanation"
        explanation_history = page.evaluate("() => JSON.stringify(history.state)")
        assert SLIMMING_RECYCLE_IDS[1] not in explanation_history
        assert "RECYCLE_0002" not in explanation_history
        assert "旅行归档" not in explanation_history
        assert "RECYCLE_0002" in page.locator("#slimmingRecycleExplanationTitle").inner_text()
        assert "目录中的文件与分析时记录不一致" in page.locator(
            "#slimmingRecycleExplanationMessage"
        ).inner_text()
        assert "原文件未删除" in page.locator(
            "#slimmingRecycleExplanationPolicy"
        ).inner_text()
        page.go_back()
        page.wait_for_function(
            "() => !document.querySelector('#slimmingRecycleExplanationDialog').open"
        )
        page.wait_for_function(
            "entryID => document.activeElement?.dataset.slimmingRecycleExplanationId === entryID",
            arg=SLIMMING_RECYCLE_IDS[1],
        )
        page.go_forward()
        page.locator("#slimmingRecycleExplanationDialog[open]").wait_for()
        assert "RECYCLE_0002" in page.locator("#slimmingRecycleExplanationTitle").inner_text()
        assert "目录中的文件与分析时记录不一致" in page.locator(
            "#slimmingRecycleExplanationMessage"
        ).inner_text()
        page.screenshot(path="/tmp/imageall-slimming-recycle-recovery.png", full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        explanation_dimensions = page.locator("#slimmingRecycleExplanationDialog").evaluate(
            "dialog => ({ width: dialog.getBoundingClientRect().width, "
            "scrollWidth: dialog.scrollWidth, viewportWidth: document.documentElement.clientWidth })"
        )
        assert explanation_dimensions["width"] <= explanation_dimensions["viewportWidth"]
        assert explanation_dimensions["scrollWidth"] <= explanation_dimensions["width"] + 1
        page.screenshot(
            path="/tmp/imageall-slimming-recycle-recovery-390.png",
            full_page=True,
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        page.keyboard.press("Escape")
        page.locator("#slimmingRecycleExplanationDialog").wait_for(state="hidden")
        assert page.locator("#slimmingWorkspace").is_visible()
        page.wait_for_function(
            "entryID => document.activeElement?.dataset.slimmingRecycleExplanationId === entryID",
            arg=SLIMMING_RECYCLE_IDS[1],
        )
        refresh_source_button = refresh_row.get_by_role("button", name="刷新来源")
        recycle_source_action_scroll = page.evaluate(
            """entryID => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(entryID)}"]`
              );
              const unaffectedRow = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              body.scrollTop = Math.min(90, Math.max(0, body.scrollHeight - body.clientHeight));
              window.__imageAllRecycleSourceActionRow = row;
              window.__imageAllRecycleSourceActionThumbnail = row.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              window.__imageAllRecycleSourceActionUnaffectedRow = unaffectedRow;
              window.__imageAllRecycleSourceActionUnaffectedThumbnail = unaffectedRow.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              return body.scrollTop;
            }""",
            SLIMMING_RECYCLE_IDS[1],
        )
        recycle_source_action_count = len(submitted_source_management)
        refresh_source_button.click()
        page.wait_for_function(
            "entryID => !state.slimming.recycle.mutatingEntryIDs.has(entryID) "
            "&& !state.sourceManagement.submitting",
            arg=SLIMMING_RECYCLE_IDS[1],
        )
        assert len(submitted_source_management) == recycle_source_action_count + 1
        assert submitted_source_management[-1]["action"] == "rescan"
        assert submitted_source_management[-1]["sourceID"] == SECOND_SOURCE_ID
        assert page.evaluate(
            """expected => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.entryID)}"]`
              );
              const unaffectedRow = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              return row === window.__imageAllRecycleSourceActionRow
                && row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleSourceActionThumbnail
                && unaffectedRow === window.__imageAllRecycleSourceActionUnaffectedRow
                && unaffectedRow.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleSourceActionUnaffectedThumbnail
                && body.scrollTop === expected.scrollTop
                && document.activeElement?.dataset.slimmingRecycleRecoveryAction === 'rescan';
            }""",
            {
                "entryID": SLIMMING_RECYCLE_IDS[1],
                "scrollTop": recycle_source_action_scroll,
            },
        )

        reinspect_row = page.locator(
            f'[data-slimming-recycle-row-id="{SLIMMING_RECYCLE_IDS[2]}"]'
        )
        reinspect_button = reinspect_row.get_by_role("button", name="重新检查")
        assert reinspect_button.is_visible()
        assert reinspect_row.get_by_role("button", name="说明").is_visible()
        recycle_action_scroll = page.evaluate(
            """entryID => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(entryID)}"]`
              );
              const unaffectedRow = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              body.scrollTop = Math.min(90, Math.max(0, body.scrollHeight - body.clientHeight));
              window.__imageAllRecycleActionRow = row;
              window.__imageAllRecycleActionThumbnail = row.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              window.__imageAllRecycleActionUnaffectedRow = unaffectedRow;
              window.__imageAllRecycleActionUnaffectedThumbnail = unaffectedRow.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              return body.scrollTop;
            }""",
            SLIMMING_RECYCLE_IDS[2],
        )
        recycle_action_count = len(submitted_slimming_recycle_actions)
        reinspect_button.click()
        page.wait_for_function(
            "entryID => !state.slimming.recycle.mutatingEntryIDs.has(entryID) "
            "&& state.slimming.recycle.requests.some(request => request.entryID === entryID)",
            arg=SLIMMING_RECYCLE_IDS[2],
        )
        assert len(submitted_slimming_recycle_actions) == recycle_action_count + 1
        assert submitted_slimming_recycle_actions[-1]["action"] == "retryInterruptedOperation"
        assert page.evaluate(
            """expected => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.entryID)}"]`
              );
              const unaffectedRow = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              return row === window.__imageAllRecycleActionRow
                && row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleActionThumbnail
                && unaffectedRow === window.__imageAllRecycleActionUnaffectedRow
                && unaffectedRow.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleActionUnaffectedThumbnail
                && body.scrollTop === expected.scrollTop
                && document.activeElement?.dataset.action === 'retryInterruptedOperation';
            }""",
            {
                "entryID": SLIMMING_RECYCLE_IDS[2],
                "scrollTop": recycle_action_scroll,
            },
        )
        slimming_recycle_action_failures[0] = 1
        recycle_failed_action_before = page.evaluate(
            """entryID => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(entryID)}"]`
              );
              window.__imageAllRecycleFailedActionRow = row;
              window.__imageAllRecycleFailedActionThumbnail = row.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              return {
                scrollTop: body.scrollTop,
                requestCount: state.slimming.recycle.requests.length,
              };
            }""",
            SLIMMING_RECYCLE_IDS[2],
        )
        recycle_failed_action_count = len(submitted_slimming_recycle_actions)
        reinspect_button.click()
        page.wait_for_function(
            "entryID => !state.slimming.recycle.mutatingEntryIDs.has(entryID)",
            arg=SLIMMING_RECYCLE_IDS[2],
        )
        page.wait_for_function(
            "() => document.querySelector('#toast')?.textContent.includes('模拟回收动作失败')"
        )
        assert len(submitted_slimming_recycle_actions) == recycle_failed_action_count + 1
        recycle_failed_action_after = page.evaluate(
            """expected => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.entryID)}"]`
              );
              return {
                rowStable: row === window.__imageAllRecycleFailedActionRow,
                thumbnailStable: row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleFailedActionThumbnail,
                scrollTop: body.scrollTop,
                requestCount: state.slimming.recycle.requests.length,
                focusedAction: document.activeElement?.dataset.action || null,
              };
            }""",
            {
                "entryID": SLIMMING_RECYCLE_IDS[2],
                **recycle_failed_action_before,
            },
        )
        assert recycle_failed_action_after == {
            "rowStable": True,
            "thumbnailStable": True,
            "scrollTop": recycle_failed_action_before["scrollTop"],
            "requestCount": recycle_failed_action_before["requestCount"],
            "focusedAction": "retryInterruptedOperation",
        }, recycle_failed_action_after

        authorization_row = page.locator(
            f'[data-slimming-recycle-row-id="{SLIMMING_RECYCLE_IDS[3]}"]'
        )
        authorization_row.get_by_role("button", name="更新回收权限").click()
        page.wait_for_timeout(100)
        assert submitted_source_management[-1]["action"] == "refreshFolderMutationAuthorization"
        assert submitted_source_management[-1]["sourceID"] == SECOND_SOURCE_ID

        photos_authorization_row = page.locator(
            f'[data-slimming-recycle-row-id="{SLIMMING_RECYCLE_IDS[4]}"]'
        )
        photos_authorization_row.get_by_role("button", name="请求照片权限").click()
        page.wait_for_timeout(100)
        assert submitted_source_management[-1]["action"] == "requestPhotosWriteAuthorization"
        assert submitted_source_management[-1]["sourceID"] == SOURCE_ID

        discard_row = page.locator(
            f'[data-slimming-recycle-row-id="{SLIMMING_RECYCLE_IDS[6]}"]'
        )
        assert discard_row.get_by_role("button", name="更新回收权限").is_visible()
        recycle_confirm_action_scroll = page.evaluate(
            """entryID => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(entryID)}"]`
              );
              const unaffectedRow = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              body.scrollTop = Math.min(90, Math.max(0, body.scrollHeight - body.clientHeight));
              window.__imageAllRecycleConfirmActionRow = row;
              window.__imageAllRecycleConfirmActionThumbnail = row.querySelector(
                '.slimming-recycle-thumbnail-card'
              );
              window.__imageAllRecycleConfirmActionUnaffectedRow = unaffectedRow;
              return body.scrollTop;
            }""",
            SLIMMING_RECYCLE_IDS[6],
        )
        recycle_confirm_action_count = len(submitted_slimming_recycle_actions)
        discard_row.get_by_role("button", name="移除记录").click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "未执行的失败记录" in page.locator("#confirmDialogTitle").inner_text()
        page.locator("#confirmActionButton").click()
        page.wait_for_function(
            "entryID => !state.slimming.recycle.mutatingEntryIDs.has(entryID) "
            "&& state.slimming.recycle.requests.some(request => request.entryID === entryID)",
            arg=SLIMMING_RECYCLE_IDS[6],
        )
        assert len(submitted_slimming_recycle_actions) == recycle_confirm_action_count + 1
        assert submitted_slimming_recycle_actions[-1]["action"] == "discardPreflightFailure"
        page.wait_for_timeout(100)
        assert page.evaluate(
            "() => document.activeElement?.dataset.action === 'discardPreflightFailure'"
        )
        assert page.evaluate(
            """expected => {
              const body = document.querySelector('#slimmingRecycleBody');
              const row = document.querySelector(
                `[data-slimming-recycle-row-id="${CSS.escape(expected.entryID)}"]`
              );
              const unaffectedRow = document.querySelector(
                '#slimmingRecycleList > .slimming-recycle-row'
              );
              return row === window.__imageAllRecycleConfirmActionRow
                && row.querySelector('.slimming-recycle-thumbnail-card')
                  === window.__imageAllRecycleConfirmActionThumbnail
                && unaffectedRow === window.__imageAllRecycleConfirmActionUnaffectedRow
                && body.scrollTop === expected.scrollTop;
            }""",
            {
                "entryID": SLIMMING_RECYCLE_IDS[6],
                "scrollTop": recycle_confirm_action_scroll,
            },
        )
        page.screenshot(
            path="/tmp/imageall-slimming-recycle-action-continuity.png",
            full_page=False,
        )

        expanded_slimming_recycle_pagination_enabled = True
        page.evaluate(
            """async () => {
              state.slimming.recycle.scope = 'all';
              state.slimming.recycle.sourceID = '';
              state.slimming.recycle.searchText = '';
              state.slimming.recycle.limit = 60;
              await loadSlimmingRecycle({ quiet: true });
            }"""
        )
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 60"
        )
        pagination_recycle_rows = page.locator(
            "#slimmingRecycleList .slimming-recycle-row"
        )
        assert "ImageAll 将在" in pagination_recycle_rows.nth(0).locator(
            ".slimming-recycle-detail"
        ).inner_text()
        assert "清理此记录" in pagination_recycle_rows.nth(0).locator(
            ".slimming-recycle-detail"
        ).inner_text()
        folder_recycle_detail = pagination_recycle_rows.nth(1).locator(
            ".slimming-recycle-detail"
        )
        assert "永久删除" in folder_recycle_detail.inner_text()
        assert "ImageAll" not in folder_recycle_detail.inner_text()
        assert folder_recycle_detail.get_attribute("class") == (
            "slimming-recycle-detail folder-countdown"
        )
        folder_restore = pagination_recycle_rows.nth(1).get_by_role(
            "button", name="恢复", exact=True
        )
        folder_purge = pagination_recycle_rows.nth(1).get_by_role(
            "button", name="立即删除", exact=True
        )
        assert "button-primary" in folder_restore.get_attribute("class")
        assert "button-danger" in folder_purge.get_attribute("class")
        assert "button-primary" not in folder_purge.get_attribute("class")
        recycle_append_progress = page.evaluate(
            """() => {
              state.slimming.recycle.loading = true;
              state.slimming.recycle.appending = true;
              renderSlimmingWorkspace({ preserveRecycle: true });
              const result = {
                summary: document.querySelector('#slimmingSummary').textContent,
                count: document.querySelector('#slimmingRecycleCount').textContent,
                buttonText: document.querySelector('#slimmingRecycleLoadMoreButton').textContent,
                actionDisabled: document.querySelector(
                  '#slimmingRecycleList [data-slimming-recycle-entry-id]'
                )?.disabled,
                favoriteDisabled: document.querySelector(
                  '#slimmingRecycleList .slimming-recycle-favorite'
                )?.disabled,
              };
              state.slimming.recycle.loading = false;
              state.slimming.recycle.appending = false;
              renderSlimmingWorkspace({ preserveRecycle: true });
              return result;
            }"""
        )
        assert "正在载入更多回收项目" in recycle_append_progress["summary"]
        assert "正在载入更多" in recycle_append_progress["count"]
        assert recycle_append_progress["buttonText"] == "正在载入更多回收项目…"
        assert recycle_append_progress["actionDisabled"] is True
        assert recycle_append_progress["favoriteDisabled"] is True

        recycle_append_baseline = page.evaluate(
            """() => {
              clearTimeout(state.slimming.recycle.pollTimer);
              state.slimming.recycle.pollTimer = null;
              const originalSyncSlimmingRecycleRow = syncSlimmingRecycleRow;
              globalThis.__slimmingRecycleSyncCalls = 0;
              globalThis.__slimmingRecycleBaselineRows = [
                ...document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row')
              ];
              syncSlimmingRecycleRow = (...args) => {
                globalThis.__slimmingRecycleSyncCalls += 1;
                return originalSyncSlimmingRecycleRow(...args);
              };
              const body = document.querySelector('#slimmingRecycleBody');
              body.scrollTop = 480;
              const favorite = globalThis.__slimmingRecycleBaselineRows[20]
                .querySelector('.slimming-recycle-favorite');
              favorite.focus({ preventScroll: true });
              return {
                scrollTop: body.scrollTop,
                focusedEntryID: favorite.closest('[data-slimming-recycle-row-id]')
                  .dataset.slimmingRecycleRowId,
              };
            }"""
        )
        page.locator("#slimmingRecycleLoadMoreButton").evaluate("button => button.click()")
        page.wait_for_function(
            "() => !state.slimming.recycle.loading "
            "&& document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 120"
        )
        recycle_append = page.evaluate(
            """() => ({
              syncCalls: globalThis.__slimmingRecycleSyncCalls,
              retained: globalThis.__slimmingRecycleBaselineRows.every(
                (row, index) => document.querySelector('#slimmingRecycleList').children[index] === row
              ),
              scrollTop: document.querySelector('#slimmingRecycleBody').scrollTop,
              focusedEntryID: document.activeElement?.closest('[data-slimming-recycle-row-id]')
                ?.dataset.slimmingRecycleRowId || null,
              focusedFavorite: document.activeElement?.classList.contains(
                'slimming-recycle-favorite'
              ),
              rovingEntryID: state.slimming.recycle.focusEntryID,
              rovingThumbnailCount: document.querySelectorAll(
                '#slimmingRecycleList .slimming-recycle-thumbnail-card[tabindex="0"]'
              ).length,
            })"""
        )
        assert recycle_append["syncCalls"] == 60, recycle_append
        assert recycle_append["retained"] is True, recycle_append
        assert recycle_append["scrollTop"] == recycle_append_baseline["scrollTop"]
        assert recycle_append["focusedEntryID"] == recycle_append_baseline["focusedEntryID"]
        assert recycle_append["focusedFavorite"] is True
        assert recycle_append["rovingEntryID"] == recycle_append_baseline["focusedEntryID"]
        assert recycle_append["rovingThumbnailCount"] == 1

        page.evaluate(
            """() => {
              clearTimeout(state.slimming.recycle.pollTimer);
              state.slimming.recycle.pollTimer = null;
              globalThis.__slimmingRecycleSyncCalls = 0;
              const stale = document.createElement('article');
              stale.className = 'slimming-recycle-row';
              stale.dataset.slimmingRecycleRowId = 'stale-recycle-entry';
              document.querySelector('#slimmingRecycleList').append(stale);
            }"""
        )
        page.locator("#slimmingRecycleLoadMoreButton").evaluate("button => button.click()")
        page.wait_for_function(
            "() => !state.slimming.recycle.loading "
            "&& document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 135"
        )
        recycle_fallback = page.evaluate(
            """() => ({
              syncCalls: globalThis.__slimmingRecycleSyncCalls,
              staleCount: document.querySelectorAll(
                '#slimmingRecycleList [data-slimming-recycle-row-id="stale-recycle-entry"]'
              ).length,
              scrollTop: document.querySelector('#slimmingRecycleBody').scrollTop,
              focusedEntryID: document.activeElement?.closest('[data-slimming-recycle-row-id]')
                ?.dataset.slimmingRecycleRowId || null,
              focusedFavorite: document.activeElement?.classList.contains(
                'slimming-recycle-favorite'
              ),
              rovingEntryID: state.slimming.recycle.focusEntryID,
              rovingThumbnailCount: document.querySelectorAll(
                '#slimmingRecycleList .slimming-recycle-thumbnail-card[tabindex="0"]'
              ).length,
            })"""
        )
        assert recycle_fallback["syncCalls"] == 135, recycle_fallback
        assert recycle_fallback["staleCount"] == 0, recycle_fallback
        assert recycle_fallback["scrollTop"] == recycle_append_baseline["scrollTop"]
        assert recycle_fallback["focusedEntryID"] == recycle_append_baseline["focusedEntryID"]
        assert recycle_fallback["focusedFavorite"] is True
        assert recycle_fallback["rovingEntryID"] == recycle_append_baseline["focusedEntryID"]
        assert recycle_fallback["rovingThumbnailCount"] == 1

        expanded_slimming_recycle_pagination_enabled = False
        page.evaluate(
            """async () => {
              state.slimming.recycle.limit = 60;
              await loadSlimmingRecycle({ quiet: true });
            }"""
        )
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 7"
        )

        retry_from_analysis_row = page.locator(
            f'[data-slimming-recycle-row-id="{SLIMMING_RECYCLE_IDS[5]}"]'
        )
        retry_from_analysis_row.get_by_role("button", name="返回分析结果").click()
        page.wait_for_function(
            "() => document.querySelector('[data-slimming-view=\"analysis\"]')"
            "?.getAttribute('aria-pressed') === 'true'"
        )

        expanded_slimming_history_enabled = True
        page.locator('[data-slimming-view="analysis"]').click()
        page.evaluate(
            "async jobID => { state.slimming.jobLimit = 2; "
            "state.slimming.totalJobCount = 0; state.slimming.selectedJobID = jobID; "
            "state.slimming.selectedClusterID = null; await loadSlimmingWorkspace({ quiet: true }); }",
            SLIMMING_JOB_ID,
        )
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingJobList [data-slimming-job-id]').length === 2"
        )
        assert page.locator("#slimmingJobCount").inner_text() == "121 条"
        assert "已载入 2 / 121" in page.locator("#slimmingJobCount").get_attribute("title")
        load_more_jobs = page.locator("#slimmingLoadMoreJobsButton")
        assert load_more_jobs.is_visible()
        assert "剩余 119" in load_more_jobs.inner_text()
        job_append_baseline = page.evaluate(
            """() => {
              const originalSyncSlimmingJobRow = syncSlimmingJobRow;
              globalThis.__slimmingJobSyncCalls = 0;
              globalThis.__slimmingJobBaselineRows = [
                ...document.querySelectorAll('#slimmingJobList [data-slimming-job-id]')
              ];
              globalThis.__slimmingJobBaselineClusters = [
                ...document.querySelectorAll('#slimmingClusterList .slimming-cluster-row')
              ];
              globalThis.__slimmingJobBaselineMembers = [
                ...document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card')
              ];
              syncSlimmingJobRow = (...args) => {
                globalThis.__slimmingJobSyncCalls += 1;
                return originalSyncSlimmingJobRow(...args);
              };
              return {
                rowCount: globalThis.__slimmingJobBaselineRows.length,
                selectedJobID: state.slimming.selectedJobID,
              };
            }"""
        )
        assert job_append_baseline["rowCount"] == 2
        load_more_jobs.click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingJobList [data-slimming-job-id]').length === 102"
        )
        job_append = page.evaluate(
            """() => ({
              syncCalls: globalThis.__slimmingJobSyncCalls,
              retainedRows: globalThis.__slimmingJobBaselineRows.every(
                (row, index) => document.querySelector('#slimmingJobList').children[index] === row
              ),
              retainedClusters: globalThis.__slimmingJobBaselineClusters.every(
                (row, index) => document.querySelector('#slimmingClusterList').children[index] === row
              ),
              retainedMembers: globalThis.__slimmingJobBaselineMembers.every(
                (card, index) => document.querySelector('#slimmingMemberGrid').children[index] === card
              ),
              selectedJobID: state.slimming.selectedJobID,
            })"""
        )
        assert job_append["syncCalls"] == 100, job_append
        assert job_append["retainedRows"] is True, job_append
        assert job_append["retainedClusters"] is True, job_append
        assert job_append["retainedMembers"] is True, job_append
        assert job_append["selectedJobID"] == job_append_baseline["selectedJobID"]
        assert "剩余 19" in load_more_jobs.inner_text()
        page.evaluate(
            """() => {
              globalThis.__slimmingJobSyncCalls = 0;
              const stale = document.createElement('button');
              stale.className = 'slimming-job-row';
              stale.dataset.slimmingJobId = 'stale-job';
              document.querySelector('#slimmingJobList').append(stale);
            }"""
        )
        page.locator("#slimmingNavigatorPane").evaluate(
            "element => { element.scrollTop = 120; }"
        )
        navigator_scroll_before_final_page = page.locator(
            "#slimmingNavigatorPane"
        ).evaluate("element => element.scrollTop")
        assert navigator_scroll_before_final_page == 120
        load_more_jobs.evaluate("button => button.click()")
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingJobList [data-slimming-job-id]').length === 121"
        )
        job_fallback = page.evaluate(
            """() => ({
              syncCalls: globalThis.__slimmingJobSyncCalls,
              staleCount: document.querySelectorAll(
                '#slimmingJobList [data-slimming-job-id="stale-job"]'
              ).length,
            })"""
        )
        assert job_fallback["syncCalls"] == 121, job_fallback
        assert job_fallback["staleCount"] == 0, job_fallback
        page.wait_for_function(
            "scrollTop => document.querySelector('#slimmingNavigatorPane').scrollTop === scrollTop",
            arg=navigator_scroll_before_final_page,
        )
        assert page.locator("#slimmingNavigatorPane").evaluate(
            "element => element.scrollTop"
        ) == navigator_scroll_before_final_page
        main_job_row = page.locator(
            f'[data-slimming-job-id="{SLIMMING_JOB_ID}"]'
        )
        main_job_row.focus()
        main_job_row.press("End")
        page.wait_for_function(
            "jobID => document.querySelectorAll('#slimmingJobList [data-slimming-job-id]').length === 121 "
            "&& document.querySelector(`[data-slimming-job-id=\"${jobID}\"]`)"
            ".getAttribute('aria-selected') === 'true'",
            arg=SLIMMING_HISTORY_JOB_IDS[-1],
        )
        assert load_more_jobs.is_hidden()
        assert page.locator("#slimmingJobPosition").inner_text() == "121 / 121"
        page.screenshot(path="/tmp/imageall-slimming-complete-history.png", full_page=True)

        expanded_slimming_history_enabled = False
        page.evaluate(
            "async jobID => { state.slimming.jobLimit = 100; "
            "state.slimming.totalJobCount = 0; state.slimming.selectedJobID = jobID; "
            "state.slimming.selectedClusterID = null; await loadSlimmingWorkspace({ quiet: true }); }",
            SLIMMING_JOB_ID,
        )
        expanded_slimming_pagination_enabled = True
        page.evaluate(
            """async jobID => {
              state.slimming.jobLimit = 2;
              state.slimming.clusterScope = 'pending';
              state.slimming.clusterLimit = 48;
              state.slimming.memberLimit = 96;
              state.slimming.selectedJobID = jobID;
              state.slimming.selectedClusterID = null;
              state.slimming.selectedMemberIDs.clear();
              state.slimming.selectionAnchorID = null;
              await loadSlimmingWorkspace({ quiet: true });
            }""",
            SLIMMING_JOB_ID,
        )
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingClusterList .slimming-cluster-row').length === 48 "
            "&& document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card').length === 96"
        )
        append_progress = page.evaluate(
            """() => {
              const memberID = state.slimming.members[0].id;
              state.slimming.selectedMemberIDs = new Set([memberID]);
              state.slimming.selectionAnchorID = memberID;
              state.slimming.selectionMode = true;
              state.slimming.loading = true;
              state.slimming.appending = 'members';
              renderSlimmingWorkspace({
                preserveJobs: true,
                preserveClusters: true,
                preserveMembers: true,
              });
              const result = {
                summary: document.querySelector('#slimmingSummary').textContent,
                buttonText: document.querySelector('#slimmingLoadMoreMembersButton').textContent,
                selectionModeDisabled: document.querySelector('#slimmingSelectionModeButton').disabled,
                selectAllDisabled: document.querySelector('#slimmingSelectAllButton').disabled,
                recycleDisabled: document.querySelector('#slimmingMoveToRecycleButton').disabled,
                deleteDisabled: document.querySelector('#slimmingReleaseSpaceButton').disabled,
                clusterDisabled: document.querySelector('[data-slimming-cluster-id]').disabled,
                jobActionDisabled: document.querySelector('[data-slimming-job-action-id]')?.disabled,
              };
              state.slimming.loading = false;
              state.slimming.appending = null;
              renderSlimmingWorkspace({
                preserveJobs: true,
                preserveClusters: true,
                preserveMembers: true,
              });
              return result;
            }"""
        )
        assert "正在载入更多成员" in append_progress["summary"]
        assert append_progress["buttonText"] == "正在载入更多成员…"
        assert append_progress["selectionModeDisabled"] is False
        assert append_progress["selectAllDisabled"] is False
        assert append_progress["recycleDisabled"] is True
        assert append_progress["deleteDisabled"] is True
        assert append_progress["clusterDisabled"] is True
        assert append_progress["jobActionDisabled"] is True
        pagination_baseline = page.evaluate(
            """() => {
              const originalSyncSlimmingClusterRow = syncSlimmingClusterRow;
              const originalSyncSlimmingMemberCard = syncSlimmingMemberCard;
              globalThis.__slimmingClusterSyncCalls = 0;
              globalThis.__slimmingMemberSyncCalls = 0;
              syncSlimmingClusterRow = (...args) => {
                globalThis.__slimmingClusterSyncCalls += 1;
                return originalSyncSlimmingClusterRow(...args);
              };
              syncSlimmingMemberCard = (...args) => {
                globalThis.__slimmingMemberSyncCalls += 1;
                return originalSyncSlimmingMemberCard(...args);
              };
              globalThis.__slimmingBaselineClusters = [
                ...document.querySelectorAll('#slimmingClusterList .slimming-cluster-row')
              ];
              globalThis.__slimmingBaselineMembers = [
                ...document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card')
              ];
              const navigator = document.querySelector('#slimmingNavigatorPane');
              const memberScroll = slimmingMemberScrollContainer();
              navigator.scrollTop = 420;
              memberScroll.scrollTop = 520;
              const memberID = state.slimming.members[40].id;
              selectSlimmingMember(memberID, {}, { forceReplace: true });
              document.querySelector(`[data-slimming-member-id="${memberID}"]`)
                .querySelector('.slimming-member-main').focus({ preventScroll: true });
              return {
                navigatorScrollTop: navigator.scrollTop,
                memberScrollTop: memberScroll.scrollTop,
                memberID,
              };
            }"""
        )
        page.locator("#slimmingLoadMoreClustersButton").evaluate("button => button.click()")
        page.wait_for_function(
            "() => !state.slimming.loading "
            "&& document.querySelectorAll('#slimmingClusterList .slimming-cluster-row').length === 96"
        )
        cluster_append = page.evaluate(
            """baseline => ({
              syncCalls: globalThis.__slimmingClusterSyncCalls,
              memberSyncCalls: globalThis.__slimmingMemberSyncCalls,
              retainedClusters: globalThis.__slimmingBaselineClusters.every(
                (row, index) => document.querySelector('#slimmingClusterList').children[index] === row
              ),
              retainedMembers: globalThis.__slimmingBaselineMembers.every(
                (card, index) => document.querySelector('#slimmingMemberGrid').children[index] === card
              ),
              navigatorScrollTop: document.querySelector('#slimmingNavigatorPane').scrollTop,
              memberScrollTop: slimmingMemberScrollContainer().scrollTop,
              selectedIDs: [...state.slimming.selectedMemberIDs],
              focusedMemberID: document.activeElement?.closest('[data-slimming-member-id]')
                ?.dataset.slimmingMemberId || null,
            })""",
            pagination_baseline,
        )
        assert cluster_append["syncCalls"] == 48, cluster_append
        assert cluster_append["memberSyncCalls"] == 0, cluster_append
        assert cluster_append["retainedClusters"] is True, cluster_append
        assert cluster_append["retainedMembers"] is True, cluster_append
        assert cluster_append["navigatorScrollTop"] == pagination_baseline["navigatorScrollTop"]
        assert cluster_append["memberScrollTop"] == pagination_baseline["memberScrollTop"], (
            pagination_baseline,
            cluster_append,
        )
        assert cluster_append["selectedIDs"] == [pagination_baseline["memberID"]]
        assert cluster_append["focusedMemberID"] == pagination_baseline["memberID"]

        page.evaluate(
            """() => {
              globalThis.__slimmingClusterSyncCalls = 0;
              const stale = document.createElement('div');
              stale.className = 'slimming-cluster-row';
              stale.dataset.slimmingClusterRowId = 'stale-cluster';
              document.querySelector('#slimmingClusterList').append(stale);
            }"""
        )
        page.locator("#slimmingLoadMoreClustersButton").evaluate("button => button.click()")
        page.wait_for_function(
            "() => !state.slimming.loading "
            "&& document.querySelectorAll('#slimmingClusterList .slimming-cluster-row').length === 105"
        )
        cluster_fallback = page.evaluate(
            """() => ({
              syncCalls: globalThis.__slimmingClusterSyncCalls,
              staleCount: document.querySelectorAll(
                '#slimmingClusterList [data-slimming-cluster-row-id="stale-cluster"]'
              ).length,
            })"""
        )
        assert cluster_fallback["syncCalls"] == 105, cluster_fallback
        assert cluster_fallback["staleCount"] == 0, cluster_fallback

        page.evaluate(
            """() => {
              globalThis.__slimmingMemberSyncCalls = 0;
              globalThis.__slimmingMemberAppendBaseline = [
                ...document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card')
              ];
            }"""
        )
        page.locator("#slimmingLoadMoreMembersButton").evaluate("button => button.click()")
        page.wait_for_function(
            "() => !state.slimming.loading "
            "&& document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card').length === 192"
        )
        member_append = page.evaluate(
            """baseline => ({
              syncCalls: globalThis.__slimmingMemberSyncCalls,
              retained: globalThis.__slimmingMemberAppendBaseline.every(
                (card, index) => document.querySelector('#slimmingMemberGrid').children[index] === card
              ),
              selectedIDs: [...state.slimming.selectedMemberIDs],
              focusedMemberID: document.activeElement?.closest('[data-slimming-member-id]')
                ?.dataset.slimmingMemberId || null,
              memberScrollTop: slimmingMemberScrollContainer().scrollTop,
            })""",
            pagination_baseline,
        )
        assert member_append["syncCalls"] == 96, member_append
        assert member_append["retained"] is True, member_append
        assert member_append["selectedIDs"] == [pagination_baseline["memberID"]]
        assert member_append["focusedMemberID"] == pagination_baseline["memberID"]
        assert member_append["memberScrollTop"] == pagination_baseline["memberScrollTop"], (
            pagination_baseline,
            member_append,
        )

        page.evaluate(
            """() => {
              globalThis.__slimmingMemberSyncCalls = 0;
              const stale = document.createElement('div');
              stale.className = 'slimming-member-card';
              stale.dataset.slimmingMemberId = 'stale-member';
              document.querySelector('#slimmingMemberGrid').append(stale);
            }"""
        )
        page.locator("#slimmingLoadMoreMembersButton").evaluate("button => button.click()")
        page.wait_for_function(
            "() => !state.slimming.loading "
            "&& document.querySelectorAll('#slimmingMemberGrid > .slimming-member-card').length === 205"
        )
        member_fallback = page.evaluate(
            """() => ({
              syncCalls: globalThis.__slimmingMemberSyncCalls,
              staleCount: document.querySelectorAll(
                '#slimmingMemberGrid [data-slimming-member-id="stale-member"]'
              ).length,
            })"""
        )
        assert member_fallback["syncCalls"] == 205, member_fallback
        assert member_fallback["staleCount"] == 0, member_fallback

        expanded_slimming_pagination_enabled = False
        page.evaluate(
            """async jobID => {
              state.slimming.clusterLimit = 48;
              state.slimming.memberLimit = 96;
              state.slimming.selectedJobID = jobID;
              state.slimming.selectedClusterID = null;
              state.slimming.selectedMemberIDs.clear();
              state.slimming.selectionAnchorID = null;
              await loadSlimmingWorkspace({ quiet: true });
            }""",
            SLIMMING_JOB_ID,
        )
        page.locator('[data-slimming-view="recycle"]').click()

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        slimming_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert slimming_dimensions["scroll"] <= slimming_dimensions["viewport"], slimming_dimensions
        assert page.locator("#slimmingRecycleList .slimming-recycle-favorite").first.is_visible()
        page.screenshot(path="/tmp/imageall-slimming-favorites-390.png", full_page=True)

        page.locator("#slimmingThumbnailAspectButton").click()
        page.locator('[data-slimming-view="analysis"]').click()
        page.locator("#slimmingCatalogSourceButton").click()
        page.locator("#slimmingCatalogSourcePopover:not(.hidden)").wait_for()
        catalog_source_dimensions = page.evaluate(
            "() => { const rect = document.querySelector('#slimmingCatalogSourcePopover')"
            ".getBoundingClientRect(); return { viewport: innerWidth, "
            "scroll: document.documentElement.scrollWidth, left: rect.left, "
            "right: rect.right, top: rect.top, bottom: rect.bottom, height: innerHeight }; }"
        )
        assert catalog_source_dimensions["scroll"] <= catalog_source_dimensions["viewport"], (
            catalog_source_dimensions
        )
        assert catalog_source_dimensions["left"] >= 0, catalog_source_dimensions
        assert catalog_source_dimensions["right"] <= catalog_source_dimensions["viewport"], (
            catalog_source_dimensions
        )
        assert catalog_source_dimensions["top"] >= 0, catalog_source_dimensions
        assert catalog_source_dimensions["bottom"] <= catalog_source_dimensions["height"], (
            catalog_source_dimensions
        )
        page.screenshot(
            path="/tmp/imageall-slimming-catalog-sources-390.png",
            full_page=True,
        )
        page.keyboard.press("Escape")
        page.locator("#slimmingCatalogSourcePopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingCatalogSourceButton'"
        )
        page.locator("#slimmingAnalysisOptionsButton").click()
        page.locator("#slimmingAnalysisOptionsPopover:not(.hidden)").wait_for()
        page.locator("#slimmingAnalysisOptionsContent:not(.hidden)").wait_for()
        analysis_options_dimensions = page.evaluate(
            "() => { const rect = document.querySelector('#slimmingAnalysisOptionsPopover')"
            ".getBoundingClientRect(); return { viewport: innerWidth, "
            "scroll: document.documentElement.scrollWidth, left: rect.left, "
            "right: rect.right, top: rect.top, width: rect.width }; }"
        )
        assert analysis_options_dimensions["scroll"] <= analysis_options_dimensions["viewport"], (
            analysis_options_dimensions
        )
        assert analysis_options_dimensions["left"] >= 0, analysis_options_dimensions
        assert analysis_options_dimensions["right"] <= analysis_options_dimensions["viewport"], (
            analysis_options_dimensions
        )
        assert analysis_options_dimensions["top"] >= 0, analysis_options_dimensions
        page.screenshot(
            path="/tmp/imageall-slimming-analysis-options-390.png",
            full_page=True,
        )
        page.locator("#openSlimmingThresholdEditorButton").click()
        page.locator("#slimmingThresholdDialogContent:not(.hidden)").wait_for()
        threshold_dialog_dimensions = page.evaluate(
            "() => { const rect = document.querySelector('#slimmingThresholdDialog')"
            ".getBoundingClientRect(); return { viewport: innerWidth, "
            "scroll: document.documentElement.scrollWidth, left: rect.left, "
            "right: rect.right, top: rect.top, bottom: rect.bottom, "
            "height: innerHeight }; }"
        )
        assert threshold_dialog_dimensions["scroll"] <= threshold_dialog_dimensions["viewport"], (
            threshold_dialog_dimensions
        )
        assert threshold_dialog_dimensions["left"] >= 0, threshold_dialog_dimensions
        assert threshold_dialog_dimensions["right"] <= threshold_dialog_dimensions["viewport"], (
            threshold_dialog_dimensions
        )
        assert threshold_dialog_dimensions["top"] >= 0, threshold_dialog_dimensions
        assert threshold_dialog_dimensions["bottom"] <= threshold_dialog_dimensions["height"], (
            threshold_dialog_dimensions
        )
        page.screenshot(
            path="/tmp/imageall-slimming-thresholds-390.png",
            full_page=True,
        )
        page.keyboard.press("Escape")
        assert page.locator("#slimmingThresholdDialog").is_hidden()
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingAnalysisOptionsButton'"
        )
        page.locator("#slimmingGridDensityButton").click()
        page.locator(
            '#slimmingGridDensityPopover:not(.hidden) [data-grid-density="3"]'
        ).click()
        page.wait_for_timeout(100)
        analysis_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth, "
            "refreshRight: document.querySelector('#refreshSlimmingButton')"
            ".getBoundingClientRect().right })"
        )
        assert analysis_dimensions["scroll"] <= analysis_dimensions["viewport"], analysis_dimensions
        assert analysis_dimensions["refreshRight"] <= analysis_dimensions["viewport"], analysis_dimensions
        mobile_slimming_layout = page.evaluate(
            """() => {
              const body = document.querySelector('#slimmingAnalysisBody').getBoundingClientRect();
              const navigator = document.querySelector('#slimmingNavigatorPane').getBoundingClientRect();
              const member = document.querySelector('.slimming-member-pane').getBoundingClientRect();
              return {
                bodyX: body.x,
                bodyTop: body.top,
                bodyWidth: body.width,
                navigatorX: navigator.x,
                navigatorTop: navigator.top,
                navigatorWidth: navigator.width,
                navigatorBottom: navigator.bottom,
                memberX: member.x,
                memberTop: member.top,
                memberWidth: member.width,
              };
            }"""
        )
        assert abs(mobile_slimming_layout["navigatorX"] - mobile_slimming_layout["bodyX"]) < 1
        assert abs(mobile_slimming_layout["memberX"] - mobile_slimming_layout["bodyX"]) < 1
        assert abs(
            mobile_slimming_layout["navigatorWidth"] - mobile_slimming_layout["bodyWidth"]
        ) < 1
        assert abs(
            mobile_slimming_layout["memberWidth"] - mobile_slimming_layout["bodyWidth"]
        ) < 1
        assert mobile_slimming_layout["memberTop"] >= mobile_slimming_layout["navigatorBottom"] - 1
        slimming_navigator_button.click()
        assert page.locator("#slimmingNavigatorPane").is_hidden()
        assert page.evaluate(
            "() => Math.abs(document.querySelector('.slimming-member-pane')"
            ".getBoundingClientRect().top - document.querySelector('#slimmingAnalysisBody')"
            ".getBoundingClientRect().top) < 1"
        )
        page.screenshot(path="/tmp/imageall-slimming-analysis-navigator-hidden-390.png", full_page=True)
        slimming_navigator_button.click()
        assert page.locator("#refreshSlimmingButton").is_visible()
        page.screenshot(path="/tmp/imageall-slimming-analysis-390.png", full_page=True)

        slimming_history_snapshot = page.evaluate(
            """() => ({
              view: state.slimming.view,
              selectedJobID: state.slimming.selectedJobID,
              selectedClusterID: state.slimming.selectedClusterID,
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              clusterScope: state.slimming.clusterScope,
            })"""
        )
        library_history_snapshot = page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        )
        assert page.evaluate(
            """() => ({
              navigationLevel: history.state?.imageAllWorkspace?.navigationLevel,
              actionMenuKind: activeActionMenuDescriptor()?.kind || null,
              confirmationOpen: document.querySelector('#confirmDialog').open,
            })"""
        ) == {
            "navigationLevel": "workspace",
            "actionMenuKind": None,
            "confirmationOpen": False,
        }
        page.evaluate("() => history.back()")
        page.locator("#slimmingWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )
        assert page.evaluate(
            """() => ({
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == library_history_snapshot
        page.evaluate("() => history.forward()")
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        page.wait_for_function("() => !state.slimming.loading")
        assert page.evaluate(
            """() => ({
              view: state.slimming.view,
              selectedJobID: state.slimming.selectedJobID,
              selectedClusterID: state.slimming.selectedClusterID,
              selectedMemberIDs: [...state.slimming.selectedMemberIDs].sort(),
              selectionAnchorID: state.slimming.selectionAnchorID,
              clusterScope: state.slimming.clusterScope,
            })"""
        ) == slimming_history_snapshot
        page.locator("#closeSlimmingButton").click()
        page.locator("#slimmingWorkspace").wait_for(state="hidden")
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        selection_inspector_state = page.evaluate(
            """() => ({
              selectionMode: state.selectionMode,
              selectedCount: state.selectedAssetIDs.size,
              selectedAssetID: state.selectedAssetID,
              inspectorClass: document.querySelector('#inspector').className,
              appClass: document.querySelector('#appView').className,
              actionDisplay: getComputedStyle(
                document.querySelector('#selectionInspectorPrepareFeaturesButton')
              ).display,
            })"""
        )
        assert page.locator("#selectionInspectorPrepareFeaturesButton").is_visible(), (
            selection_inspector_state
        )
        assert page.locator("#selectionInspectorGenerateSuggestionsButton").is_visible()
        assert page.locator("#selectionInspectorFindSimilarButton").is_visible()
        assert page.locator("#selectionInspectorFavoriteButton").is_visible()
        assert page.locator("#selectionInspectorUnfavoriteButton").is_visible()
        assert page.locator("#selectionInspectorPrimary").is_visible()
        assert page.locator("#assetGrid .asset-card-favorite").first.is_visible()
        if not page.locator("#inspector").evaluate(
            "element => element.classList.contains('open')"
        ):
            page.locator("#selectionInspectorOverlayButton").click()
            page.wait_for_function(
                "() => document.querySelector('#inspector').classList.contains('open')"
            )
        page.screenshot(path="/tmp/imageall-selection-tools-synthetic.png", full_page=True)

        page.locator("#closeInspectorButton").click()
        page.wait_for_function(
            "() => !document.querySelector('#inspector').classList.contains('open')"
        )
        compact_tool_geometry = page.evaluate(
            """() => {
              const bar = document.querySelector('#batchBar').getBoundingClientRect();
              const strip = document.querySelector('#selectionToolActions');
              const stripRect = strip.getBoundingClientRect();
              const first = document.querySelector('#favoriteSelectedButton').getBoundingClientRect();
              const last = document.querySelector('#deleteSelectedButton').getBoundingClientRect();
              return {
                barHeight: bar.height,
                clientWidth: strip.clientWidth,
                scrollWidth: strip.scrollWidth,
                scrollLeft: strip.scrollLeft,
                stripLeft: stripRect.left,
                stripRight: stripRect.right,
                firstLeft: first.left,
                firstRight: first.right,
                lastLeft: last.left,
                lastRight: last.right,
              };
            }"""
        )
        assert compact_tool_geometry["barHeight"] <= 190, compact_tool_geometry
        assert compact_tool_geometry["scrollWidth"] > compact_tool_geometry["clientWidth"], (
            compact_tool_geometry
        )
        assert compact_tool_geometry["scrollLeft"] <= 1, compact_tool_geometry
        assert compact_tool_geometry["firstLeft"] >= compact_tool_geometry["stripLeft"] - 1, (
            compact_tool_geometry
        )
        assert compact_tool_geometry["firstRight"] <= compact_tool_geometry["stripRight"] + 1, (
            compact_tool_geometry
        )
        page.locator("#deleteSelectedButton").focus()
        page.wait_for_function(
            """() => {
              const strip = document.querySelector('#selectionToolActions');
              const stripRect = strip.getBoundingClientRect();
              const buttonRect = document.querySelector('#deleteSelectedButton')
                .getBoundingClientRect();
              return strip.scrollLeft > 0
                && buttonRect.left >= stripRect.left - 1
                && buttonRect.right <= stripRect.right + 1;
            }"""
        )
        end_scroll_left = page.locator("#selectionToolActions").evaluate(
            "element => element.scrollLeft"
        )
        page.locator("#favoriteSelectedButton").focus()
        page.wait_for_function(
            """() => {
              const strip = document.querySelector('#selectionToolActions');
              const stripRect = strip.getBoundingClientRect();
              const buttonRect = document.querySelector('#favoriteSelectedButton')
                .getBoundingClientRect();
              return buttonRect.left >= stripRect.left - 1
                && buttonRect.right <= stripRect.right + 1;
            }"""
        )
        assert page.locator("#selectionToolActions").evaluate(
            "element => element.scrollLeft"
        ) < end_scroll_left
        narrow_favorite = page.locator("#assetGrid .asset-card-favorite").first
        assert narrow_favorite.is_visible()
        narrow_scroll = page.locator("#libraryScroll").evaluate("element => element.scrollTop")
        narrow_favorite.click()
        page.wait_for_function(
            "() => document.querySelector('#assetGrid .asset-card-favorite')"
            "?.dataset.favorite === 'false'"
        )
        assert page.locator("#selectionSummary").inner_text() == "已选择 2 项"
        assert not page.locator("#inspector").evaluate(
            "element => element.classList.contains('open')"
        )
        assert page.locator("#libraryScroll").evaluate("element => element.scrollTop") == narrow_scroll
        narrow_favorite.click()
        page.wait_for_function(
            "() => document.querySelector('#assetGrid .asset-card-favorite')"
            "?.dataset.favorite === 'true'"
        )
        with page.expect_response("**/v1/favorites"):
            page.locator("#favoriteSelectedButton").click()
        page.wait_for_function(
            "ids => ids.every(id => favoriteStateForAssetID(id)?.isFavorite === true)",
            arg=ASSET_IDS,
        )
        page.screenshot(path="/tmp/imageall-grid-favorite-390.png", full_page=True)

        page.locator("#sidebarToggle").click()
        page.locator("#favoritesNavigationButton").click()
        page.wait_for_function(
            "() => document.querySelectorAll('#assetGrid > .asset-card').length === 2"
        )
        assert page.locator("#favoritesNavigationButton").get_attribute("aria-current") == "page"
        page.locator("#selectionModeButton").click()
        page.locator("#assetGrid > .asset-card").first.click()
        page.locator("#commandButton").click()
        page.locator('[data-command-id="unfavoriteSelection"]').click()
        page.wait_for_function(
            "() => document.querySelectorAll('#assetGrid > .asset-card').length === 1"
        )
        assert submitted_favorites[-1]["isFavorite"] is False
        page.set_viewport_size({"width": 1440, "height": 960})
        remaining = page.locator("#assetGrid > .asset-card").first
        remaining.click(button="right")
        page.locator("#assetFavoriteContextAction").click()
        page.wait_for_function(
            "() => document.querySelectorAll('#assetGrid > .asset-card').length === 0"
        )
        assert all(not value for value in favorite_states.values())
        page.locator('#libraryNavigation [data-source-id=""]').click()
        page.wait_for_function(
            "() => document.querySelectorAll('#assetGrid > .asset-card').length === 2"
        )
        assert page.locator(
            '#assetGrid .asset-card-favorite[data-favorite="true"]'
        ).count() == 0

        expected_conflict_console = [
            message
            for message in console_errors
            if "status of 409 (Conflict)" in message
        ]
        unexpected_console_errors = [
            message
            for message in console_errors
            if message not in expected_conflict_console
        ]
        assert len(expected_conflict_console) == 4, console_errors
        assert failed_resources == [
            (409, f"{BASE_URL}/v1/tags/create-and-apply"),
            (409, f"{BASE_URL}/v1/library-slimming/recycle?mediaKind=image&scope=all&limit=60&search=RECYCLE"),
            (409, f"{BASE_URL}/v1/library-slimming/recycle?mediaKind=video&scope=all&limit=60&sourceID={SOURCE_ID}&search=RECYCLE"),
            (409, f"{BASE_URL}/v1/library-slimming/recycle/requests"),
        ], failed_resources
        assert not page_errors, page_errors
        assert not unexpected_console_errors, unexpected_console_errors
        assert not unexpected_dialogs, unexpected_dialogs
        context.close()
        browser.close()

    print(
        "selection tools browser flow passed; "
        f"preparations={len(submitted_preparations)}; "
        f"suggestions={len(submitted_sample_suggestions)}; slimming={len(submitted_slimming)}; "
        f"slimming reviews={len(submitted_slimming_cluster_reviews)}; "
        f"slimming job actions={len(submitted_slimming_job_actions)}; "
        f"slimming thresholds={len(submitted_slimming_thresholds)}; "
        f"slimming removals={len(submitted_slimming_removals)}; "
        f"tag decisions={len(submitted_tag_decisions)}; created tags={len(created_tag_results)}; "
        f"favorites={len(submitted_favorites)}; "
        f"favorite retries={len(submitted_favorite_retries)}"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--inspector-actions-only",
        action="store_true",
        help="Stop after the focused single-inspector action-strip regression.",
    )
    arguments = parser.parse_args()
    main(inspector_actions_only=arguments.inspector_actions_only)
