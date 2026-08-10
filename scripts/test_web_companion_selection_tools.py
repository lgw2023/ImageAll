#!/usr/bin/env python3
import base64
import json
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
SLIMMING_RECYCLE_IDS = [
    "66666666-4444-4444-4444-444444444441",
    "66666666-4444-4444-4444-444444444442",
    "66666666-4444-4444-4444-444444444443",
    "66666666-4444-4444-4444-444444444444",
    "66666666-4444-4444-4444-444444444445",
    "66666666-4444-4444-4444-444444444446",
    "66666666-4444-4444-4444-444444444447",
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


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def drag_marquee_to_bottom_edge(page, container_selector, grid_selector):
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


def main():
    submitted_preparations = []
    submitted_slimming = []
    submitted_slimming_cluster_reviews = []
    submitted_slimming_job_actions = []
    submitted_slimming_source_maintenance = []
    submitted_slimming_thresholds = []
    submitted_slimming_removals = []
    submitted_slimming_recycle_actions = []
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
    sample_reads = 0
    sample_active = False
    active_slimming_removal = None
    hidden_slimming_asset_ids = set()
    deleted_slimming_job_ids = set()
    expanded_slimming_history_enabled = False
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

    def preparation_activity(phase):
        completed = 2 if phase == "completed" else 1
        return {
            "operationID": PREPARATION_ID,
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
                    "capabilities": ["favorites", "sourceManagement"],
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
                "isFavorite": favorite_states[asset_id],
                "photosObservedValue": favorite_states[asset_id],
                "syncStatus": favorite_sync_status[asset_id],
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
            nonlocal preparation_reads, preparation_active
            if route.request.method == "POST":
                payload = route.request.post_data_json
                submitted_preparations.append(payload)
                preparation_active = True
                preparation_reads = 0
                fulfill_json(
                    route,
                    {"activity": preparation_activity("running"), "replayed": False},
                    status=202,
                )
                return
            activities = []
            if preparation_active:
                preparation_reads += 1
                phase = "completed" if preparation_reads >= 2 else "running"
                activities = [preparation_activity(phase)]
                if phase == "completed":
                    preparation_active = False
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
            return {
                "id": job_id,
                "mode": mode,
                "mediaKind": media_kind,
                "state": "completed",
                "attempts": 1,
                "maxAttempts": 10,
                "memberCount": len(SLIMMING_ASSET_IDS),
                "seedCount": 2 if mode == "seeds" else 0,
                "clusterCount": 3 if job_id == SLIMMING_JOB_ID else 0,
                "hasResult": job_id == SLIMMING_JOB_ID,
                "createdAtMs": 1_700_000_000_000,
                "updatedAtMs": 1_700_000_001_000 if job_id == SLIMMING_JOB_ID else 1_699_999_999_000,
                "sourceNames": ["Apple Photos"],
                "availableActions": [],
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
            cluster_members = {
                SLIMMING_CLUSTER_ID: visible_slimming_asset_ids,
                SLIMMING_CONFIRMED_CLUSTER_ID: [],
                SLIMMING_IGNORED_CLUSTER_ID: visible_slimming_asset_ids[:1],
            }
            eligible_cluster_ids = [
                cluster_id for cluster_id, disposition in slimming_cluster_dispositions.items()
                if disposition is not None or len(cluster_members[cluster_id]) >= 2
            ]
            scoped_cluster_ids = [
                cluster_id for cluster_id, disposition in slimming_cluster_dispositions.items()
                if cluster_id in eligible_cluster_ids
                if (cluster_scope == "pending" and disposition is None)
                or disposition == cluster_scope
            ] if selected_job_id == SLIMMING_JOB_ID else []
            requested_cluster_id = query.get("clusterID", [None])[0]
            selected_cluster_id = requested_cluster_id \
                if requested_cluster_id in scoped_cluster_ids \
                else (scoped_cluster_ids[0] if scoped_cluster_ids else None)
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
                "reviewDisposition": slimming_cluster_dispositions[cluster_id],
                "originalMemberCount": len(SLIMMING_ASSET_IDS),
                "isHistoricalProcessedRecord": len(cluster_members[cluster_id]) < len(SLIMMING_ASSET_IDS),
            } for index, cluster_id in enumerate(scoped_cluster_ids)]
            selected_member_ids = cluster_members.get(selected_cluster_id, [])
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
                        "fileName": f"SLIM_{SLIMMING_ASSET_IDS.index(asset_id) + 1:04}.{'MOV' if media_kind == 'video' else 'JPG'}",
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
                            slimming_cluster_dispositions[cluster_id] is None
                            for cluster_id in eligible_cluster_ids
                        ) if selected_job_id == SLIMMING_JOB_ID else 0,
                        "confirmed": sum(
                            slimming_cluster_dispositions[cluster_id] == "confirmed"
                            for cluster_id in eligible_cluster_ids
                        ) if selected_job_id == SLIMMING_JOB_ID else 0,
                        "ignored": sum(
                            slimming_cluster_dispositions[cluster_id] == "ignored"
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
            submitted_slimming_job_actions.append({"jobID": job_id, **payload})
            if payload["action"] == "deleteRecord":
                deleted_slimming_job_ids.add(job_id)
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
            for index, (entry_id, spec) in enumerate(zip(SLIMMING_RECYCLE_IDS, entry_specs)):
                asset_id = SLIMMING_ASSET_IDS[index % len(SLIMMING_ASSET_IDS)]
                entries.append({
                    "id": entry_id,
                    "assetID": asset_id,
                    "mediaKind": media_kind,
                    "fileName": f"RECYCLE_{index + 1:04}.{'MOV' if media_kind == 'video' else 'JPG'}",
                    "trashedAtMs": 1_700_000_000_000,
                    "purgeAfterMs": 4_102_444_800_000,
                    "favorite": favorite_state(asset_id),
                    **spec,
                })
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
            fulfill_json(
                route,
                {
                    "mediaKind": media_kind,
                    "entries": visible_entries,
                    "totalCount": len(visible_entries),
                    "requests": [],
                    "scopeCounts": scope_counts,
                },
            )

        def handle_slimming_recycle_request(route):
            payload = route.request.post_data_json
            submitted_slimming_recycle_actions.append(payload)
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
            "Shift-F10 查看同步、缓存、授权、管理和移除动作",
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
        assert "Shift-F10 可仅筛选、排除、重命名或归档" in unfiltered_tag_help
        sidebar_cat_chip.click()
        page.wait_for_function(
            "tagID => state.filters.tagConditions.some((item) => "
            "item.tagID === tagID && item.decision === 'accepted')",
            arg=CAT_TAG_ID,
        )
        sidebar_cat_chip.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert "当前：并集筛选" in page.locator("#persistentHelpDetail").inner_text()
        sidebar_cat_chip.click()
        page.wait_for_function(
            "tagID => !state.filters.tagConditions.some((item) => item.tagID === tagID)",
            arg=CAT_TAG_ID,
        )
        sidebar_cat_chip.focus()
        page.keyboard.press("Shift+F10")
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
        sidebar_cat_chip.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert "正在搜索标签" in page.locator("#persistentHelpDetail").inner_text()
        page.locator("#tagNavigationSearch").fill("")

        page.set_viewport_size({"width": 390, "height": 844})
        page.locator("#sidebarToggle").click()
        page.locator("#sourceSidebar.open").wait_for()
        sidebar_cat_chip.scroll_into_view_if_needed()
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
        page.locator("#lightboxFavoriteButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxFavoriteButton')?.dataset.favorite === 'true'"
        )
        assert not page.locator("#lightbox").evaluate("element => element.classList.contains('hidden')")
        assert submitted_favorites[-1]["assetIDs"] == [ASSET_IDS[0]]
        assert submitted_favorites[-1]["isFavorite"] is True
        page.locator("#lightboxFavoriteButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxFavoriteButton')?.dataset.favorite === 'false'"
        )
        assert submitted_favorites[-1]["isFavorite"] is False
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")

        single_inline_input = page.locator("#inspectorInlineTagName")
        page.wait_for_function(
            "id => state.selectedAssetID === id && state.selectedDetail?.assetID === id",
            arg=ASSET_IDS[0],
        )
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
        travel_chip.click()
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        assert submitted_tag_decisions[-1]["action"] == "accept"
        assert set(submitted_tag_decisions[-1]["assetIDs"]) == set(ASSET_IDS)
        travel_chip.click(button="right")
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        assert submitted_tag_decisions[-1]["action"] == "clear"
        assert not unexpected_dialogs, unexpected_dialogs

        page.locator("#favoriteSelectedButton").click()
        page.wait_for_function(
            "() => document.querySelectorAll("
            "'#assetGrid .asset-card-favorite[data-favorite=\"true\"]'"
            ").length === 2"
        )
        assert submitted_favorites[-1]["isFavorite"] is True
        assert set(submitted_favorites[-1]["assetIDs"]) == set(ASSET_IDS)

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
        page.locator("#slimmingThresholdRecallMode").select_option("allCandidates")
        assert page.locator("#slimmingThresholdRecallTopK").is_disabled()
        assert page.locator("#slimmingThresholdDialogExtremeWarning").is_visible()
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
        maintenance_sources = page.locator(
            "#slimmingMaintenanceSourceOptions [data-slimming-maintenance-source-id]"
        )
        assert maintenance_sources.count() == 2
        assert "全部 2 个" in page.locator("#slimmingMaintenanceSourceSummary").inner_text()
        maintenance_sources.nth(1).uncheck()
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
        first_slimming_main.focus()
        page.keyboard.press("ArrowRight")
        assert page.evaluate(
            "id => state.slimming.selectedMemberIDs.size === 1 "
            "&& state.slimming.selectedMemberIDs.has(id)",
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
        slimming_cards.nth(1).locator(":scope > .slimming-member-main").click()
        assert page.evaluate("() => state.slimming.selectedMemberIDs.size") == 2
        assert slimming_select_all.is_enabled()
        slimming_cards.nth(1).locator(":scope > .slimming-member-main").dispatch_event(
            "dblclick"
        )
        assert page.locator("#lightbox").is_hidden()
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
        page.evaluate(
            """() => {
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
        assert slimming_narrow_marquee_scroll > 80
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
        assert "(2)" in slimming_context_menu.locator(
            '[data-slimming-member-context-action="recoverableRecycle"]'
        ).inner_text()
        assert "(2)" in slimming_context_menu.locator(
            '[data-slimming-member-context-action="releaseSourceSpace"]'
        ).inner_text()
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
        assert page.evaluate(
            "() => document.activeElement?.dataset.slimmingMemberMain === 'true'"
        )

        first_slimming_main.press("Shift+F10")
        slimming_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberContextAction === 'favorite'"
        )
        page.screenshot(path="/tmp/imageall-slimming-context-menu.png", full_page=True)
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.slimmingMemberContextAction"
            " === 'releaseSourceSpace'"
        )
        page.keyboard.press("Escape")
        assert slimming_context_menu.is_hidden()
        page.wait_for_function(
            "() => document.activeElement?.dataset.slimmingMemberMain === 'true'"
        )

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
        assert "(1)" in slimming_context_menu.locator(
            '[data-slimming-member-context-action="recoverableRecycle"]'
        ).inner_text()
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
        slimming_inspector_summary = slimming_inspector.locator(":scope > summary")
        assert slimming_inspector.get_attribute("open") is None
        grid_geometry_before_inspector = page.locator("#slimmingMemberGrid").evaluate(
            "element => { const rect = element.getBoundingClientRect(); "
            "return { top: rect.top, height: rect.height, scrollTop: element.scrollTop }; }"
        )
        selection_before_inspector = page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all("cards => cards.map(card => card.dataset.slimmingMemberId)")
        slimming_inspector_summary.click()
        assert slimming_inspector.get_attribute("open") == ""
        assert page.locator("#slimmingInspectorContent").is_visible()
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => { const rect = element.getBoundingClientRect(); "
            "return { top: rect.top, height: rect.height, scrollTop: element.scrollTop }; }"
        ) == grid_geometry_before_inspector
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selection_before_inspector
        page.screenshot(path="/tmp/imageall-slimming-inspector-overlay.png", full_page=True)
        slimming_inspector_summary.press("Escape")
        assert slimming_inspector.get_attribute("open") is None
        assert page.evaluate(
            "() => document.activeElement === document.querySelector('#slimmingInspector > summary')"
        )
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
        slimming_density_metrics = page.locator("#slimmingGridDensitySlider").evaluate(
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
        page.locator("#slimmingGridDensitySlider").evaluate(
            "element => { element.value = '8'; "
            "element.dispatchEvent(new Event('input', { bubbles: true })); }"
        )
        assert page.locator("#gridDensitySlider").input_value() == "8"
        assert page.evaluate(
            "() => getComputedStyle(document.documentElement)"
            ".getPropertyValue('--slimming-member-min-width').trim() === '268px'"
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
        assert page.locator("#thumbnailAspectButton").get_attribute("aria-pressed") == "true"
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

        page.locator("#slimmingRecycleSourceSelect").select_option(SOURCE_ID)
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
        recycle_favorite = recycle_rows.nth(0).locator(".slimming-recycle-favorite")
        recycle_rows.nth(0).hover()
        assert recycle_favorite.is_visible()
        assert "不会暂停系统“照片”的永久删除" in recycle_favorite.get_attribute("title")
        recycle_before = recycle_favorite.get_attribute("data-favorite")
        recycle_scroll_before = page.locator("#slimmingRecycleBody").evaluate(
            "element => element.scrollTop"
        )
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
        assert "RECYCLE_0002" in page.locator("#slimmingRecycleExplanationTitle").inner_text()
        assert "目录中的文件与分析时记录不一致" in page.locator(
            "#slimmingRecycleExplanationMessage"
        ).inner_text()
        assert "原文件未删除" in page.locator(
            "#slimmingRecycleExplanationPolicy"
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
        refresh_row.get_by_role("button", name="刷新来源").click()
        page.wait_for_timeout(100)
        assert submitted_source_management[-1]["action"] == "rescan"
        assert submitted_source_management[-1]["sourceID"] == SECOND_SOURCE_ID

        reinspect_row = page.locator(
            f'[data-slimming-recycle-row-id="{SLIMMING_RECYCLE_IDS[2]}"]'
        )
        assert reinspect_row.get_by_role("button", name="重新检查").is_visible()
        assert reinspect_row.get_by_role("button", name="说明").is_visible()
        reinspect_row.get_by_role("button", name="重新检查").click()
        page.wait_for_timeout(100)
        assert submitted_slimming_recycle_actions[-1]["action"] == "retryInterruptedOperation"

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
        discard_row.get_by_role("button", name="移除记录").click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "未执行的失败记录" in page.locator("#confirmDialogTitle").inner_text()
        page.locator("#confirmActionButton").click()
        page.wait_for_timeout(100)
        assert submitted_slimming_recycle_actions[-1]["action"] == "discardPreflightFailure"

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
        load_more_jobs.click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingJobList [data-slimming-job-id]').length === 102"
        )
        assert "剩余 19" in load_more_jobs.inner_text()
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
        page.locator("#slimmingGridDensitySlider").evaluate(
            "element => { element.value = '4'; "
            "element.dispatchEvent(new Event('input', { bubbles: true })); }"
        )
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
        assert page.locator("#selectionInspectorPrepareFeaturesButton").is_visible()
        assert page.locator("#selectionInspectorGenerateSuggestionsButton").is_visible()
        assert page.locator("#selectionInspectorFindSimilarButton").is_visible()
        assert page.locator("#selectionInspectorFavoriteButton").is_visible()
        assert page.locator("#selectionInspectorUnfavoriteButton").is_visible()
        assert page.locator("#selectionInspectorPrimary").is_visible()
        assert page.locator("#assetGrid .asset-card-favorite").first.is_visible()
        page.screenshot(path="/tmp/imageall-selection-tools-synthetic.png", full_page=True)

        page.locator("#closeInspectorButton").click()
        page.wait_for_function(
            "() => !document.querySelector('#inspector').classList.contains('open')"
        )
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
        assert len(expected_conflict_console) == 1, console_errors
        assert failed_resources == [
            (409, f"{BASE_URL}/v1/tags/create-and-apply")
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
    main()
