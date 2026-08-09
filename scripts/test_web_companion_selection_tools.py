#!/usr/bin/env python3
import base64
import json
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8802"
SOURCE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
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
]
SAMPLE_SUGGESTION_ID = "77777777-7777-7777-7777-777777777777"
CAT_TAG_ID = "88888888-8888-8888-8888-888888888888"
TRAVEL_TAG_ID = "99999999-9999-9999-9999-999999999999"
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


def main():
    submitted_preparations = []
    submitted_slimming = []
    submitted_slimming_cluster_reviews = []
    submitted_slimming_job_actions = []
    submitted_slimming_removals = []
    submitted_sample_suggestions = []
    submitted_tag_decisions = []
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
    slimming_cluster_dispositions = {
        SLIMMING_CLUSTER_ID: None,
        SLIMMING_CONFIRMED_CLUSTER_ID: "confirmed",
        SLIMMING_IGNORED_CLUSTER_ID: "ignored",
    }
    page_errors = []
    console_errors = []
    failed_resources = []
    unexpected_dialogs = []

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
                    "capabilities": ["favorites"],
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
        page.route(
            "**/v1/tags",
            lambda route: fulfill_json(route, [
                {"id": CAT_TAG_ID, "displayName": "猫", "state": "active", "groupID": SUBJECT_GROUP_ID},
                {"id": TRAVEL_TAG_ID, "displayName": "旅行", "state": "active", "groupID": SCENE_GROUP_ID},
            ]),
        )
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(route, [
                {"id": SUBJECT_GROUP_ID, "displayName": "主体", "sortOrder": 0},
                {"id": SCENE_GROUP_ID, "displayName": "场景", "sortOrder": 1},
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
                            "acceptedTagCount": 0,
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
            fulfill_json(
                route,
                {
                    "assetID": asset_id,
                    "sourceID": SOURCE_ID,
                    "sourceName": "Apple Photos",
                    "sourceState": "active",
                    "fileName": f"IMG_{ASSET_IDS.index(asset_id) + 1:04}.JPG",
                    "mediaType": "image",
                    "availability": "available",
                    "contentRevision": 1,
                    "acceptedTagCount": 0,
                    "rejectedTagCount": 0,
                    "tags": [],
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
        page.route(
            "**/v1/tags/selection",
            lambda route: fulfill_json(route, [
                {"tagID": CAT_TAG_ID, "acceptedCount": 2, "rejectedCount": 0, "unknownCount": 0},
                {"tagID": TRAVEL_TAG_ID, "acceptedCount": 1, "rejectedCount": 0, "unknownCount": 1},
            ]),
        )

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
            entries = [{
                "id": entry_id,
                "assetID": asset_id,
                "sourceID": SOURCE_ID,
                "sourceDisplayName": "Apple Photos",
                "sourceKind": "photos" if index == 0 else "file",
                "mediaKind": media_kind,
                "fileName": f"RECYCLE_{index + 1:04}.{'MOV' if media_kind == 'video' else 'JPG'}",
                "trashedAtMs": 1_700_000_000_000,
                "purgeAfterMs": 4_102_444_800_000,
                "state": "recycled" if index == 0 else "failed",
                "errorCode": None if index == 0 else "sourceChanged",
                "resolution": "photosManagedBySystem" if index == 0 else "retryInterruptedOperation",
                "availableActions": [] if index == 0 else ["retryInterruptedOperation"],
                "favorite": favorite_state(asset_id),
            } for index, (entry_id, asset_id) in enumerate(
                zip(SLIMMING_RECYCLE_IDS, ASSET_IDS)
            )]
            scope_counts = {
                "all": len(entries),
                "photos": sum(entry["sourceKind"] == "photos" for entry in entries),
                "files": sum(entry["sourceKind"] == "file" for entry in entries),
                "attention": sum(entry["state"] != "recycled" for entry in entries),
            }
            if scope == "photos":
                visible_entries = [entry for entry in entries if entry["sourceKind"] == "photos"]
            elif scope == "files":
                visible_entries = [entry for entry in entries if entry["sourceKind"] == "file"]
            elif scope == "attention":
                visible_entries = [entry for entry in entries if entry["state"] != "recycled"]
            else:
                visible_entries = entries
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

        page.route("**/v1/library-slimming/recycle?**", handle_slimming_recycle)
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
        page.locator("#selectionModeButton").click()
        cards = page.locator("#assetGrid > .asset-card")
        assert cards.count() == 2
        cards.nth(0).click()
        cards.nth(1).click(modifiers=["Meta"])
        assert "已选择 2 项" in page.locator("#selectionSummary").inner_text()
        page.locator("#selectionInspector:not(.hidden)").wait_for()
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
        page.locator("#findSimilarSelectionButton").click()
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        assert submitted_slimming[-1]["mode"] == "seeds"
        assert submitted_slimming[-1]["sourceIDs"] is None
        assert set(submitted_slimming[-1]["seedAssetIDs"]) == set(ASSET_IDS)

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
        assert page.evaluate(
            "jobID => document.activeElement?.dataset.slimmingJobId === jobID",
            SLIMMING_SECOND_JOB_ID,
        )

        page.evaluate(
            "() => { window.__imageAllOriginalConfirm = window.confirm; "
            "window.confirm = () => false; }"
        )
        second_job.click(button="right")
        job_context_menu.locator('[data-slimming-job-context-action="deleteRecord"]').click()
        assert slimming_jobs.count() == 2
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.slimmingJobId === jobID",
            arg=SLIMMING_SECOND_JOB_ID,
        )
        page.evaluate("() => { window.confirm = () => true; }")
        second_job.click(button="right")
        job_context_menu.locator('[data-slimming-job-context-action="deleteRecord"]').click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingJobList [data-slimming-job-id]').length === 1"
        )
        assert submitted_slimming_job_actions[-1]["jobID"] == SLIMMING_SECOND_JOB_ID
        assert submitted_slimming_job_actions[-1]["action"] == "deleteRecord"
        assert page.locator(
            f'[data-slimming-job-id="{SLIMMING_JOB_ID}"]'
        ).get_attribute("aria-selected") == "true"
        page.evaluate(
            "() => { window.confirm = window.__imageAllOriginalConfirm; "
            "delete window.__imageAllOriginalConfirm; }"
        )

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
        first_slimming_main = slimming_cards.nth(0).locator(":scope > .slimming-member-main")
        second_slimming_main = slimming_cards.nth(1).locator(":scope > .slimming-member-main")
        first_slimming_main.click()
        second_slimming_main.click(modifiers=["Shift"])
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
        slimming_navigator_button.click()
        assert page.locator("#slimmingAnalysisBody").evaluate(
            "element => element.classList.contains('navigator-hidden')"
        )
        assert page.locator("#slimmingAnalysisBody > .slimming-job-pane").is_hidden()
        assert page.locator("#slimmingAnalysisBody > .slimming-cluster-pane").is_hidden()
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
        assert page.locator("#slimmingAnalysisBody > .slimming-job-pane").is_visible()
        assert page.locator("#slimmingAnalysisBody > .slimming-cluster-pane").is_visible()
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

        page.evaluate(
            "() => { window.__imageAllOriginalConfirm = window.confirm; "
            "window.confirm = () => false; }"
        )
        removal_count_before_cancel = len(submitted_slimming_removals)
        page.keyboard.press("Delete")
        page.wait_for_timeout(100)
        assert len(submitted_slimming_removals) == removal_count_before_cancel
        assert page.locator(
            "#slimmingMemberGrid > .slimming-member-card.selected"
        ).evaluate_all(
            "cards => cards.map(card => card.dataset.slimmingMemberId)"
        ) == selection_before_layout
        assert page.locator("#slimmingMemberGrid").evaluate(
            "element => element.scrollTop"
        ) == slimming_scroll_before_layout
        page.evaluate(
            "() => { window.confirm = window.__imageAllOriginalConfirm; "
            "delete window.__imageAllOriginalConfirm; }"
        )

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
        page.evaluate(
            "() => { window.__imageAllOriginalConfirm = window.confirm; "
            "window.confirm = () => false; }"
        )
        preview_removal_count_before_cancel = len(submitted_slimming_removals)
        page.keyboard.press("Delete")
        page.wait_for_timeout(100)
        assert len(submitted_slimming_removals) == preview_removal_count_before_cancel
        assert page.locator("#lightbox").is_visible()
        assert "SLIM_0002" in page.locator("#lightboxTitle").inner_text()
        assert page.locator("#slimmingMemberGrid > .slimming-member-card.selected").count() == 2
        page.evaluate(
            "() => { window.confirm = window.__imageAllOriginalConfirm; "
            "delete window.__imageAllOriginalConfirm; }"
        )
        page.keyboard.press("Delete")
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
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 2"
        )
        recycle_scope_buttons = page.locator(
            "#slimmingRecycleScopes [data-slimming-recycle-scope]"
        )
        assert recycle_scope_buttons.count() == 4
        assert page.locator(
            '[data-slimming-recycle-scope-count="all"]'
        ).inner_text() == "2"
        assert page.locator(
            '[data-slimming-recycle-scope-count="photos"]'
        ).inner_text() == "1"
        assert page.locator(
            '[data-slimming-recycle-scope-count="files"]'
        ).inner_text() == "1"
        assert page.locator(
            '[data-slimming-recycle-scope-count="attention"]'
        ).inner_text() == "1"

        page.locator("#slimmingRecycleSourceSelect").select_option(SOURCE_ID)
        page.locator("#slimmingRecycleSearchInput").fill("RECYCLE")
        page.wait_for_timeout(300)
        attention_scope = page.locator('[data-slimming-recycle-scope="attention"]')
        attention_scope.click()
        page.wait_for_function(
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 1"
        )
        assert "RECYCLE_0002" in page.locator(
            "#slimmingRecycleList .slimming-recycle-row"
        ).inner_text()
        assert page.locator("#slimmingRecycleSourceSelect").input_value() == SOURCE_ID
        assert page.locator("#slimmingRecycleSearchInput").input_value() == "RECYCLE"
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
            "() => document.querySelectorAll('#slimmingRecycleList .slimming-recycle-row').length === 2"
        )
        page.locator("#slimmingRecycleSearchInput").fill("")
        page.locator("#slimmingRecycleSourceSelect").select_option("")
        page.wait_for_timeout(300)

        assert page.locator("#slimmingRecycleList .slimming-recycle-video-badge").count() == 2
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
        assert recycle_rows.count() == 2
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
        slimming_navigator_button.click()
        assert page.locator("#slimmingAnalysisBody").evaluate(
            "element => getComputedStyle(element).gridTemplateRows"
        ) != "120px 120px 0px"
        page.screenshot(path="/tmp/imageall-slimming-analysis-navigator-hidden-390.png", full_page=True)
        slimming_navigator_button.click()
        assert page.locator("#refreshSlimmingButton").is_visible()
        page.screenshot(path="/tmp/imageall-slimming-analysis-390.png", full_page=True)

        page.locator("#closeSlimmingButton").click()
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

        assert not page_errors, page_errors
        assert not console_errors, {"console": console_errors, "resources": failed_resources}
        browser.close()

    print(
        "selection tools browser flow passed; "
        f"preparations={len(submitted_preparations)}; "
        f"suggestions={len(submitted_sample_suggestions)}; slimming={len(submitted_slimming)}; "
        f"slimming reviews={len(submitted_slimming_cluster_reviews)}; "
        f"slimming job actions={len(submitted_slimming_job_actions)}; "
        f"slimming removals={len(submitted_slimming_removals)}; "
        f"tag decisions={len(submitted_tag_decisions)}; favorites={len(submitted_favorites)}; "
        f"favorite retries={len(submitted_favorite_retries)}"
    )


if __name__ == "__main__":
    main()
