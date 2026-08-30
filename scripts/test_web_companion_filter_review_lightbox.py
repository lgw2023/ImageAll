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
NEW_REVIEW_TAG_ID = "dddddddd-2222-3333-4444-dddddddddddd"
SUBJECT_GROUP_ID = "eeeeeeee-1111-2222-3333-eeeeeeeeeeee"
SCENE_GROUP_ID = "ffffffff-1111-2222-3333-ffffffffffff"
IMAGE_IDS = [
    "11111111-1111-1111-1111-111111111111",
    "22222222-2222-2222-2222-222222222222",
]
IMAGE_PAGE_2_IDS = [
    f"10000000-0000-4000-8000-{index:012d}" for index in range(1, 17)
]
REVIEW_IDS = [
    "33333333-3333-3333-3333-333333333333",
    "44444444-4444-4444-4444-444444444444",
    "55555555-5555-5555-5555-555555555555",
]
VIDEO_ID = "66666666-6666-6666-6666-666666666666"
VIDEO_PAGE_2_IDS = [
    f"20000000-0000-4000-8000-{index:012d}" for index in range(1, 17)
]
SUGGESTION_TAG_IDS = [
    f"77777777-7777-7777-7777-77777777777{index}" for index in range(6)
]
LOCAL_SUGGESTION_IDS = ["personal:cat", "personal:travel"]
PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
PREVIEW_SVG_BYTES = b"""\
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="900" viewBox="0 0 1200 900">
  <defs>
    <linearGradient id="sky" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#14384a"/>
      <stop offset="0.55" stop-color="#3a7c78"/>
      <stop offset="1" stop-color="#d59b61"/>
    </linearGradient>
    <linearGradient id="water" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1e5d67"/>
      <stop offset="1" stop-color="#071c26"/>
    </linearGradient>
  </defs>
  <rect width="1200" height="900" fill="url(#sky)"/>
  <circle cx="930" cy="190" r="92" fill="#ffe0a6" opacity="0.92"/>
  <path d="M0 510 225 230 430 500 650 175 910 515 1200 295 1200 650 0 650Z" fill="#102d35"/>
  <path d="M0 565 255 370 460 590 710 315 970 590 1200 420 1200 690 0 690Z" fill="#1b4d4d"/>
  <rect y="630" width="1200" height="270" fill="url(#water)"/>
  <path d="M0 705 C220 650 350 770 570 705 S930 650 1200 720" fill="none" stroke="#cde1d2" stroke-width="10" opacity="0.42"/>
  <g fill="#f7f2e8" font-family="-apple-system, BlinkMacSystemFont, sans-serif">
    <text x="54" y="82" font-size="28" font-weight="700" letter-spacing="3">IMAGEALL SYNTHETIC PREVIEW</text>
    <text x="55" y="119" font-size="18" opacity="0.76">1200 x 900 / safe browser fixture</text>
  </g>
  <g transform="translate(1060 760)" fill="#ffbd59">
    <circle r="56" opacity="0.92"/>
    <path d="M-26-24-9-44 2-23 21-45 35-18V22H-35V-18Z" fill="#173540"/>
    <circle cx="-14" cy="0" r="5" fill="#ffbd59"/>
    <circle cx="16" cy="0" r="5" fill="#ffbd59"/>
  </g>
</svg>
"""


def original_thumbnail_svg(asset_id):
    dimensions = {
        REVIEW_IDS[0]: (1200, 900),
        REVIEW_IDS[1]: (900, 1200),
        # The Host intentionally falls back to the existing square thumbnail
        # when an original-aspect cache has not been generated yet. Web must
        # keep this item square, matching the Mac grid instead of stretching a
        # square fallback into the asset metadata ratio.
        REVIEW_IDS[2]: (512, 512),
    }
    width, height = dimensions.get(asset_id, (1200, 900))
    return f"""\
<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">
  <rect width="{width}" height="{height}" fill="#183d4a"/>
  <path d="M0 {height * 0.72:.0f} L{width * 0.34:.0f} {height * 0.22:.0f} L{width * 0.58:.0f} {height * 0.68:.0f} L{width} {height * 0.3:.0f} V{height} H0Z" fill="#4d8a78"/>
  <text x="{width * 0.05:.0f}" y="{height * 0.1:.0f}" fill="#f5e4b8" font-size="{max(18, width * 0.035):.0f}">ORIGINAL {width} × {height}</text>
</svg>
""".encode("utf-8")
MP4_BYTES = base64.b64decode(
    "AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAMzbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAAD6AAAAZAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAl10cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAAZAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAABAAAAAQAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAGQAAAAAAABAAAAAAHVbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAAEABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAABgG1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAUBzdGJsAAAAuHN0c2QAAAAAAAAAAQAAAKhhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAABAAEABIAAAASAAAAAAAAAABFUxhdmM2Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALmF2Y0MBQsAK/+EAFmdCwArZHsBEAAADAAQAAAMAUDxImSABAAVoy4PLIAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAADRsAAAAAAAAABhzdHRzAAAAAAAAAAEAAAAEAAAEAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAAEAAAAAQAAACRzdHN6AAAAAAAAAAAAAAAEAAACgwAAAAkAAAAKAAAACQAAABRzdGNvAAAAAAAAAAEAAANjAAAAYnVkdGEAAABabWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9vAAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAAAqdtZGF0AAACcQYF//9t3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MToweDExMSBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhyZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJhPTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MjUwIGtleWludF9taW49MTAgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVzaD0wIHJjX2xvb2thaGVhZD00MCByYz1jcmYgbWJ0cmVlPTEgY3JmPTIzLjAgcWNvbXA9MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MToxLjAwAIAAAAAKZYiED/JigADD7gAAAAVBmjgf6gAAAAZBmlQHeoAAAAAFQZpgN9Q="
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
    assert container.evaluate("element => element.scrollHeight > element.clientHeight")
    start_point = page.evaluate(
        """([containerSelector, gridSelector]) => {
          const container = document.querySelector(containerSelector);
          const grid = document.querySelector(gridSelector);
          const containerRect = container.getBoundingClientRect();
          const gridRect = grid.getBoundingClientRect();
          const top = Math.max(containerRect.top + 2, gridRect.top + 2);
          const bottom = Math.min(containerRect.bottom - 2, gridRect.bottom - 2);
          const left = Math.max(containerRect.left + 2, gridRect.left + 2);
          const right = Math.min(containerRect.right - 2, gridRect.right - 2);
          for (let y = top; y <= Math.min(bottom, top + 80); y += 2) {
            for (let x = left; x <= right; x += 2) {
              const target = document.elementFromPoint(x, y);
              if (target && grid.contains(target) && !target.closest('.review-card')) {
                return { x, y };
              }
            }
          }
          return null;
        }""",
        [container_selector, grid_selector],
    )
    assert start_point is not None
    start_x = start_point["x"]
    start_y = start_point["y"]
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
    # Chromium can coalesce the last pointermove with an animation-frame scroll.
    # Emit one final in-bounds move so the assertion observes the selection at
    # the settled scroll offset rather than the rectangle from the prior frame.
    page.mouse.move(end_x - 1, end_y - 1)
    page.wait_for_timeout(50)
    selection_before_refresh = page.evaluate(
        "() => [...state.review.selectedAssetIDs]"
    )
    page.evaluate(
        """() => {
          void loadReviewQueue({
            preserveUnchangedGrid: true,
            preserveLoadedWindow: true,
          });
        }"""
    )
    page.wait_for_function("() => state.review.deferredQueueRefresh === true")
    assert page.locator("#reviewGrid .marquee-candidate").count() > 0
    page.mouse.up()
    page.wait_for_function(
        "() => !state.review.deferredQueueRefresh && !state.review.loading"
    )
    return scrolled, selection_before_refresh


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
        "relativePath": f"Trips/{file_name}",
        "mediaCreatedAtMs": 1_700_000_000_000,
        "mediaModifiedAtMs": 1_700_000_100_000,
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
    dimensions = [(1200, 900), (900, 1200), (1600, 900)]
    width, height = dimensions[index - 1]
    return {
        "assetID": asset_id,
        "fileName": f"REVIEW_{index}.JPG",
        "availability": "available",
        "contentRevision": index,
        "acceptedTagCount": 0,
        "rejectedTagCount": 0,
        "suggestionOrigin": "featurePrint",
        "score": 0.92 - index * 0.03,
        "width": width,
        "height": height,
    }


def main():
    asset_queries = []
    tag_decisions = []
    fail_next_tag_decision = [False]
    created_tag_applications = []
    review_decisions = []
    review_queue_queries = []
    source_actions = []
    source_requests = []
    complete_next_refresh_all_without_job = [False]
    media_requests = []
    preview_requests = []
    opened_originals = []
    favorite_mutations = []
    submitted_review_removals = []
    review_removal = {"request": None}
    hidden_gallery_asset_ids = set()
    thumbnail_queries = []
    workspace_notice_requests = []
    workspace_notice_fail_next = [False]
    workspace_notice_actions = []
    recycle_queries = []
    storage_requests = []
    local_suggestion_requests = []
    storage_snapshot = {
        "previewCache": {"entryCount": 12, "registeredBytes": 1_500_000},
        "photosOriginals": {"entryCount": 3, "registeredBytes": 9_000_000},
        "clearPreviewCacheAvailability": {"isAvailable": True, "reason": None},
        "clearPhotosOriginalsAvailability": {
            "isAvailable": False,
            "reason": "librarySlimmingAnalysisInProgress",
        },
        "appStorage": {
            "kind": "internalStorage",
            "requiresRestart": False,
            "pendingExternalRootName": None,
        },
        "requests": [],
    }
    catalog_jobs = []
    catalog_job_fetches = [0]
    favorite_states = {
        asset_id: False
        for asset_id in IMAGE_IDS + IMAGE_PAGE_2_IDS + REVIEW_IDS
        + [VIDEO_ID] + VIDEO_PAGE_2_IDS
    }
    prewarm_poll_count = [0]
    cloud_preview_downloads = []
    page_errors = []
    console_errors = []
    http_errors = []
    review_items = [review_item(asset_id, index + 1) for index, asset_id in enumerate(REVIEW_IDS)]
    review_pending_override = [None]
    review_task = {
        "taskStatus": "completed",
        "checkedCount": 12,
        "totalCount": 12,
        "skippedCount": 0,
    }

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
                    "capabilities": [
                        "sourceManagement",
                        "favorites",
                        "librarySlimming",
                        "workspaceNotices",
                        "assetLocalSuggestions",
                    ],
                },
            ),
        )
        sources = [{
            "id": SOURCE_ID,
            "kind": "photos",
            "displayName": "Apple Photos",
            "state": "active",
        }]
        source_management_sources = sources + [
            {
                "id": "55555555-aaaa-bbbb-cccc-555555555555",
                "kind": "folder",
                "displayName": "Needs Access",
                "state": "authorizationRequired",
            },
            {
                "id": "66666666-aaaa-bbbb-cccc-666666666666",
                "kind": "folder",
                "displayName": "Active Folder",
                "state": "active",
            },
        ]
        tags = [
            {"id": CAT_TAG_ID, "displayName": "猫", "state": "active", "groupID": SUBJECT_GROUP_ID},
            {"id": TRAVEL_TAG_ID, "displayName": "旅行", "state": "active", "groupID": SCENE_GROUP_ID},
        ]
        page.route("**/v1/sources", lambda route: fulfill_json(route, sources))
        workspace_notice = {
            "id": "notice-source-recycle",
            "severity": "warning",
            "message": "“Apple Photos”仍有待处理回收项目，来源尚未删除。",
            "actions": [{
                "id": "openRecycleBin",
                "kind": "openRecycleBin",
                "title": "前往回收站",
                "sourceID": SOURCE_ID,
            }],
        }
        def route_workspace_notice(route):
            workspace_notice_requests.append(route.request.url)
            if workspace_notice_fail_next[0]:
                workspace_notice_fail_next[0] = False
                fulfill_json(route, {"error": "noticeUnavailable"}, status=503)
                return
            fulfill_json(route, {"notice": workspace_notice or None})

        page.route("**/v1/workspace-notice", route_workspace_notice)

        def route_workspace_notice_action(route):
            payload = route.request.post_data_json
            workspace_notice_actions.append(payload)
            action_ids = {
                action["id"] for action in workspace_notice.get("actions", [])
            }
            performed = (
                payload.get("noticeID") == workspace_notice.get("id")
                and payload.get("actionID") in action_ids
            )
            if len(workspace_notice_actions) == 1 and payload.get("actionID") == "openRecycleBin":
                workspace_notice["id"] = "notice-source-recycle-new"
                performed = False
            if performed and payload.get("actionID") == "undoTagMutation":
                workspace_notice.clear()
            fulfill_json(route, {
                "performed": performed,
                "notice": workspace_notice or None,
            })

        page.route("**/v1/workspace-notice/action", route_workspace_notice_action)

        def route_slimming_recycle(route):
            query = parse_qs(urlparse(route.request.url).query)
            recycle_queries.append(query)
            fulfill_json(route, {
                "mediaKind": query.get("mediaKind", ["image"])[0],
                "entries": [],
                "totalCount": 0,
                "scopeCounts": {"all": 0, "photos": 0, "files": 0, "attention": 0},
                "requests": [],
            })

        page.route("**/v1/library-slimming/recycle?**", route_slimming_recycle)
        page.route(
            "**/v1/library-slimming/workspace?**",
            lambda route: fulfill_json(route, {
                "mediaKind": "image",
                "jobs": [],
                "totalJobCount": 0,
                "selectedJobID": None,
                "clusters": [],
                "selectedClusterID": None,
                "members": [],
                "pendingAnalysisCount": 0,
                "analyzedAssetCount": 0,
                "policyVersion": "librarySlimming.v1",
                "clusterScopeCounts": {
                    "pending": 0,
                    "confirmed": 0,
                    "ignored": 0,
                },
            }),
        )
        page.route("**/v1/tags", lambda route: fulfill_json(route, tags))
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(route, [
                {"id": SUBJECT_GROUP_ID, "displayName": "主体", "sortOrder": 0},
                {"id": SCENE_GROUP_ID, "displayName": "场景", "sortOrder": 1},
            ]),
        )
        def route_jobs(route):
            catalog_job_fetches[0] += 1
            if catalog_jobs and catalog_jobs[0]["state"] == "running":
                catalog_jobs[0]["progress"]["completedUnitCount"] = min(
                    10,
                    2 + catalog_job_fetches[0] * 2,
                )
            fulfill_json(route, catalog_jobs)

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
                {"sources": source_management_sources, "canConnectPhotos": False, "requests": source_requests},
            )

        page.route("**/v1/source-management", route_source_management)

        def route_source_action(route):
            payload = route.request.post_data_json
            source_actions.append(payload)
            if payload["action"] in {"syncPhotos", "rescan"}:
                request = {
                    "id": "77777777-9999-4999-8999-777777777777",
                    "operationID": payload["operationID"],
                    "action": payload["action"],
                    "sourceID": payload.get("sourceID"),
                    "sourceDisplayName": "Apple Photos",
                    "phase": "completed",
                    "message": "已交给 Mac 更新来源",
                    "completedCount": None,
                    "totalCount": None,
                    "warmedCount": None,
                    "failedCount": None,
                    "updatedAtMs": 1_700_000_000_550,
                }
                source_requests.insert(0, request)
                fulfill_json(route, request)
                return
            if payload["action"] == "refreshAll":
                if complete_next_refresh_all_without_job[0]:
                    complete_next_refresh_all_without_job[0] = False
                else:
                    catalog_jobs[:] = [{
                        "id": "aaaaaaaa-9999-4000-8000-aaaaaaaaaaaa",
                        "sourceID": SOURCE_ID,
                        "sourceDisplayName": "Apple Photos",
                        "kind": "photosReconcile",
                        "state": "running",
                        "progress": {"completedUnitCount": 2, "totalUnitCount": 14},
                        "availableActions": ["pause", "cancel"],
                        "controlRequest": "none",
                    }]
                request = {
                    "id": "88888888-9999-9999-9999-999999999999",
                    "operationID": payload["operationID"],
                    "action": "refreshAll",
                    "sourceID": None,
                    "sourceDisplayName": "全部来源",
                    "phase": "completed",
                    "message": "已为 1 个活跃来源排入更新任务",
                    "completedCount": None,
                    "totalCount": None,
                    "warmedCount": None,
                    "failedCount": None,
                    "updatedAtMs": 1_700_000_000_600,
                }
                source_requests.insert(0, request)
                fulfill_json(route, request)
                return
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
            is_all_sources = payload["action"] in {
                "prewarmAllThumbnails", "prewarmAllOriginalAspect"
            }
            is_batch_authorization = payload["action"] in {
                "reauthorizeAll", "refreshAllFolderMutationAuthorizations"
            }
            message = (
                "正在预热 Apple Photos 的网格缩略图 0 / 3"
                if phase == "running"
                else "请在 Mac 上完成当前来源授权"
                if is_batch_authorization
                else "等待 Mac 确认"
            )
            request = {
                "id": "99999999-9999-9999-9999-999999999999",
                "operationID": payload["operationID"],
                "action": payload["action"],
                "sourceID": payload.get("sourceID"),
                "sourceDisplayName": "全部来源"
                if is_all_sources or is_batch_authorization else "Apple Photos",
                "phase": phase,
                "message": message,
                "completedCount": 0 if phase == "running" else None,
                "totalCount": 3 if phase == "running" else None,
                "warmedCount": 0 if phase == "running" else None,
                "failedCount": 0 if phase == "running" else None,
                "reusedCount": 1 if is_all_sources else 0 if phase == "running" else None,
                "ineligibleCount": 1 if is_all_sources else 0 if phase == "running" else None,
                "completedSourceCount": 0
                if is_all_sources or is_batch_authorization else None,
                "totalSourceCount": 2
                if is_all_sources or is_batch_authorization else None,
                "updatedAtMs": 1_700_000_000_000,
            }
            source_requests[:] = [request]
            fulfill_json(
                route,
                request,
            )

        page.route("**/v1/source-management/requests", route_source_action)

        def route_storage_maintenance(route):
            fulfill_json(route, storage_snapshot)

        def route_storage_maintenance_request(route):
            payload = route.request.post_data_json
            storage_requests.append(payload)
            fulfill_json(
                route,
                {
                    "id": "99999999-9999-4999-8999-999999999999",
                    "operationID": payload["operationID"],
                    "action": payload["action"],
                    "phase": "awaitingMac",
                    "message": "请回到 Mac 确认清理操作",
                    "updatedAtMs": 1_700_000_000_900,
                    "result": None,
                },
                status=202,
            )

        page.route(
            "**/v1/storage-maintenance/requests",
            route_storage_maintenance_request,
        )
        page.route("**/v1/storage-maintenance", route_storage_maintenance)

        def route_assets(route):
            query = parse_qs(urlparse(route.request.url).query)
            asset_queries.append(query)
            if query.get("q") == ["不存在"]:
                items = []
                next_cursor = None
            elif query.get("mediaKinds") == ["video"]:
                if query.get("cursor") == ["video-page-2"]:
                    items = [
                        asset_summary(asset_id, f"CLIP_{index + 2:04d}.MP4", "public.mpeg-4")
                        for index, asset_id in enumerate(VIDEO_PAGE_2_IDS)
                    ]
                    next_cursor = None
                else:
                    items = [asset_summary(VIDEO_ID, "CLIP_0001.MP4", "public.mpeg-4")]
                    next_cursor = "video-page-2"
            else:
                if query.get("cursor") == ["image-page-2"]:
                    items = [
                        asset_summary(asset_id, f"PHOTO_{index + 3:04d}.JPG")
                        for index, asset_id in enumerate(IMAGE_PAGE_2_IDS)
                    ]
                    next_cursor = None
                else:
                    items = [
                        asset_summary(IMAGE_IDS[0], "CAT_0001.JPG"),
                        asset_summary(IMAGE_IDS[1], "TRIP_0002.JPG"),
                    ]
                    next_cursor = "image-page-2"
            for item in items:
                item["favorite"] = {
                    "assetID": item["id"],
                    "isFavorite": favorite_states[item["id"]],
                    "photosObservedValue": favorite_states[item["id"]],
                    "syncStatus": "synced",
                    "lastErrorCode": None,
                }
            items = [
                item for item in items
                if item["id"] not in hidden_gallery_asset_ids
            ]
            fulfill_json(route, {"items": items, "nextCursor": next_cursor})

        page.route("**/v1/assets?**", route_assets)

        def route_asset_detail(route):
            asset_id = urlparse(route.request.url).path.rsplit("/", 1)[-1]
            if asset_id == VIDEO_ID:
                detail = asset_detail(asset_id, "CLIP_0001.MP4", "public.mpeg-4")
            elif asset_id in VIDEO_PAGE_2_IDS:
                detail = asset_detail(
                    asset_id,
                    f"CLIP_{VIDEO_PAGE_2_IDS.index(asset_id) + 2:04d}.MP4",
                    "public.mpeg-4",
                )
            elif asset_id in REVIEW_IDS:
                review_index = REVIEW_IDS.index(asset_id)
                detail = asset_detail(
                    asset_id,
                    f"REVIEW_{review_index + 1}.JPG",
                )
                detail["contentRevision"] = review_index + 1
            elif asset_id in IMAGE_PAGE_2_IDS:
                detail = asset_detail(
                    asset_id,
                    f"PHOTO_{IMAGE_PAGE_2_IDS.index(asset_id) + 3:04d}.JPG",
                )
            elif asset_id in IMAGE_IDS:
                index = IMAGE_IDS.index(asset_id) + 1
                detail = asset_detail(asset_id, f"PHOTO_{index:04d}.JPG")
            else:
                detail = asset_detail(asset_id, "PHOTO_DETAIL.JPG")
            detail["favorite"] = {
                "assetID": asset_id,
                "isFavorite": favorite_states[asset_id],
                "photosObservedValue": favorite_states[asset_id],
                "syncStatus": "synced",
                "lastErrorCode": None,
            }
            for application in created_tag_applications:
                if asset_id not in application["assetIDs"]:
                    continue
                detail["tags"].append({
                    "tagID": NEW_REVIEW_TAG_ID,
                    "displayName": application["name"],
                    "decision": "accepted",
                })
                detail["acceptedTagCount"] += 1
            fulfill_json(route, detail)

        page.route(re.compile(r".*/v1/assets/[0-9a-f-]+$"), route_asset_detail)

        def route_local_suggestions(route):
            payload = route.request.post_data_json
            asset_id = urlparse(route.request.url).path.split("/")[-2]
            local_suggestion_requests.append({"assetID": asset_id, **payload})
            suggestions = [
                {
                    "id": suggestion_id,
                    "track": payload["track"],
                    "tagID": tag_id,
                    "displayName": display_name,
                    "recommendation": "suggested",
                }
                for suggestion_id, tag_id, display_name in [
                    (LOCAL_SUGGESTION_IDS[0], CAT_TAG_ID, "猫"),
                    (LOCAL_SUGGESTION_IDS[1], TRAVEL_TAG_ID, "旅行"),
                ]
            ]
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "assetID": asset_id,
                    "track": payload["track"],
                    "state": "results",
                    "suggestions": suggestions,
                    "replayed": False,
                },
            )

        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/local-suggestions$"),
            route_local_suggestions,
        )

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

        def route_review_removal(route):
            if route.request.method == "POST":
                payload = route.request.post_data_json
                submitted_review_removals.append(payload)
                canonical_ids = sorted(set(payload["assetIDs"]))
                review_removal["request"] = {
                    "id": (
                        "aaaaaaaa-4444-5555-6666-"
                        f"{len(submitted_review_removals):012d}"
                    ),
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
                    "message": "请回到 Mac 核对并确认删除审核选区",
                    "updatedAtMs": 1_700_000_020_000,
                }
                fulfill_json(route, review_removal["request"], status=202)
                return
            fulfill_json(route, {
                "mediaKind": "image",
                "requests": [review_removal["request"]]
                if review_removal["request"] else [],
            })

        page.route("**/v1/library-slimming/removals", route_review_removal)
        page.route("**/v1/library-slimming/removals?**", route_review_removal)
        page.route(
            "**/v1/library-slimming/identical-cleanup/requests?**",
            lambda route: fulfill_json(route, {
                "mediaKind": "video" if "mediaKind=video" in route.request.url else "image",
                "requests": [],
            }),
        )

        def route_asset_image(route):
            parsed = urlparse(route.request.url)
            path = parsed.path
            asset_id = path.split("/")[-2]
            if path.endswith("/preview") and asset_id == IMAGE_IDS[1] \
                    and asset_id not in cloud_preview_downloads:
                fulfill_json(
                    route,
                    {"code": "conflict", "message": "cloud preview required"},
                    status=409,
                )
                return
            if path.endswith("/preview"):
                preview_requests.append(route.request.url)
                route.fulfill(
                    status=200,
                    content_type="image/svg+xml; charset=utf-8",
                    body=PREVIEW_SVG_BYTES,
                )
                return
            query = parse_qs(parsed.query)
            thumbnail_queries.append({
                "assetID": asset_id,
                "aspect": query.get("aspect", ["square"])[0],
            })
            if query.get("aspect") == ["original"]:
                route.fulfill(
                    status=200,
                    content_type="image/svg+xml; charset=utf-8",
                    body=original_thumbnail_svg(asset_id),
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

        viewed_originals = []
        original_failures = set()

        def route_view_original(route):
            assert route.request.method == "GET"
            asset_id = urlparse(route.request.url).path.split("/")[-2]
            viewed_originals.append(asset_id)
            if asset_id in original_failures:
                fulfill_json(
                    route,
                    {"code": "conflict", "message": "合成原图当前不可用"},
                    status=409,
                )
                return
            route.fulfill(
                status=200,
                content_type="image/svg+xml",
                headers={"Accept-Ranges": "bytes", "Cache-Control": "no-store"},
                body=original_thumbnail_svg(asset_id),
            )

        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/original(\?.*)?$"),
            route_view_original,
        )

        def route_open_original(route):
            assert route.request.method == "POST"
            opened_originals.append(urlparse(route.request.url).path.split("/")[-2])
            fulfill_json(route, {"opened": True})

        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/open-original$"),
            route_open_original,
        )

        def route_tag_decision(route):
            payload = route.request.post_data_json
            tag_decisions.append(payload)
            if fail_next_tag_decision[0]:
                fail_next_tag_decision[0] = False
                fulfill_json(
                    route,
                    {"code": "conflict", "message": "synthetic tag decision denied"},
                    status=409,
                )
                return
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

        def route_tag_selection(route):
            payload = route.request.post_data_json
            asset_ids = payload["assetIDs"]
            aggregates = []
            for tag_id in payload["tagIDs"]:
                created = next((
                    application for application in created_tag_applications
                    if tag_id == NEW_REVIEW_TAG_ID
                ), None)
                accepted_count = sum(
                    1 for asset_id in asset_ids
                    if tag_id == CAT_TAG_ID
                    or (created is not None and asset_id in created["assetIDs"])
                )
                aggregates.append({
                    "tagID": tag_id,
                    "acceptedCount": accepted_count,
                    "rejectedCount": 0,
                    "unknownCount": len(asset_ids) - accepted_count,
                })
            fulfill_json(route, aggregates)

        page.route("**/v1/tags/selection", route_tag_selection)

        def route_create_tag_and_apply(route):
            payload = route.request.post_data_json
            application = {
                "name": payload["name"],
                "assetIDs": payload["assetIDs"],
            }
            created_tag_applications.append(application)
            if not any(tag["id"] == NEW_REVIEW_TAG_ID for tag in tags):
                tags.append({
                    "id": NEW_REVIEW_TAG_ID,
                    "displayName": payload["name"],
                    "state": "active",
                    "groupID": SUBJECT_GROUP_ID,
                })
            fulfill_json(route, {
                "operationID": payload["operationID"],
                "tagID": NEW_REVIEW_TAG_ID,
                "displayName": payload["name"],
                "appliedAssetCount": len(payload["assetIDs"]),
                "replayed": False,
                "undoID": "99999999-9999-9999-9999-999999999999",
            })

        page.route("**/v1/tags/create-and-apply", route_create_tag_and_apply)
        def route_review_overview(route):
            pending_count = review_pending_override[0]
            if pending_count is None:
                pending_count = len(review_items)
            fulfill_json(route, {
                "totalPendingSuggestionCount": pending_count,
                "tags": [{
                    "id": CAT_TAG_ID,
                    "displayName": "猫",
                    "acceptedSampleCount": 8,
                    "rejectedSampleCount": 4,
                    "pendingSuggestionCount": pending_count,
                    "pendingSuggestionCounts": {
                        "featurePrint": pending_count,
                        "standardModel": 0,
                        "personalModel": 0,
                        "personalAdamW": 0,
                    },
                    **review_task,
                    "missingPositiveCount": 0,
                    "missingNegativeCount": 0,
                    "canReview": pending_count > 0,
                }],
            })

        page.route("**/v1/review/overview?**", route_review_overview)
        def route_review_queue(route):
            query = parse_qs(urlparse(route.request.url).query)
            review_queue_queries.append(query)
            items = projected_review_items()
            if query.get("cursor") == ["review-page-2"]:
                fulfill_json(route, {"items": items[1:], "nextCursor": None})
            elif len(items) > 1:
                fulfill_json(
                    route,
                    {"items": items[:1], "nextCursor": "review-page-2"},
                )
            else:
                fulfill_json(route, {"items": items, "nextCursor": None})

        page.route("**/v1/review/queue?**", route_review_queue)

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

        library_image_tab = page.locator('#mediaKindTabs [data-media-kind="image"]')
        library_video_tab = page.locator('#mediaKindTabs [data-media-kind="video"]')
        assert library_image_tab.get_attribute("tabindex") == "0"
        assert library_video_tab.get_attribute("tabindex") == "-1"
        library_image_tab.focus()
        page.keyboard.press("End")
        page.wait_for_function("() => state.mediaKind === 'video' && !state.loadingAssets")
        assert page.evaluate(
            "() => document.activeElement?.dataset.mediaKind"
        ) == "video"
        assert library_video_tab.get_attribute("aria-pressed") == "true"
        assert library_video_tab.get_attribute("tabindex") == "0"
        assert library_image_tab.get_attribute("tabindex") == "-1"
        page.keyboard.press("Home")
        page.wait_for_function("() => state.mediaKind === 'image' && !state.loadingAssets")
        assert page.evaluate(
            "() => document.activeElement?.dataset.mediaKind"
        ) == "image"
        assert library_image_tab.get_attribute("aria-pressed") == "true"

        interaction_poll_asset_queries = len(asset_queries)
        interaction_poll_probe = page.evaluate(
            """() => {
              const before = state.lastWorkspaceInteractionAt;
              document.body.dispatchEvent(new PointerEvent("pointerdown", {
                bubbles: true,
                cancelable: true,
              }));
              scheduleProjectionPoll(state.socketGeneration, 20);
              return {
                before,
                after: state.lastWorkspaceInteractionAt,
              };
            }"""
        )
        assert interaction_poll_probe["after"] > interaction_poll_probe["before"]
        page.wait_for_timeout(100)
        assert len(asset_queries) == interaction_poll_asset_queries
        assert page.evaluate("() => state.accountPollTimer != null")
        page.evaluate("() => scheduleProjectionPoll(state.socketGeneration)")

        stable_notice_requests = len(workspace_notice_requests)
        page.evaluate(
            """() => {
              const banner = document.querySelector("#workspaceNoticeBanner");
              const action = banner.querySelector(
                '[data-workspace-notice-action-id="openRecycleBin"]'
              );
              const mutations = [];
              const observer = new MutationObserver((records) => mutations.push(...records));
              action.focus({ preventScroll: true });
              observer.observe(banner, {
                attributes: true,
                childList: true,
                characterData: true,
                subtree: true,
              });
              window.__stableWorkspaceNoticeFrame = {
                banner,
                message: document.querySelector("#workspaceNoticeMessage"),
                actions: document.querySelector("#workspaceNoticeActions"),
                action,
                dismiss: document.querySelector("#dismissWorkspaceNoticeButton"),
                mutations,
                observer,
              };
              document.querySelector("#refreshButton").click();
            }"""
        )
        page.wait_for_function("() => !state.refreshingWorkspace")
        assert len(workspace_notice_requests) == stable_notice_requests + 1
        stable_notice_refresh = page.evaluate(
            """() => {
              const frame = window.__stableWorkspaceNoticeFrame;
              frame.mutations.push(...frame.observer.takeRecords());
              frame.observer.disconnect();
              const action = document.querySelector(
                '[data-workspace-notice-action-id="openRecycleBin"]'
              );
              return {
                banner: document.querySelector("#workspaceNoticeBanner") === frame.banner,
                message: document.querySelector("#workspaceNoticeMessage") === frame.message,
                actions: document.querySelector("#workspaceNoticeActions") === frame.actions,
                action: action === frame.action,
                dismiss: document.querySelector("#dismissWorkspaceNoticeButton") === frame.dismiss,
                focus: document.activeElement === frame.action,
                mutations: frame.mutations.length === 0,
              };
            }"""
        )
        assert all(stable_notice_refresh.values()), stable_notice_refresh

        failed_notice_requests = len(workspace_notice_requests)
        workspace_notice_fail_next[0] = True
        page.evaluate("() => document.querySelector('#refreshButton').click()")
        page.wait_for_function("() => !state.refreshingWorkspace")
        assert len(workspace_notice_requests) == failed_notice_requests + 1
        failed_notice_refresh = page.evaluate(
            """() => {
              const frame = window.__stableWorkspaceNoticeFrame;
              const action = document.querySelector(
                '[data-workspace-notice-action-id="openRecycleBin"]'
              );
              return {
                banner: document.querySelector("#workspaceNoticeBanner") === frame.banner,
                message: document.querySelector("#workspaceNoticeMessage") === frame.message,
                actions: document.querySelector("#workspaceNoticeActions") === frame.actions,
                action: action === frame.action,
                focus: document.activeElement === frame.action,
              };
            }"""
        )
        assert all(failed_notice_refresh.values()), failed_notice_refresh
        page.evaluate(
            """() => {
              clearTimeout(state.refreshRetryTimer);
              state.refreshRetryTimer = null;
              state.pendingRefreshKinds.clear();
              state.refreshRetryAttempt = 0;
            }"""
        )

        original_workspace_notice = json.loads(json.dumps(workspace_notice))
        workspace_notice.clear()
        workspace_notice.update({
            "id": "notice-tag-preview",
            "severity": "success",
            "message": "已将 2 张照片标记为属于“猫”。",
            "actions": [{
                "id": "undoTagMutation",
                "kind": "undoTagMutation",
                "title": "撤销",
                "sourceID": None,
            }],
        })
        changed_notice_requests = len(workspace_notice_requests)
        page.evaluate("() => document.querySelector('#refreshButton').click()")
        page.wait_for_function("() => !state.refreshingWorkspace")
        assert len(workspace_notice_requests) == changed_notice_requests + 1
        changed_notice_refresh = page.evaluate(
            """() => {
              const frame = window.__stableWorkspaceNoticeFrame;
              const undo = document.querySelector(
                '[data-workspace-notice-action-id="undoTagMutation"]'
              );
              return {
                banner: document.querySelector("#workspaceNoticeBanner") === frame.banner,
                message: document.querySelector("#workspaceNoticeMessage") === frame.message,
                actions: document.querySelector("#workspaceNoticeActions") === frame.actions,
                oldActionRemoved: !frame.action.isConnected,
                undoAdded: Boolean(undo),
                focusMigrated: document.activeElement === undo,
                messageUpdated: frame.message.textContent.includes("2 张照片"),
                severityUpdated: frame.banner.dataset.severity === "success",
              };
            }"""
        )
        assert all(changed_notice_refresh.values()), changed_notice_refresh

        workspace_notice.clear()
        workspace_notice.update(original_workspace_notice)
        restored_notice_requests = len(workspace_notice_requests)
        page.evaluate("() => document.querySelector('#refreshButton').click()")
        page.wait_for_function("() => !state.refreshingWorkspace")
        assert len(workspace_notice_requests) == restored_notice_requests + 1
        page.wait_for_function(
            "() => document.activeElement?.dataset.workspaceNoticeActionId "
            "=== 'openRecycleBin'"
        )
        page.evaluate(
            """() => {
              window.__stableWorkspaceNoticeFrame.action = document.querySelector(
                '[data-workspace-notice-action-id="openRecycleBin"]'
              );
            }"""
        )

        page.locator('[data-workspace-notice-action-id="openRecycleBin"]').click()
        page.wait_for_function(
            "() => state.workspaceNotice.notice?.id === 'notice-source-recycle-new' "
            "&& !state.workspaceNotice.activeActionID"
        )
        updated_notice_action = page.evaluate(
            """() => {
              const frame = window.__stableWorkspaceNoticeFrame;
              const action = document.querySelector(
                '[data-workspace-notice-action-id="openRecycleBin"]'
              );
              return {
                action: action === frame.action,
                focus: document.activeElement === action,
                enabled: !action.disabled,
              };
            }"""
        )
        assert all(updated_notice_action.values()), updated_notice_action
        assert workspace_notice_actions[0] == {
            "noticeID": "notice-source-recycle",
            "actionID": "openRecycleBin",
        }
        page.locator('[data-workspace-notice-action-id="openRecycleBin"]').click()
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        assert workspace_notice_actions[1] == {
            "noticeID": "notice-source-recycle-new",
            "actionID": "openRecycleBin",
        }
        assert recycle_queries[-1].get("sourceID") == [SOURCE_ID]
        page.wait_for_function(
            "sourceID => document.querySelector('#slimmingRecycleSourceSelect').value === sourceID",
            arg=SOURCE_ID,
        )
        assert page.locator("#slimmingRecycleSourceSelect").input_value() == SOURCE_ID
        page.locator("#closeSlimmingButton").click()
        page.locator("#slimmingWorkspace.hidden").wait_for(state="attached")
        page.wait_for_function(
            "() => document.activeElement?.dataset.workspaceNoticeActionId === 'openRecycleBin'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        assert recycle_queries[-1].get("sourceID") == [SOURCE_ID]
        page.locator("#closeSlimmingButton").click()
        page.locator("#slimmingWorkspace.hidden").wait_for(state="attached")
        page.wait_for_function(
            "() => document.activeElement?.dataset.workspaceNoticeActionId === 'openRecycleBin'"
        )

        # A delete initiated from Web can fail after Mac approval when unresolved
        # recycle entries still exist. The terminal source request must immediately
        # refresh the Host notice and expose the same filtered recycle-bin action as Mac.
        workspace_notice.update({
            "id": "notice-source-delete-terminal",
            "severity": "warning",
            "message": "“Apple Photos”尚未删除，且没有在后台继续。回收站中还有 6 个项目待处理；请处理后重试。原照片没有被修改。",
            "actions": [{
                "id": "openRecycleBin",
                "kind": "openRecycleBin",
                "title": "前往回收站",
                "sourceID": SOURCE_ID,
            }],
        })
        source_requests[:] = [{
            "id": "77777777-7777-4777-8777-777777777777",
            "operationID": "77777777-7777-4777-8777-777777777778",
            "action": "delete",
            "sourceID": SOURCE_ID,
            "sourceDisplayName": "Apple Photos",
            "phase": "failed",
            "message": "来源仍有 6 条回收记录需要先在 Mac 端处理",
            "updatedAtMs": 1_700_000_000_700,
        }]
        page.evaluate("loadSourceManagement({ quiet: true, notifyTerminal: true })")
        page.wait_for_function(
            "() => state.workspaceNotice.notice?.id === 'notice-source-delete-terminal'"
        )
        assert page.locator("#workspaceNoticeMessage").inner_text().startswith(
            "“Apple Photos”尚未删除"
        )
        page.screenshot(path="/tmp/imageall-source-delete-blocker.png", full_page=True)
        page.locator('[data-workspace-notice-action-id="openRecycleBin"]').click()
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        assert workspace_notice_actions[-1] == {
            "noticeID": "notice-source-delete-terminal",
            "actionID": "openRecycleBin",
        }
        assert recycle_queries[-1].get("sourceID") == [SOURCE_ID]
        page.locator("#closeSlimmingButton").click()
        page.locator("#slimmingWorkspace.hidden").wait_for(state="attached")

        workspace_notice.update({
            "id": "notice-tag-undo",
            "severity": "success",
            "message": "已将 2 张照片标记为属于“猫”。",
            "actions": [{
                "id": "undoTagMutation",
                "kind": "undoTagMutation",
                "title": "撤销",
                "sourceID": None,
            }],
        })
        page.evaluate(
            "notice => { state.workspaceNotice.notice = notice; renderWorkspaceNotice(); }",
            workspace_notice,
        )
        page.locator('[data-workspace-notice-action-id="undoTagMutation"]').click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('已撤销最近一次标签操作')"
        )
        assert workspace_notice_actions[-1] == {
            "noticeID": "notice-tag-undo",
            "actionID": "undoTagMutation",
        }
        page.locator("#workspaceNoticeBanner.hidden").wait_for(state="attached")
        page.locator(f'[data-quick-tag-id="{CAT_TAG_ID}"]').click()
        page.locator("#activeFilterBar:not(.hidden)").wait_for()
        assert "猫 已确认" in page.locator("#activeFilterSummary").inner_text()
        assert any(query.get("acceptedTagIDs") == [CAT_TAG_ID] for query in asset_queries)

        page.locator("#filterButton").click()
        assert page.locator('#mediaTypeFilter input[value="jpeg2000"]').count() == 1
        assert page.locator('#mediaTypeFilter input[value="svg"]').count() == 1
        assert page.locator('#mediaTypeFilter input[value="pdfai"]').count() == 1
        assert page.locator('#mediaTypeFilter input[value="raw"]').count() == 1
        page.locator('#availabilityFilter input[value="available"]').check()
        page.locator('#availabilityFilter input[value="missing"]').check()
        page.locator('#mediaTypeFilter input[value="jpeg"]').check()
        page.locator('#mediaTypeFilter input[value="raw"]').check()
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        assert page.locator("#filterPopover").is_visible()
        assert page.evaluate("() => document.activeElement?.value") == "raw"
        page.set_viewport_size({"width": 390, "height": 844})
        filter_bounds = page.locator("#filterPopover").bounding_box()
        assert filter_bounds is not None
        assert filter_bounds["x"] >= 0
        assert filter_bounds["x"] + filter_bounds["width"] <= 390
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        page.screenshot(path="/tmp/imageall-filter-multiselect-390.png", full_page=True)
        filter_history_queries = len(asset_queries)
        filter_history_state = page.evaluate(
            """() => {
              const entry = history.state?.imageAllWorkspace;
              const filter = document.querySelector('#filterPopover');
              filter.style.paddingBottom = '320px';
              filter.scrollTop = 120;
              return {
                route: entry?.route,
                navigationLevel: entry?.navigationLevel,
                baseLevel: entry?.context?.filterBaseLevel,
                historyKeys: Object.keys(entry?.context || {}).sort(),
                serialized: JSON.stringify(entry),
                scrollTop: document.querySelector('#filterPopover').scrollTop,
              };
            }"""
        )
        assert filter_history_state["route"] == "gallery"
        assert filter_history_state["navigationLevel"] == "filter"
        assert filter_history_state["baseLevel"] == "workspace"
        assert filter_history_state["scrollTop"] > 0
        assert "filterFocusedControl" not in filter_history_state["serialized"]
        assert "filterScrollTop" not in filter_history_state["serialized"]
        assert "filterDraft" not in filter_history_state["serialized"]
        page.evaluate("() => history.back()")
        page.locator("#filterPopover").wait_for(state="hidden")
        page.wait_for_function("() => document.activeElement?.id === 'filterButton'")
        assert len(asset_queries) == filter_history_queries
        page.evaluate("() => history.forward()")
        page.locator("#filterPopover:not(.hidden)").wait_for()
        page.wait_for_function("() => document.activeElement?.value === 'raw'")
        assert page.evaluate(
            "() => document.querySelector('#filterPopover').scrollTop"
        ) == filter_history_state["scrollTop"]
        assert len(asset_queries) == filter_history_queries
        page.evaluate(
            "() => document.querySelector('#filterPopover').style.removeProperty('padding-bottom')"
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#applyFiltersButton").click()
        page.locator("#filterPopover").wait_for(state="hidden")
        page.locator("#activeFilterBar:not(.hidden)").wait_for()
        assert page.locator("#filterBadge").inner_text() == "5"
        filter_summary = page.locator("#activeFilterSummary").inner_text()
        assert "可用、文件缺失" in filter_summary
        assert "JPEG、RAW" in filter_summary
        assert any(
            query.get("availabilities") == ["available,missing"]
            and query.get("mediaTypes") == [
                "public.jpeg,com.fuji.raw-image,com.adobe.raw-image,public.camera-raw-image"
            ]
            for query in asset_queries
        )

        page.locator("#filterButton").click()
        page.locator("#clearAvailabilityFilter").click()
        page.locator("#clearMediaTypeFilter").click()
        page.locator("#filterTagSelect").select_option(TRAVEL_TAG_ID)
        page.locator("#filterTagDecision").select_option("rejected")
        page.locator("#addTagFilterButton").click()
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        page.evaluate(
            """() => {
              const filter = document.querySelector('#filterPopover');
              filter.style.maxHeight = '500px';
              filter.style.overflowY = 'auto';
              filter.style.paddingBottom = '1200px';
              filter.scrollTop = 120;
            }"""
        )
        cat_filter_button = page.locator(
            f'[data-remove-tag-filter="{CAT_TAG_ID}"]'
        )
        cat_filter_button_bounds = cat_filter_button.bounding_box()
        assert cat_filter_button_bounds is not None
        page.mouse.move(
            cat_filter_button_bounds["x"] + cat_filter_button_bounds["width"] / 2,
            cat_filter_button_bounds["y"] + cat_filter_button_bounds["height"] / 2,
        )
        filter_chip_scroll = page.evaluate(
            """(catTagID) => {
              const catButton = document.querySelector(
                `[data-remove-tag-filter="${catTagID}"]`
              );
              const filter = document.querySelector('#filterPopover');
              catButton.focus({ preventScroll: true });
              window.__filterChipContinuityFrame = {
                catChip: catButton.closest('.filter-chip'),
                catButton,
              };
              return filter.scrollTop;
            }""",
            CAT_TAG_ID,
        )
        assert filter_chip_scroll > 0
        page.evaluate(
            """(travelTagID) => {
              document.querySelector(
                `[data-remove-tag-filter="${travelTagID}"]`
              ).click();
            }""",
            TRAVEL_TAG_ID,
        )
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        filter_chip_continuity = page.evaluate(
            """([catTagID, travelTagID, expectedScrollTop]) => {
              const frame = window.__filterChipContinuityFrame;
              const catButton = document.querySelector(
                `[data-remove-tag-filter="${catTagID}"]`
              );
              return {
                chip: catButton?.closest('.filter-chip') === frame.catChip,
                button: catButton === frame.catButton,
                focused: document.activeElement === catButton,
                hovered: catButton?.matches(':hover') || false,
                scroll: document.querySelector('#filterPopover').scrollTop === expectedScrollTop,
                travelRemoved: !document.querySelector(
                  `[data-remove-tag-filter="${travelTagID}"]`
                ),
              };
            }""",
            [CAT_TAG_ID, TRAVEL_TAG_ID, filter_chip_scroll],
        )
        assert filter_chip_continuity == {
            "chip": True,
            "button": True,
            "focused": True,
            "hovered": True,
            "scroll": True,
            "travelRemoved": True,
        }, filter_chip_continuity
        assert asset_queries[-1].get("acceptedTagIDs") == [CAT_TAG_ID]
        assert "rejectedTagIDs" not in asset_queries[-1]
        page.evaluate(
            """() => {
              const filter = document.querySelector('#filterPopover');
              filter.style.removeProperty('max-height');
              filter.style.removeProperty('overflow-y');
              filter.style.removeProperty('padding-bottom');
            }"""
        )
        page.locator("#filterTagSelect").select_option(TRAVEL_TAG_ID)
        page.locator("#filterTagDecision").select_option("rejected")
        page.locator("#addTagFilterButton").click()
        page.locator("#tagMatchMode").focus()
        page.locator("#tagMatchMode").select_option("any")
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        assert page.locator("#filterPopover").is_visible()
        assert page.evaluate("() => document.activeElement?.id") == "tagMatchMode"
        assert any(query.get("tagMatchMode") == ["any"] for query in asset_queries)
        page.locator("#applyFiltersButton").click()
        page.locator("#filterPopover").wait_for(state="hidden")
        page.locator("#activeFilterRelation:not(.hidden)").wait_for()
        assert "旅行 已拒绝" in page.locator("#activeFilterSummary").inner_text()
        page.wait_for_function(
            "() => document.querySelector('[data-active-filter-match=\"any\"]').getAttribute('aria-pressed') === 'true'"
        )
        any_relation = page.locator('[data-active-filter-match="any"]')
        all_relation = page.locator('[data-active-filter-match="all"]')
        assert any_relation.get_attribute("tabindex") == "0"
        assert all_relation.get_attribute("tabindex") == "-1"
        any_relation.focus()
        page.keyboard.press("End")
        page.wait_for_function(
            "() => state.filters.tagMatchMode === 'all' && !state.loadingAssets"
        )
        assert page.evaluate(
            "() => document.activeElement?.dataset.activeFilterMatch"
        ) == "all"
        assert all_relation.get_attribute("aria-pressed") == "true"
        page.keyboard.press("Home")
        page.wait_for_function(
            "() => state.filters.tagMatchMode === 'any' && !state.loadingAssets"
        )
        assert page.evaluate(
            "() => document.activeElement?.dataset.activeFilterMatch"
        ) == "any"
        assert any_relation.get_attribute("aria-pressed") == "true"
        page.locator("#clearActiveFiltersButton").click()
        page.locator("#activeFilterBar").wait_for(state="hidden")

        page.locator("#filterButton").click()
        page.locator("#tagPresenceFilter").focus()
        page.locator("#tagPresenceFilter").select_option("untagged")
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        assert page.locator("#filterPopover").is_visible()
        assert page.evaluate("() => document.activeElement?.id") == "tagPresenceFilter"
        assert asset_queries[-1].get("tagPresence") == ["untagged"]
        page.locator("#resetFiltersButton").click()
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        assert page.evaluate("() => document.activeElement?.id") == "resetFiltersButton"
        quick_query_start = len(asset_queries)
        page.evaluate(
            """() => {
              for (const value of ['available', 'missing', 'unreadable']) {
                document.querySelector(`#availabilityFilter input[value="${value}"]`).click();
              }
            }"""
        )
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        quick_queries = asset_queries[quick_query_start:]
        assert len([query for query in quick_queries if "cursor" not in query]) == 1
        assert quick_queries[-1].get("availabilities") == ["available,missing,unreadable"]
        page.locator("#clearAvailabilityFilter").click()
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        assert page.evaluate("() => document.activeElement?.id") == "clearAvailabilityFilter"
        page.locator("#applyFiltersButton").click()
        page.locator("#filterPopover").wait_for(state="hidden")

        # Mac-style zero-result recovery keeps source/media scope and exposes the exact
        # condition groups that can be removed instead of leaving a dead-end message.
        page.locator("#searchInput").fill("不存在")
        page.locator("#emptyState:not(.hidden)").wait_for()
        assert page.locator("#emptyStateTitle").inner_text() == "没有找到照片"
        assert "文件名、相对路径、标签和来源" in page.locator(
            "#emptyStateCopy"
        ).inner_text()
        assert page.locator("#emptyStateSymbol").inner_text() == "≡"
        assert page.locator("#emptyClearSearchButton").is_visible()
        assert "button-primary" in page.locator("#emptyClearSearchButton").get_attribute("class")
        assert page.locator("#emptyClearAllConditionsButton").is_hidden()
        page.locator("#emptyClearSearchButton").click()
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').wait_for()
        assert page.evaluate("() => document.activeElement?.id") == "searchInput"
        assert "q" not in asset_queries[-1]

        # The main search field keeps native Mac search behavior: Escape clears
        # a non-empty query before it can act on the surrounding workspace.
        page.locator("#selectionModeButton").click()
        page.wait_for_function("() => state.selectionMode === true")
        page.locator("#searchInput").fill("不存在")
        page.locator("#emptyState:not(.hidden)").wait_for()
        search_escape_queries = len(asset_queries)
        page.locator("#searchInput").press("Escape")
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').wait_for()
        assert page.locator("#searchInput").input_value() == ""
        assert page.evaluate("() => state.searchText") == ""
        assert page.evaluate("() => state.selectionMode") is True
        assert page.evaluate("() => document.activeElement?.id") == "searchInput"
        escaped_search_queries = asset_queries[search_escape_queries:]
        assert escaped_search_queries
        assert all("q" not in query for query in escaped_search_queries)
        assert len({query.get("cursor", [""])[0] for query in escaped_search_queries}) \
            == len(escaped_search_queries)
        page.locator("#selectionModeButton").click()
        page.wait_for_function("() => state.selectionMode === false")

        page.locator("#searchInput").fill("不存在")
        page.locator("#emptyState:not(.hidden)").wait_for()
        page.locator("#filterButton").click()
        page.locator('#availabilityFilter input[value="unsupported"]').check()
        page.locator("#filterTagSelect").select_option(TRAVEL_TAG_ID)
        page.locator("#filterTagDecision").select_option("rejected")
        page.locator("#addTagFilterButton").click()
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        page.locator("#applyFiltersButton").click()
        page.locator("#filterPopover").wait_for(state="hidden")
        page.locator("#emptyState:not(.hidden)").wait_for()
        assert "搜索“不存在”与当前筛选" in page.locator(
            "#emptyStateCopy"
        ).inner_text()
        for selector in [
            "#emptyClearAllConditionsButton",
            "#emptyClearSearchButton",
            "#emptyClearTagFiltersButton",
            "#emptyClearPropertyFiltersButton",
        ]:
            assert page.locator(selector).is_visible()
        assert asset_queries[-1].get("q") == ["不存在"]
        assert asset_queries[-1].get("availabilities") == ["unsupported"]
        assert asset_queries[-1].get("rejectedTagIDs") == [TRAVEL_TAG_ID]
        page.screenshot(path="/tmp/imageall-empty-recovery-synthetic.png", full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(250)
        assert page.evaluate(
            "() => document.querySelector('#sourceSidebar').getBoundingClientRect().right <= 1"
        )
        assert page.evaluate(
            "() => document.querySelector('#inspector').getBoundingClientRect().left >= 389"
        )
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        for button in page.locator(
            "#emptyStateActions button:not(.hidden)"
        ).all():
            bounds = button.bounding_box()
            assert bounds is not None
            assert bounds["x"] >= 0
            assert bounds["x"] + bounds["width"] <= 390
        page.screenshot(path="/tmp/imageall-empty-recovery-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})

        page.locator("#emptyClearPropertyFiltersButton").click()
        page.wait_for_function("() => document.activeElement?.id === 'filterButton'")
        assert "availabilities" not in asset_queries[-1]
        assert asset_queries[-1].get("rejectedTagIDs") == [TRAVEL_TAG_ID]
        assert page.locator("#emptyClearPropertyFiltersButton").is_hidden()

        page.locator("#emptyClearTagFiltersButton").click()
        page.wait_for_function("() => document.activeElement?.id === 'filterButton'")
        assert "rejectedTagIDs" not in asset_queries[-1]
        assert page.locator("#emptyClearAllConditionsButton").is_hidden()
        page.locator("#emptyClearSearchButton").click()
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').wait_for()

        page.locator("#searchInput").fill("不存在")
        page.locator("#emptyState:not(.hidden)").wait_for()
        page.locator("#filterButton").click()
        page.locator('#availabilityFilter input[value="missing"]').check()
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        page.locator("#applyFiltersButton").click()
        page.locator("#filterPopover").wait_for(state="hidden")
        assert page.locator("#emptyClearAllConditionsButton").is_visible()
        page.locator("#emptyClearAllConditionsButton").click()
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').wait_for()
        page.wait_for_function("() => document.activeElement?.id === 'filterButton'")
        assert "q" not in asset_queries[-1]
        assert "availabilities" not in asset_queries[-1]

        filter_escape_queries = len(asset_queries)
        page.locator("#selectionModeButton").click()
        page.wait_for_function("() => state.selectionMode === true")
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"] > .asset-card-main').click()
        page.wait_for_function(
            "assetID => state.selectedAssetIDs.has(assetID)",
            arg=IMAGE_IDS[0],
        )
        page.locator("#filterButton").click()
        page.locator("#filterPopover:not(.hidden)").wait_for()
        page.keyboard.press("Escape")
        page.locator("#filterPopover").wait_for(state="hidden")
        page.wait_for_function("() => document.activeElement?.id === 'filterButton'")
        assert page.evaluate("() => state.selectionMode") is True
        assert page.evaluate(
            "assetID => state.selectedAssetIDs.has(assetID)",
            IMAGE_IDS[0],
        ) is True
        assert len(asset_queries) == filter_escape_queries
        page.locator("#selectionModeButton").click()
        page.wait_for_function("() => state.selectionMode === false")

        first_asset_main = page.locator(
            f'[data-asset-id="{IMAGE_IDS[0]}"] > .asset-card-main'
        )
        first_asset_main.hover()
        persistent_help = page.locator("#persistentHelp:not(.hidden)")
        persistent_help.wait_for(timeout=2_000)
        assert persistent_help.get_attribute("data-kind") == "asset"
        assert page.locator("#persistentHelpTitle").inner_text() == "CAT_0001.JPG"
        persistent_detail = page.locator("#persistentHelpDetail").inner_text()
        for expected in [
            "来源：Apple Photos",
            "位置：Trips/CAT_0001.JPG",
            "尺寸：1200 × 900",
            "格式：public.jpeg",
            "拍摄时间：",
            "修改时间：",
            "标签：已确认 1 · 已拒绝 0",
            "状态：可用",
        ]:
            assert expected in persistent_detail, (expected, persistent_detail)
        desktop_help_bounds = persistent_help.bounding_box()
        assert desktop_help_bounds is not None
        assert desktop_help_bounds["x"] >= 8
        assert desktop_help_bounds["x"] + desktop_help_bounds["width"] <= 1432
        assert desktop_help_bounds["y"] >= 8
        assert desktop_help_bounds["y"] + desktop_help_bounds["height"] <= 952
        page.screenshot(path="/tmp/imageall-asset-persistent-help.png", full_page=True)
        page.locator("#searchInput").focus()
        page.keyboard.press("Tab")
        first_asset_main.focus()
        persistent_help.wait_for(timeout=1_000)
        assert "persistentHelp" in (first_asset_main.get_attribute("aria-describedby") or "")
        page.set_viewport_size({"width": 390, "height": 844})
        page.locator("#sidebarToggle").focus()
        page.wait_for_function(
            "() => document.activeElement?.id === 'sidebarToggle'"
        )
        page.wait_for_timeout(120)
        first_asset_main.focus()
        persistent_help.wait_for(timeout=2_000)
        narrow_help_bounds = persistent_help.bounding_box()
        assert narrow_help_bounds is not None
        assert narrow_help_bounds["x"] >= 8
        assert narrow_help_bounds["x"] + narrow_help_bounds["width"] <= 382
        assert narrow_help_bounds["y"] >= 8
        assert narrow_help_bounds["y"] + narrow_help_bounds["height"] <= 836
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        page.screenshot(path="/tmp/imageall-asset-persistent-help-390.png", full_page=True)
        page.keyboard.press("Escape")
        page.locator("#persistentHelp.hidden").wait_for(state="attached")
        page.set_viewport_size({"width": 1440, "height": 960})
        first_asset_main.focus()
        context_scroll_top = page.locator("#libraryScroll").evaluate(
            "element => element.scrollTop"
        )
        asset_context_query_count = len(asset_queries)
        page.keyboard.press("Shift+F10")
        asset_context_menu = page.locator("#assetContextMenu:not(.hidden)")
        asset_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.contextAction === 'preview'"
        )
        assert asset_context_menu.get_attribute("aria-label") == "CAT_0001.JPG 项目操作"
        asset_context_history = page.evaluate(
            """() => {
              const entry = history.state?.imageAllWorkspace;
              return {
                route: entry?.route,
                navigationLevel: entry?.navigationLevel,
                kind: entry?.context?.contextMenuKind,
                baseLevel: entry?.context?.contextMenuBaseLevel,
                contextKeys: Object.keys(entry?.context || {}),
              };
            }"""
        )
        assert asset_context_history["route"] == "gallery"
        assert asset_context_history["navigationLevel"] == "contextMenu"
        assert asset_context_history["kind"] == "asset"
        assert asset_context_history["baseLevel"] in {"workspace", "inspector"}
        assert all(
            key in {"contextMenuKind", "contextMenuBaseLevel"}
            for key in asset_context_history["contextKeys"]
            if key.startswith("contextMenu")
        )
        page.evaluate("() => history.back()")
        asset_context_menu.wait_for(state="hidden")
        page.wait_for_function(
            "(assetID) => document.activeElement?.closest('[data-asset-id]')?.dataset.assetId === assetID",
            arg=IMAGE_IDS[0],
        )
        assert len(asset_queries) == asset_context_query_count
        page.evaluate("() => history.forward()")
        asset_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.contextAction === 'preview'"
        )
        assert len(asset_queries) == asset_context_query_count
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.contextAction"
        ) == "delete"
        page.keyboard.press("ArrowDown")
        assert page.evaluate(
            "() => document.activeElement?.dataset.contextAction"
        ) == "preview"
        page.keyboard.press("Escape")
        page.wait_for_function(
            "(assetID) => document.activeElement?.closest('[data-asset-id]')?.dataset.assetId === assetID",
            arg=IMAGE_IDS[0],
        )
        assert asset_context_menu.is_hidden()
        assert page.locator("#libraryScroll").evaluate(
            "element => element.scrollTop"
        ) == context_scroll_top
        assert page.locator(".asset-card.batch-selected").count() == 0

        first_asset_main.focus()
        page.keyboard.press("Shift+F10")
        asset_context_menu.wait_for()
        page.locator("#searchInput").click()
        asset_context_menu.wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.navigationLevel !== 'contextMenu'"
        )
        assert page.evaluate("() => document.activeElement?.id") != "searchInput"
        assert len(asset_queries) == asset_context_query_count
        first_asset_main.focus()

        page.keyboard.press("ContextMenu")
        asset_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.contextAction === 'preview'"
        )
        page.keyboard.press("End")
        page.keyboard.press("ArrowUp")
        page.keyboard.press("ArrowUp")
        assert page.evaluate(
            "() => document.activeElement?.dataset.contextAction"
        ) == "toggleSelection"
        page.keyboard.press("Enter")
        page.wait_for_function(
            "(assetID) => document.activeElement?.closest('[data-asset-id]')?.dataset.assetId === assetID",
            arg=IMAGE_IDS[0],
        )
        assert asset_context_menu.is_hidden()
        assert page.locator(".asset-card.batch-selected").count() == 1
        assert page.locator("#libraryScroll").evaluate(
            "element => element.scrollTop"
        ) == context_scroll_top
        asset_preview_snapshot = page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectedAssetID: state.selectedAssetID,
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        )
        second_asset_main = page.locator(
            f'[data-asset-id="{IMAGE_IDS[1]}"] > .asset-card-main'
        )
        second_asset_main.press("Shift+F10")
        asset_context_menu.wait_for()
        page.locator('[data-context-action="preview"]').click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "TRIP_0002.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectedAssetID: state.selectedAssetID,
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == asset_preview_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "assetID => document.activeElement?.closest('[data-asset-id]')?.dataset.assetId === assetID",
            arg=IMAGE_IDS[1],
        )
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              selectedAssetID: state.selectedAssetID,
              selectionAnchorID: state.selectionAnchorID,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == asset_preview_snapshot
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.querySelector('.asset-card.batch-selected') === null"
        )

        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').click()
        page.locator("#inspectorContent:not(.hidden)").wait_for()
        page.locator("#inspectorLocalModelSection:not(.hidden)").wait_for()
        page.locator("#inspectorPersonalModelButton").click()
        page.wait_for_function(
            "() => state.assetLocalSuggestions.phase === 'results' "
            "&& !state.assetLocalSuggestions.submitting"
        )
        assert local_suggestion_requests[-1]["assetID"] == IMAGE_IDS[0]
        assert local_suggestion_requests[-1]["track"] == "personal"
        assert page.locator("#inspectorLocalModelBody .inspector-local-model-result").count() == 2
        page.evaluate(
            """() => {
              const container = document.querySelector("#inspectorLocalModelBody");
              window.__stableLocalSuggestionFrame = {
                rows: [...container.querySelectorAll(".inspector-local-model-result")],
                actions: [...container.querySelectorAll("[data-local-suggestion-id][data-action]")],
                scrollTop: container.scrollTop,
              };
            }"""
        )
        page.locator(
            f'#inspectorLocalModelBody [data-local-suggestion-id="{LOCAL_SUGGESTION_IDS[0]}"]'
            '[data-action="accept"]'
        ).click()
        page.wait_for_function(
            "(id) => document.activeElement?.dataset.localSuggestionId === id "
            "&& state.assetLocalSuggestions.suggestions.length === 1",
            arg=LOCAL_SUGGESTION_IDS[1],
        )
        stable_local_suggestion = page.evaluate(
            """() => {
              const frame = window.__stableLocalSuggestionFrame;
              const container = document.querySelector("#inspectorLocalModelBody");
              const row = container.querySelector(".inspector-local-model-result");
              const actions = [...container.querySelectorAll(
                "[data-local-suggestion-id][data-action]"
              )];
              return {
                row: row === frame.rows[1],
                reject: actions[0] === frame.actions[2],
                accept: actions[1] === frame.actions[3],
                focus: document.activeElement === frame.actions[3],
                scroll: container.scrollTop === frame.scrollTop,
              };
            }"""
        )
        assert all(stable_local_suggestion.values()), stable_local_suggestion

        page.evaluate(
            """() => {
              const container = document.querySelector("#inspectorLocalModelBody");
              window.__stableFailedLocalSuggestionFrame = {
                row: container.querySelector(".inspector-local-model-result"),
                actions: [...container.querySelectorAll(
                  "[data-local-suggestion-id][data-action]"
                )],
                scrollTop: container.scrollTop,
              };
            }"""
        )
        fail_next_tag_decision[0] = True
        page.locator(
            f'#inspectorLocalModelBody [data-local-suggestion-id="{LOCAL_SUGGESTION_IDS[1]}"]'
            '[data-action="reject"]'
        ).click()
        page.wait_for_function(
            "() => !state.tagMutating "
            "&& document.querySelector('#toastMessage').textContent.includes("
            "'synthetic tag decision denied')"
        )
        page.wait_for_function(
            "(id) => document.activeElement?.dataset.localSuggestionId === id",
            arg=LOCAL_SUGGESTION_IDS[1],
        )
        stable_failed_local_suggestion = page.evaluate(
            """() => {
              const frame = window.__stableFailedLocalSuggestionFrame;
              const container = document.querySelector("#inspectorLocalModelBody");
              const actions = [...container.querySelectorAll(
                "[data-local-suggestion-id][data-action]"
              )];
              return {
                row: container.querySelector(".inspector-local-model-result") === frame.row,
                reject: actions[0] === frame.actions[0],
                accept: actions[1] === frame.actions[1],
                focus: document.activeElement === frame.actions[0],
                retained: state.assetLocalSuggestions.suggestions.length === 1,
                scroll: container.scrollTop === frame.scrollTop,
              };
            }"""
        )
        assert all(stable_failed_local_suggestion.values()), (
            stable_failed_local_suggestion
        )

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
        page.evaluate(
            """() => {
              const container = document.querySelector("#inspectorSuggestions");
              const metadata = document.querySelector("#assetMetadata");
              const source = metadata.querySelector('dd[data-metadata-key="来源"]');
              const range = document.createRange();
              range.selectNodeContents(source);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const metadataFrame = {
                children: [...metadata.children],
                source,
                selection: selection.toString(),
                mutations: 0,
              };
              metadataFrame.observer = new MutationObserver((records) => {
                metadataFrame.mutations += records.filter(
                  (record) => record.type === "childList"
                ).length;
              });
              metadataFrame.observer.observe(metadata, { childList: true, subtree: true });
              renderInspector(state.selectedDetail);
              window.__stableInspectorSuggestionFrame = {
                container,
                rows: [...container.querySelectorAll(".inspector-suggestion-row")],
                actions: [...container.querySelectorAll("[data-inspector-suggestion-key][data-action]")],
                scrollTop: container.scrollTop,
                metadataFrame,
                metadataSelectionPreserved: selection.toString() === metadataFrame.selection
                  && selection.toString() === "Apple Photos",
              };
            }"""
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
        stable_inspector_suggestions = page.evaluate(
            """() => {
              const frame = window.__stableInspectorSuggestionFrame;
              const container = document.querySelector("#inspectorSuggestions");
              return {
                container: container === frame.container,
                rows: [...container.querySelectorAll(".inspector-suggestion-row")]
                  .every((row, index) => row === frame.rows[index]),
                actions: [...container.querySelectorAll(
                  "[data-inspector-suggestion-key][data-action]"
                )].every((action, index) => action === frame.actions[index]),
                focus: document.activeElement === frame.actions[0],
                scroll: container.scrollTop === frame.scrollTop,
              };
            }"""
        )
        assert all(stable_inspector_suggestions.values()), stable_inspector_suggestions
        stable_inspector_metadata = page.evaluate(
            """() => {
              const frame = window.__stableInspectorSuggestionFrame.metadataFrame;
              const metadata = document.querySelector("#assetMetadata");
              frame.observer.disconnect();
              const children = [...metadata.children];
              return {
                children: children.length === frame.children.length
                  && children.every((child, index) => child === frame.children[index]),
                source: metadata.querySelector('dd[data-metadata-key="来源"]')
                  === frame.source,
                selection: window.__stableInspectorSuggestionFrame.metadataSelectionPreserved,
                mutations: frame.mutations,
              };
            }"""
        )
        assert stable_inspector_metadata == {
            "children": True,
            "source": True,
            "selection": True,
            "mutations": 0,
        }, stable_inspector_metadata

        page.evaluate(
            """() => {
              const container = document.querySelector("#inspectorSuggestions");
              window.__stableFailedInspectorSuggestionFrame = {
                rows: [...container.querySelectorAll(".inspector-suggestion-row")],
                actions: [...container.querySelectorAll("[data-inspector-suggestion-key][data-action]")],
                scrollTop: container.scrollTop,
              };
            }"""
        )
        fail_next_tag_decision[0] = True
        failed_suggestion_reject = page.locator(
            f'#inspectorSuggestions [data-tag-id="{SUGGESTION_TAG_IDS[1]}"][data-action="reject"]'
        )
        failed_suggestion_reject.click()
        page.wait_for_function(
            "() => !state.tagMutating "
            "&& document.querySelector('#toastMessage').textContent.includes("
            "'synthetic tag decision denied')"
        )
        page.wait_for_function(
            "(key) => document.activeElement?.dataset.inspectorSuggestionKey === key",
            arg=f"{SUGGESTION_TAG_IDS[1]}|standardModel",
        )
        stable_failed_inspector_suggestions = page.evaluate(
            """() => {
              const frame = window.__stableFailedInspectorSuggestionFrame;
              const container = document.querySelector("#inspectorSuggestions");
              const rows = [...container.querySelectorAll(".inspector-suggestion-row")];
              const actions = [...container.querySelectorAll(
                "[data-inspector-suggestion-key][data-action]"
              )];
              return {
                rows: rows.every((row, index) => row === frame.rows[index]),
                actions: actions.every((action, index) => action === frame.actions[index]),
                focus: document.activeElement === frame.actions[3],
                scroll: container.scrollTop === frame.scrollTop,
              };
            }"""
        )
        assert all(stable_failed_inspector_suggestions.values()), (
            stable_failed_inspector_suggestions
        )
        assert tag_decisions[-1]["tagID"] == SUGGESTION_TAG_IDS[1]
        assert tag_decisions[-1]["action"] == "reject"

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
        page.evaluate(
            f"""() => {{
              const container = document.querySelector("#inspectorTags");
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
              const actions = (row) => Object.fromEntries(
                [...row.querySelectorAll('[data-action][data-tag-id]')]
                  .map((button) => [button.dataset.action, button])
              );
              window.__stableSingleInspectorTagFrame = {{
                container,
                subject,
                scene,
                subjectToggle: subject.querySelector(".inspector-tag-group-toggle"),
                sceneToggle: scene.querySelector(".inspector-tag-group-toggle"),
                subjectRows: subject.querySelector(".inspector-tag-group-rows"),
                sceneRows: scene.querySelector(".inspector-tag-group-rows"),
                cat,
                travel,
                catRow: cat.closest(".tag-row"),
                travelRow: travel.closest(".tag-row"),
                catActions: actions(cat.closest(".tag-row")),
                travelActions: actions(travel.closest(".tag-row")),
              }};
            }}"""
        )
        travel_chip.click()
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        stable_single_inspector = page.evaluate(
            f"""() => {{
              const frame = window.__stableSingleInspectorTagFrame;
              const container = document.querySelector("#inspectorTags");
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
              const sameActions = (row, expected) =>
                [...row.querySelectorAll('[data-action][data-tag-id]')]
                  .every((button) => expected[button.dataset.action] === button);
              return {{
                container: container === frame.container,
                subject: subject === frame.subject,
                scene: scene === frame.scene,
                subjectToggle: subject.querySelector(".inspector-tag-group-toggle")
                  === frame.subjectToggle,
                sceneToggle: scene.querySelector(".inspector-tag-group-toggle")
                  === frame.sceneToggle,
                subjectRows: subject.querySelector(".inspector-tag-group-rows")
                  === frame.subjectRows,
                sceneRows: scene.querySelector(".inspector-tag-group-rows")
                  === frame.sceneRows,
                cat: cat === frame.cat,
                travel: travel === frame.travel,
                catRow: cat.closest(".tag-row") === frame.catRow,
                travelRow: travel.closest(".tag-row") === frame.travelRow,
                catActions: sameActions(cat.closest(".tag-row"), frame.catActions),
                travelActions: sameActions(travel.closest(".tag-row"), frame.travelActions),
                focus: document.activeElement === travel,
              }};
            }}"""
        )
        assert all(stable_single_inspector.values()), stable_single_inspector
        assert tag_decisions[-1]["action"] == "accept"
        assert tag_decisions[-1]["assetIDs"] == [IMAGE_IDS[0]]
        cat_chip = page.locator(f'#inspectorTags [data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]')
        page.evaluate(
            f"""() => {{
              const container = document.querySelector("#inspectorTags");
              const cat = container.querySelector(
                '[data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]'
              );
              const travel = container.querySelector(
                '[data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
              );
              window.__stableFailedSingleInspectorTagFrame = {{
                subject: container.querySelector(
                  '[data-inspector-tag-group-id="{SUBJECT_GROUP_ID}"]'
                ),
                scene: container.querySelector(
                  '[data-inspector-tag-group-id="{SCENE_GROUP_ID}"]'
                ),
                cat,
                travel,
                catRow: cat.closest(".tag-row"),
                travelRow: travel.closest(".tag-row"),
              }};
            }}"""
        )
        fail_next_tag_decision[0] = True
        cat_chip.click(
            button="right"
        )
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=CAT_TAG_ID,
        )
        page.wait_for_function(
            "() => !state.tagMutating "
            "&& document.querySelector('#toastMessage').textContent.includes("
            "'synthetic tag decision denied')"
        )
        failed_single_inspector = page.evaluate(
            f"""() => {{
              const frame = window.__stableFailedSingleInspectorTagFrame;
              const container = document.querySelector("#inspectorTags");
              const cat = container.querySelector(
                '[data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]'
              );
              const travel = container.querySelector(
                '[data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
              );
              return {{
                subject: container.querySelector(
                  '[data-inspector-tag-group-id="{SUBJECT_GROUP_ID}"]'
                ) === frame.subject,
                scene: container.querySelector(
                  '[data-inspector-tag-group-id="{SCENE_GROUP_ID}"]'
                ) === frame.scene,
                cat: cat === frame.cat,
                travel: travel === frame.travel,
                catRow: cat.closest(".tag-row") === frame.catRow,
                travelRow: travel.closest(".tag-row") === frame.travelRow,
                focus: document.activeElement === cat,
              }};
            }}"""
        )
        assert all(failed_single_inspector.values()), failed_single_inspector
        assert tag_decisions[-1]["action"] == "clear"
        travel_chip.focus()
        page.keyboard.press("x")
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        assert tag_decisions[-1]["action"] == "reject", tag_decisions[-1]

        page.locator("#searchInput").focus()
        page.keyboard.press("Meta+K")
        assert page.locator("#commandContextLabel").inner_text() == "当前：照片图库"
        assert page.locator('[data-command-id="selectAll"]').count() == 1
        page.keyboard.press("Escape")
        page.wait_for_function("() => document.activeElement?.id === 'searchInput'")
        page.locator("#commandButton").click()
        page.locator("#commandSearchInput").fill("确认标签：猫")
        page.locator(f'[data-command-id="tagAction:accept:{CAT_TAG_ID}"]').click()
        page.wait_for_function("() => document.querySelector('#commandPalette').open === false")
        assert tag_decisions[-1]["action"] == "accept"
        assert tag_decisions[-1]["assetIDs"] == [IMAGE_IDS[0]]

        page.locator(f'#sourceList [data-source-id="{SOURCE_ID}"]').click()
        page.wait_for_function(
            f"() => state.selectedSourceID === '{SOURCE_ID}' && !state.loadingAssets"
        )
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').click()
        page.wait_for_function(
            f"() => state.selectedAssetID === '{IMAGE_IDS[0]}'"
        )
        source_command_snapshot = page.evaluate(
            """() => ({
              route: visibleWorkspaceRoute(),
              navigationLevel: history.state?.imageAllWorkspace?.navigationLevel,
              selectedSourceID: state.selectedSourceID,
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        )
        assert source_command_snapshot["selectedSourceID"] == SOURCE_ID
        source_command_asset_queries = len(asset_queries)
        source_command_action_count = len(source_actions)
        page.locator("#commandButton").click()
        current_source_command = page.locator(
            f'[data-command-id="sourceAction:syncPhotos:{SOURCE_ID}"]'
        )
        assert current_source_command.is_visible()
        with page.expect_response("**/v1/source-management/requests"):
            current_source_command.click()
        page.wait_for_function("() => document.querySelector('#commandPalette').open === false")
        assert source_actions[-1]["action"] == "syncPhotos"
        assert source_actions[-1]["sourceID"] == SOURCE_ID
        assert not page.locator("#sourceManagerDialog").is_visible()
        page.wait_for_function("() => document.activeElement?.id === 'commandButton'")
        assert page.evaluate(
            """() => ({
              route: visibleWorkspaceRoute(),
              navigationLevel: history.state?.imageAllWorkspace?.navigationLevel,
              selectedSourceID: state.selectedSourceID,
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == source_command_snapshot
        assert len(asset_queries) == source_command_asset_queries

        page.locator("#commandButton").click()
        refresh_all_command = page.locator('[data-command-id="refreshAllSources"]')
        assert refresh_all_command.is_visible()
        complete_next_refresh_all_without_job[0] = True
        with page.expect_response("**/v1/source-management/requests"):
            refresh_all_command.click()
        page.wait_for_function("() => document.querySelector('#commandPalette').open === false")
        assert source_actions[-1]["action"] == "refreshAll"
        assert source_actions[-1]["sourceID"] is None
        assert len(source_actions) == source_command_action_count + 2
        assert not page.locator("#sourceManagerDialog").is_visible()
        page.wait_for_function("() => document.activeElement?.id === 'commandButton'")
        assert page.evaluate(
            """() => ({
              route: visibleWorkspaceRoute(),
              navigationLevel: history.state?.imageAllWorkspace?.navigationLevel,
              selectedSourceID: state.selectedSourceID,
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
            })"""
        ) == source_command_snapshot
        assert len(asset_queries) == source_command_asset_queries
        page.wait_for_function("() => !state.jobsRefreshing")
        catalog_job_fetches[0] = 0

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

        page.locator(f'button.sidebar-row[data-source-id="{SOURCE_ID}"]').click(button="right")
        source_menu_actions = page.locator(
            "#sourceContextMenu [data-source-context-action]"
        ).all_inner_texts()
        assert "预热缩略图缓存" in source_menu_actions
        assert "专门用于原比例的缓存" in source_menu_actions
        page.locator(
            '#sourceContextMenu [data-source-context-action="prewarmThumbnails"]'
        ).click()
        assert not page.locator("#sourceManagerDialog").is_visible()
        page.wait_for_function(
            "() => !document.querySelector('#sourcePrewarmStatusButton').classList.contains('hidden')"
        )
        source_management_projection_asset_queries = len(asset_queries)
        page.locator("#sourcePrewarmStatusButton").click()
        page.locator("#sourceManagerDialog").wait_for(state="visible")
        assert page.evaluate(
            """() => ({
              gallerySourceIDs: state.sources.map(source => source.id),
              managerSourceIDs: state.sourceManagement.snapshot.sources.map(source => source.id),
            })"""
        ) == {
            "gallerySourceIDs": [
                SOURCE_ID,
                "55555555-aaaa-bbbb-cccc-555555555555",
                "66666666-aaaa-bbbb-cccc-666666666666",
            ],
            "managerSourceIDs": [
                SOURCE_ID,
                "55555555-aaaa-bbbb-cccc-555555555555",
                "66666666-aaaa-bbbb-cccc-666666666666",
            ],
        }
        assert len(asset_queries) == source_management_projection_asset_queries
        page.wait_for_function(
            "() => document.querySelector('#sourceManagerPending').textContent.includes('/ 3')"
        )
        assert source_actions[-1]["action"] == "prewarmThumbnails"
        assert page.locator("#sourceManagerPending progress").get_attribute("max") == "3"
        assert page.locator('[data-source-pending-action="cancelPrewarm"]').is_enabled()
        page.locator("#sourceManagerCloseButton").click()
        page.wait_for_function(
            "() => !document.querySelector('#sourcePrewarmStatusButton').classList.contains('hidden')"
            " && document.querySelector('#sourcePrewarmStatusLabel').textContent.includes('/3')"
        )
        page.screenshot(path="/tmp/imageall-source-prewarm-synthetic.png", full_page=True)
        assert page.locator("#sourcePrewarmCancelButton").is_visible()
        assert "Apple Photos" in page.locator(
            "#sourcePrewarmCancelButton"
        ).get_attribute("aria-label")
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(80)
        assert page.evaluate(
            "() => document.documentElement.scrollWidth <= window.innerWidth"
        )
        for selector in [
            "#commandButton",
            "#jobsButton",
            "#connectionStatus",
            "#compactToolbarMenuButton",
        ]:
            bounds = page.locator(selector).bounding_box()
            assert bounds is not None, selector
            assert bounds["x"] >= 0 and bounds["x"] + bounds["width"] <= 390, (
                selector,
                bounds,
            )
        assert not page.locator("#sourcePrewarmStatusButton").is_visible()
        assert not page.locator("#sourcePrewarmCancelButton").is_visible()
        assert not page.locator("#settingsButton").is_visible()
        assert not page.locator("#logoutButton").is_visible()
        assert page.locator("#compactToolbarActivityDot").is_visible()
        page.locator("#compactToolbarMenuButton").click()
        prewarm_menu_item = page.locator(
            '[data-compact-toolbar-target="sourcePrewarmStatusButton"]'
        )
        cancel_menu_item = page.locator(
            '[data-compact-toolbar-target="sourcePrewarmCancelButton"]'
        )
        assert prewarm_menu_item.is_visible()
        assert "/3" in prewarm_menu_item.inner_text()
        assert cancel_menu_item.is_visible()
        assert cancel_menu_item.is_enabled()
        assert page.locator("#currentSourceRefreshButton").is_hidden()
        page.screenshot(path="/tmp/imageall-source-prewarm-390.png", full_page=True)
        cancel_menu_item.click()
        page.wait_for_function(
            "() => document.querySelector('#sourcePrewarmStatusButton').classList.contains('hidden')"
        )
        assert not page.locator("#compactToolbarActivityDot").is_visible()
        assert not page.locator("#sourceManagerDialog").is_visible()
        assert page.evaluate("() => document.activeElement?.id") == "jobsButton"
        assert source_actions[-1]["action"] == "cancelPrewarm"
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#sourceManagerButton").click()
        page.locator("#sourceManagerDialog").wait_for(state="visible")
        page.locator("#sourceAllActionsSummary").click()
        refresh_all_button = page.locator("#sourceRefreshAllButton")
        assert refresh_all_button.is_visible()
        page.wait_for_function(
            "() => !document.querySelector('#sourceRefreshAllButton').disabled"
        )
        page.locator("#sourceBatchAuthorizationPanel > summary").click()
        assert page.locator("#sourceReauthorizeAllButton").is_visible()
        assert page.locator("#sourceReauthorizeAllButton").is_enabled()
        assert page.locator("#sourceRefreshAllMutationAuthorizationButton").is_visible()
        assert page.locator("#sourceRefreshAllMutationAuthorizationButton").is_enabled()
        assert page.locator("#sourceRequestPhotosWriteAuthorizationButton").is_visible()
        assert "（1）" in page.locator("#sourceReauthorizeAllButton").inner_text()
        assert "（1）" in page.locator(
            "#sourceRefreshAllMutationAuthorizationButton"
        ).inner_text()
        page.set_viewport_size({"width": 390, "height": 844})
        source_manager_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth, "
            "buttonRight: Math.max(...[...document.querySelectorAll("
            "'#sourceRefreshAllButton, #sourcePrewarmAllButton, #sourcePrewarmAllOriginalButton, "
            "#sourceReauthorizeAllButton, #sourceRefreshAllMutationAuthorizationButton, "
            "#sourceRequestPhotosWriteAuthorizationButton')]"
            ".map(button => button.getBoundingClientRect().right)) })"
        )
        assert source_manager_dimensions["scroll"] <= source_manager_dimensions["viewport"], (
            source_manager_dimensions
        )
        assert source_manager_dimensions["buttonRight"] <= source_manager_dimensions["viewport"], (
            source_manager_dimensions
        )
        page.screenshot(path="/tmp/imageall-source-refresh-all-390.png", full_page=True)
        page.locator("#libraryScroll").evaluate("element => { element.scrollTop = 180; }")
        assert page.locator("#libraryScroll").evaluate("element => element.scrollTop") > 0
        catalog_context_script = """() => ({
          assetIDs: state.assets.map(asset => asset.id),
          nextCursor: state.nextCursor,
          selectedSourceID: state.selectedSourceID,
          selectedAssetID: state.selectedAssetID,
          selectedDetailID: state.selectedDetail?.assetID || null,
          selectionMode: state.selectionMode,
          selectedAssetIDs: [...state.selectedAssetIDs].sort(),
          scrollTop: document.querySelector('#libraryScroll').scrollTop,
        })"""
        catalog_context_before = page.evaluate(catalog_context_script)
        asset_query_count_before = len(asset_queries)
        refresh_all_button.click()
        page.wait_for_function(
            "() => !document.querySelector('#sourceRefreshAllButton').disabled"
        )
        assert source_actions[-1]["action"] == "refreshAll"
        assert source_actions[-1].get("sourceID") is None
        page.wait_for_function(
            "() => !document.querySelector('#catalogProgressStatusButton').classList.contains('hidden')"
        )
        initial_catalog_label = page.locator("#catalogProgressStatusLabel").inner_text()
        page.wait_for_function(
            "previous => document.querySelector('#catalogProgressStatusLabel')?.textContent !== previous",
            arg=initial_catalog_label,
        )
        assert page.evaluate(catalog_context_script) == catalog_context_before
        assert len(asset_queries) == asset_query_count_before, asset_queries[asset_query_count_before:]
        catalog_jobs[0]["state"] = "completed"
        page.evaluate("() => refreshJobs({ announce: false, indicateBusy: false })")
        page.locator("#catalogProgressStatusButton").wait_for(state="hidden")
        page.locator("#sourceAllActionsSummary").click()
        prewarm_all_button = page.locator("#sourcePrewarmAllButton")
        prewarm_all_original_button = page.locator("#sourcePrewarmAllOriginalButton")
        assert prewarm_all_button.is_visible() and prewarm_all_button.is_enabled()
        assert prewarm_all_original_button.is_visible() and prewarm_all_original_button.is_enabled()
        prewarm_all_button.click()
        page.wait_for_function(
            "() => document.querySelector('#sourceManagerPending').textContent.includes('来源 1 / 2')"
            " && document.querySelector('#sourceManagerPending').textContent.includes('复用 1')"
            " && document.querySelector('#sourceManagerPending').textContent.includes('不可处理跳过 1')"
        )
        assert source_actions[-1]["action"] == "prewarmAllThumbnails"
        assert source_actions[-1].get("sourceID") is None
        page.locator('[data-source-pending-action="cancelPrewarm"]').click()
        page.wait_for_function(
            "() => document.querySelector('#sourcePrewarmStatusButton').classList.contains('hidden')"
        )
        assert source_actions[-1]["action"] == "cancelPrewarm"
        assert source_actions[-1].get("sourceID") is None
        page.locator("#sourceAllActionsSummary").click()
        prewarm_all_original_button.click()
        page.wait_for_function(
            "() => document.querySelector('#sourceManagerPending').textContent.includes('来源 1 / 2')"
        )
        assert source_actions[-1]["action"] == "prewarmAllOriginalAspect"
        assert source_actions[-1].get("sourceID") is None
        page.locator('[data-source-pending-action="cancelPrewarm"]').click()
        page.wait_for_function(
            "() => document.querySelector('#sourcePrewarmStatusButton').classList.contains('hidden')"
        )
        assert source_actions[-1]["action"] == "cancelPrewarm"
        assert source_actions[-1].get("sourceID") is None
        page.locator("#sourceAllActionsSummary").click()
        page.locator("#sourceBatchAuthorizationPanel > summary").click()
        page.locator("#sourceReauthorizeAllButton").click()
        page.wait_for_function(
            "() => document.querySelector('#sourceManagerPending').textContent.includes('Mac 上完成当前来源授权')"
        )
        assert source_actions[-1]["action"] == "reauthorizeAll"
        assert source_actions[-1].get("sourceID") is None
        source_requests.clear()
        page.evaluate("() => loadSourceManagement()")
        page.wait_for_function("() => !document.querySelector('#sourceReauthorizeAllButton').disabled")
        page.locator("#sourceAllActionsSummary").click()
        page.locator("#sourceBatchAuthorizationPanel > summary").click()
        page.locator("#sourceRefreshAllMutationAuthorizationButton").click()
        page.wait_for_function(
            "() => document.querySelector('#sourceManagerPending').textContent.includes('Mac 上完成当前来源授权')"
        )
        assert source_actions[-1]["action"] == "refreshAllFolderMutationAuthorizations"
        assert source_actions[-1].get("sourceID") is None
        source_requests.clear()
        page.evaluate("() => loadSourceManagement()")
        page.wait_for_function(
            "() => !document.querySelector('#sourceRefreshAllMutationAuthorizationButton').disabled"
        )
        page.set_viewport_size({"width": 2200, "height": 960})
        page.locator("#sourceManagerCloseButton").click()

        page.locator("#toolbarConnectFolderButton").click()
        page.wait_for_function("() => document.querySelector('#sourceManagerDialog').open === true")
        page.wait_for_function("() => document.querySelector('#sourceManagerPending').textContent.includes('等待 Mac')")
        assert source_actions[-1]["action"] == "connectFolder"
        assert source_actions[-1].get("sourceID") is None
        page.locator("#sourceManagerCloseButton").click()
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceManagerButton'"
        )
        page.set_viewport_size({"width": 1440, "height": 960})

        page.locator("#commandButton").click()
        page.locator("#commandSearchInput").fill("连接文件夹来源")
        page.locator('[data-command-id="connectFolder"]').click()
        page.wait_for_function("() => document.querySelector('#sourceManagerDialog').open === true")
        page.wait_for_function("() => document.querySelector('#sourceManagerPending').textContent.includes('等待 Mac')")
        assert source_actions[-1]["action"] == "connectFolder"
        assert source_actions[-1].get("sourceID") is None
        page.locator("#sourceManagerCloseButton").click()

        page.locator("#reviewNavigationButton").click()
        page.locator("#reviewOverview:not(.hidden)").wait_for()
        review_desktop_presentation = page.evaluate(
            """() => {
              const app = document.querySelector('#appView');
              const workspace = document.querySelector('#reviewWorkspace');
              const library = document.querySelector('#libraryPane');
              const sourceSidebar = document.querySelector('#sourceSidebar');
              const reviewBounds = workspace.getBoundingClientRect();
              const libraryBounds = library.getBoundingClientRect();
              const sourceBounds = sourceSidebar.getBoundingClientRect();
              return {
                appInert: app.inert,
                role: workspace.getAttribute('role'),
                ariaModal: workspace.getAttribute('aria-modal'),
                integrated: workspace.classList.contains('integrated'),
                reviewLeft: reviewBounds.left,
                reviewTop: reviewBounds.top,
                reviewBottom: reviewBounds.bottom,
                libraryLeft: libraryBounds.left,
                libraryTop: libraryBounds.top,
                libraryBottom: libraryBounds.bottom,
                sourceVisible: sourceBounds.width > 0 && sourceBounds.height > 0,
                reviewSelected: document.querySelector('#reviewNavigationButton')
                  .classList.contains('selected'),
                reviewCurrent: document.querySelector('#reviewNavigationButton')
                  .getAttribute('aria-current'),
                title: document.querySelector('#libraryTitle').textContent,
                galleryToolbarIsolated: document.querySelector('#libraryPane > .toolbar')
                  .dataset.integratedWorkspaceIsolated || null,
              };
            }"""
        )
        assert review_desktop_presentation == {
            "appInert": False,
            "role": "region",
            "ariaModal": None,
            "integrated": True,
            "reviewLeft": review_desktop_presentation["libraryLeft"],
            "reviewTop": review_desktop_presentation["libraryTop"],
            "reviewBottom": review_desktop_presentation["libraryBottom"],
            "libraryLeft": review_desktop_presentation["libraryLeft"],
            "libraryTop": review_desktop_presentation["libraryTop"],
            "libraryBottom": review_desktop_presentation["libraryBottom"],
            "sourceVisible": True,
            "reviewSelected": True,
            "reviewCurrent": "page",
            "title": "待审核建议",
            "galleryToolbarIsolated": "true",
        }, review_desktop_presentation
        review_cat_card = page.locator(f'[data-review-overview-tag-id="{CAT_TAG_ID}"]')
        review_cat_card.wait_for()
        page.wait_for_function(
            "() => !state.review.overviewLoading "
            "&& !state.librarySuggestions.loading "
            "&& !state.sampleSuggestions.loading "
            "&& !state.generalSettings.loading"
        )
        review_cat_card.hover()
        page.wait_for_function(
            "() => !document.querySelector('#persistentHelp').classList.contains('hidden') "
            "&& document.querySelector('#persistentHelp').dataset.kind === 'review'"
        )
        assert page.locator("#persistentHelpTitle").inner_text() == "审核“猫”"
        assert review_cat_card.get_attribute("data-help-owner") == (
            f"review-overview:{CAT_TAG_ID}"
        )
        review_help_detail = page.locator("#persistentHelpDetail").inner_text()
        assert "P 属于、X 不属于、U 稍后" in review_help_detail
        review_connection_stability = page.evaluate(
            """async tagID => {
              const originalRenderReviewOverview = renderReviewOverview;
              const card = document.querySelector(
                `[data-review-overview-tag-id="${CSS.escape(tagID)}"]`
              );
              const connectionLabelBefore = document.querySelector(
                '.connection-label'
              ).textContent;
              let renderCalls = 0;
              renderReviewOverview = (...args) => {
                renderCalls += 1;
                return originalRenderReviewOverview(...args);
              };
              try {
                await api('/v1/jobs');
                return {
                  renderCalls,
                  retainedCard: card?.isConnected === true,
                  sameCard: document.querySelector(
                    `[data-review-overview-tag-id="${CSS.escape(tagID)}"]`
                  ) === card,
                  sameHelpTarget: persistentHelpTarget === card,
                  helpTargetTagID: persistentHelpTarget?.dataset?.reviewOverviewTagId || null,
                  helpTargetOwner: persistentHelpTarget?.dataset?.helpOwner || null,
                  pointerHitOwner: persistentHelpControlAtPointer()?.dataset?.helpOwner || null,
                  pointerX: persistentHelpPointerX,
                  pointerY: persistentHelpPointerY,
                  helpVisible: !document.querySelector('#persistentHelp').classList.contains('hidden'),
                  helpInputMode: persistentHelpInputMode,
                  lastVisibleOwner: persistentHelpLastVisibleOwnerKey,
                  lastVisibleAge: performance.now() - persistentHelpLastVisibleAt,
                  timerPending: persistentHelpTimer != null,
                  connectionLabelBefore,
                  connectionLabelAfter: document.querySelector('.connection-label').textContent,
                };
              } finally {
                renderReviewOverview = originalRenderReviewOverview;
              }
            }""",
            CAT_TAG_ID,
        )
        assert review_connection_stability["renderCalls"] == 0, review_connection_stability
        assert review_connection_stability["retainedCard"] is True, review_connection_stability
        assert review_connection_stability["sameCard"] is True, review_connection_stability
        assert review_connection_stability["sameHelpTarget"] is True, review_connection_stability
        assert review_connection_stability["helpVisible"] is True, review_connection_stability
        assert review_connection_stability["connectionLabelAfter"] == (
            review_connection_stability["connectionLabelBefore"]
        ), review_connection_stability
        review_repaint_stability = page.evaluate(
            """async tagID => {
              const previousCard = document.querySelector(
                `[data-review-overview-tag-id="${CSS.escape(tagID)}"]`
              );
              const previousOwner = persistentHelpOwner;
              renderReviewOverview();
              await new Promise(resolve => requestAnimationFrame(
                () => requestAnimationFrame(resolve)
              ));
              await new Promise(resolve => setTimeout(resolve, 20));
              const card = document.querySelector(
                `[data-review-overview-tag-id="${CSS.escape(tagID)}"]`
              );
              return {
                replacedCard: card !== previousCard && previousCard?.isConnected === false,
                sameSemanticOwner: card?.dataset.helpOwner
                  === previousCard?.dataset.helpOwner,
                reboundHelpTarget: persistentHelpTarget === card,
                ownerAdvanced: persistentHelpOwner > previousOwner,
                helpVisible: !document.querySelector('#persistentHelp')
                  .classList.contains('hidden'),
                helpKind: document.querySelector('#persistentHelp').dataset.kind,
                helpTitle: document.querySelector('#persistentHelpTitle').textContent,
              };
            }""",
            CAT_TAG_ID,
        )
        assert review_repaint_stability == {
            "replacedCard": True,
            "sameSemanticOwner": True,
            "reboundHelpTarget": True,
            "ownerAdvanced": True,
            "helpVisible": True,
            "helpKind": "review",
            "helpTitle": "审核“猫”",
        }, review_repaint_stability
        stale_help_owner_fence = page.evaluate(
            """async tagID => {
              const card = document.querySelector(
                `[data-review-overview-tag-id="${CSS.escape(tagID)}"]`
              );
              const stale = document.createElement('button');
              configurePersistentHelp(stale, {
                title: '旧帮助',
                detail: '这个延迟回调不得覆盖当前审核帮助。',
                kind: 'control',
                owner: 'stale-help-fixture',
              });
              document.body.append(stale);
              schedulePersistentHelp(stale, 1_000, 'pointer');
              const staleOwner = persistentHelpOwner;
              schedulePersistentHelp(card, 0, 'pointer');
              const currentOwner = persistentHelpOwner;
              showPersistentHelp(stale, staleOwner);
              await new Promise(resolve => setTimeout(resolve, 20));
              const result = {
                ownerAdvanced: currentOwner > staleOwner,
                rejectedStaleTarget: persistentHelpTarget !== stale,
                retainedCurrentOwner: persistentHelpOwnerKey(persistentHelpTarget)
                  === card.dataset.helpOwner,
                helpVisible: !document.querySelector('#persistentHelp')
                  .classList.contains('hidden'),
                helpKind: document.querySelector('#persistentHelp').dataset.kind,
                helpTitle: document.querySelector('#persistentHelpTitle').textContent,
              };
              stale.remove();
              return result;
            }""",
            CAT_TAG_ID,
        )
        assert stale_help_owner_fence == {
            "ownerAdvanced": True,
            "rejectedStaleTarget": True,
            "retainedCurrentOwner": True,
            "helpVisible": True,
            "helpKind": "review",
            "helpTitle": "审核“猫”",
        }, stale_help_owner_fence
        review_help_bounds = page.locator("#persistentHelp").bounding_box()
        assert review_help_bounds is not None
        assert review_help_bounds["x"] >= 8 and review_help_bounds["y"] >= 8
        assert review_help_bounds["x"] + review_help_bounds["width"] <= 1432
        assert page.locator("#persistentHelp").is_visible()
        page.screenshot(path="/tmp/imageall-review-persistent-help.png", full_page=True)
        page.locator("#reviewSummary").click()
        page.wait_for_function(
            "() => document.querySelector('#persistentHelp').classList.contains('hidden')"
        )
        review_overview_before_resize = page.evaluate(
            """() => {
              const content = document.querySelector('.review-overview-content');
              const grid = document.querySelector('#reviewOverviewGrid');
              grid.style.paddingBottom = '720px';
              content.scrollTop = 180;
              return {
                overviewIDs: state.review.overview.map(item => item.id),
                overviewTotal: state.review.overviewTotal,
                contentScrollTop: content.scrollTop,
                focusedTagID: document.activeElement?.dataset?.reviewOverviewTagId || null,
              };
            }"""
        )
        assert review_overview_before_resize["contentScrollTop"] > 0
        review_handle = page.locator("#reviewOverviewResizeHandle")
        review_handle_box = review_handle.bounding_box()
        assert review_handle_box is not None
        review_drag_x = review_handle_box["x"] + review_handle_box["width"] / 2
        review_drag_y = review_handle_box["y"] + min(120, review_handle_box["height"] / 2)
        page.mouse.move(review_drag_x, review_drag_y)
        page.mouse.down()
        page.mouse.move(review_drag_x + 40, review_drag_y, steps=6)
        page.mouse.up()
        page.wait_for_function("() => state.layout.reviewModelWidth === 320")
        assert review_handle.get_attribute("aria-valuenow") == "320"
        assert page.evaluate(
            "() => document.querySelector('.review-overview-content').scrollTop"
        ) == review_overview_before_resize["contentScrollTop"]
        assert page.evaluate(
            "() => ({ overviewIDs: state.review.overview.map(item => item.id), "
            "overviewTotal: state.review.overviewTotal })"
        ) == {
            "overviewIDs": review_overview_before_resize["overviewIDs"],
            "overviewTotal": review_overview_before_resize["overviewTotal"],
        }
        review_handle.focus()
        page.keyboard.press("Home")
        assert review_handle.get_attribute("aria-valuenow") == "248"
        page.keyboard.press("Shift+ArrowRight")
        assert review_handle.get_attribute("aria-valuenow") == "268"
        saved_review_width = page.evaluate(
            "() => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
            ".reviewModelWidth"
        )
        assert saved_review_width == 268
        page.evaluate(
            "() => { state.layout.reviewModelWidth = 320; renderLayoutPreferences(); "
            "loadWorkspacePreferences(); renderLayoutPreferences(); }"
        )
        assert review_handle.get_attribute("aria-valuenow") == "268"
        review_handle.dblclick()
        assert review_handle.get_attribute("aria-valuenow") == "288"
        page.screenshot(path="/tmp/imageall-review-overview-split.png", full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_function(
            "() => !document.querySelector('#reviewWorkspace').classList.contains('integrated')"
        )
        assert page.evaluate(
            "() => ({ appInert: document.querySelector('#appView').inert, "
            "role: document.querySelector('#reviewWorkspace').getAttribute('role'), "
            "ariaModal: document.querySelector('#reviewWorkspace').getAttribute('aria-modal') })"
        ) == {"appInert": True, "role": "dialog", "ariaModal": "true"}
        assert review_handle.is_hidden()
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        review_group_toggle = page.locator("[data-review-overview-group-toggle]").first
        review_group_toggle.focus()
        page.keyboard.press("Tab")
        assert page.evaluate(
            "() => document.activeElement?.dataset?.reviewOverviewTagId"
        ) == CAT_TAG_ID
        page.wait_for_function(
            "() => !document.querySelector('#persistentHelp').classList.contains('hidden') "
            "&& document.querySelector('#persistentHelp').dataset.kind === 'review'"
        )
        narrow_review_help_bounds = page.locator("#persistentHelp").bounding_box()
        assert narrow_review_help_bounds is not None
        assert narrow_review_help_bounds["x"] >= 8
        assert narrow_review_help_bounds["x"] + narrow_review_help_bounds["width"] <= 382
        assert narrow_review_help_bounds["y"] >= 8
        page.wait_for_timeout(180)
        page.screenshot(path="/tmp/imageall-review-persistent-help-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_function(
            "() => document.querySelector('#reviewWorkspace').classList.contains('integrated')"
        )
        assert page.evaluate(
            "() => !document.querySelector('#appView').inert "
            "&& document.querySelector('#reviewWorkspace').getAttribute('role') === 'region' "
            "&& !document.querySelector('#reviewWorkspace').hasAttribute('aria-modal')"
        ) is True
        page.locator("#reviewOverviewGrid").evaluate(
            "element => { element.style.paddingBottom = ''; "
            "element.closest('.review-overview-content').scrollTop = 0; }"
        )
        page.locator(f'[data-review-overview-tag-id="{CAT_TAG_ID}"]').click()
        page.locator("#reviewQueueLayout:not(.hidden)").wait_for()
        page.locator("#reviewThumbnailLayoutControls:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelectorAll('#reviewGrid > .review-card').length === 3 "
            "&& state.review.nextCursor === null"
        )
        page.wait_for_function(
            f"() => state.review.detail?.assetID === '{REVIEW_IDS[0]}' "
            "&& !state.review.detailLoadingAssetID"
        )
        review_cards = page.locator("#reviewGrid > .review-card")
        first_review_main = review_cards.nth(0).locator(":scope > .review-card-main")
        second_review_main = review_cards.nth(1).locator(":scope > .review-card-main")
        first_review_favorite = review_cards.nth(0).locator(":scope > .review-card-favorite")
        second_review_favorite = review_cards.nth(1).locator(":scope > .review-card-favorite")
        assert first_review_main.get_attribute("tabindex") == "0"
        assert first_review_favorite.get_attribute("tabindex") == "0"
        assert second_review_main.get_attribute("tabindex") == "-1"
        assert second_review_favorite.get_attribute("tabindex") == "-1"
        first_review_main.focus()
        page.keyboard.press("Tab")
        assert page.evaluate(
            "() => document.activeElement?.classList.contains('review-card-favorite')"
        )
        page.keyboard.press("Tab")
        assert not page.evaluate(
            "() => document.querySelector('#reviewGrid').contains(document.activeElement)"
        )
        second_review_main.focus()
        assert first_review_main.get_attribute("tabindex") == "-1"
        assert first_review_favorite.get_attribute("tabindex") == "-1"
        assert second_review_main.get_attribute("tabindex") == "0"
        assert second_review_favorite.get_attribute("tabindex") == "0"
        first_review_main.focus()
        page.screenshot(path="/tmp/imageall-review-roving-focus.png", full_page=False)
        assert "Apple Photos" in page.locator("#reviewAssetMetadata").inner_text()
        assert "1200 × 900" in page.locator("#reviewAssetMetadata").inner_text()
        review_view_original = page.locator("#reviewViewOriginalButton")
        assert review_view_original.is_enabled()
        assert page.locator("#reviewViewOriginalButtonLabel").inner_text() == "在网页查看原图"
        review_view_original.click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        page.wait_for_function(
            f"() => document.querySelector('#lightboxImage').dataset.protectedPath "
            f"=== '/v1/assets/{REVIEW_IDS[0]}/original?r=1'"
        )
        assert viewed_originals[-1] == REVIEW_IDS[0]
        assert page.locator("#lightboxViewOriginalButton").get_attribute("aria-pressed") == "true"
        assert page.locator("#lightboxViewOriginalButtonLabel").inner_text() == "标准预览"
        assert opened_originals == []
        page.screenshot(path="/tmp/imageall-web-original-view.png", full_page=True)
        page.locator("#lightboxViewOriginalButton").click()
        page.wait_for_function(
            f"() => document.querySelector('#lightboxImage').dataset.protectedPath "
            f"=== '/v1/assets/{REVIEW_IDS[0]}/preview?r=1'"
        )
        assert page.locator("#lightboxViewOriginalButton").get_attribute("aria-pressed") == "false"
        assert page.locator("#lightboxViewOriginalButtonLabel").inner_text() == "查看原图"
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        assert page.locator("#reviewOpenOriginalButton").is_enabled()
        page.locator("#reviewOpenOriginalButton").click()
        page.wait_for_function(
            f"() => state.openingOriginal === false "
            f"&& document.querySelector('#reviewOpenOriginalButton').dataset.assetId === '{REVIEW_IDS[0]}'"
        )
        assert opened_originals[-1] == REVIEW_IDS[0]
        review_travel_accept = page.locator(
            f'#reviewTags [data-tag-id="{TRAVEL_TAG_ID}"][data-action="accept"]'
        )
        page.evaluate(
            f"""() => {{
              const container = document.querySelector("#reviewTags");
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
              const metadata = document.querySelector("#reviewAssetMetadata");
              const metadataSource = metadata.querySelector(
                'dd[data-metadata-key="来源"]'
              );
              const metadataRange = document.createRange();
              metadataRange.selectNodeContents(metadataSource);
              const metadataSelection = getSelection();
              metadataSelection.removeAllRanges();
              metadataSelection.addRange(metadataRange);
              const metadataFrame = {{
                children: [...metadata.children],
                source: metadataSource,
                selection: metadataSelection.toString(),
                selectionPreserved: false,
                mutations: 0,
              }};
              metadataFrame.observer = new MutationObserver((records) => {{
                metadataFrame.mutations += records.filter(
                  (record) => record.type === "childList"
                ).length;
              }});
              metadataFrame.observer.observe(metadata, {{ childList: true, subtree: true }});
              renderReviewInspectorMetadata(
                state.review.items[state.review.selectedIndex],
                state.review.detail
              );
              metadataFrame.selectionPreserved = metadataSelection.toString()
                === metadataFrame.selection && metadataSelection.toString() === "Apple Photos";
              window.__stableReviewInspectorTagFrame = {{
                container,
                subject,
                scene,
                cat,
                travel,
                catRow: cat.closest(".tag-row"),
                travelRow: travel.closest(".tag-row"),
                catActions: [...cat.closest(".tag-row").querySelectorAll(
                  '[data-action][data-tag-id]'
                )],
                travelActions: [...travel.closest(".tag-row").querySelectorAll(
                  '[data-action][data-tag-id]'
                )],
                accept: travel.closest(".tag-row").querySelector('[data-action="accept"]'),
                metadataFrame,
              }};
            }}"""
        )
        with page.expect_response("**/v1/tag-decisions/batch"):
            review_travel_accept.click()
        page.wait_for_function(
            f"() => !state.tagMutating && !state.review.mutating "
            f"&& state.review.detail?.assetID === '{REVIEW_IDS[0]}' "
            "&& !state.review.detailLoadingAssetID"
        )
        stable_review_inspector = page.evaluate(
            f"""() => {{
              const frame = window.__stableReviewInspectorTagFrame;
              const container = document.querySelector("#reviewTags");
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
              const accept = travel.closest(".tag-row").querySelector(
                '[data-action="accept"]'
              );
              const metadata = document.querySelector("#reviewAssetMetadata");
              frame.metadataFrame.observer.disconnect();
              const metadataChildren = [...metadata.children];
              return {{
                container: container === frame.container,
                subject: subject === frame.subject,
                scene: scene === frame.scene,
                cat: cat === frame.cat,
                travel: travel === frame.travel,
                catRow: cat.closest(".tag-row") === frame.catRow,
                travelRow: travel.closest(".tag-row") === frame.travelRow,
                catActions: frame.catActions.every((button) => button.isConnected),
                travelActions: frame.travelActions.every((button) => button.isConnected),
                accept: accept === frame.accept,
                focus: document.activeElement === accept,
                metadataChildren: metadataChildren.length === frame.metadataFrame.children.length
                  && metadataChildren.every(
                    (child, index) => child === frame.metadataFrame.children[index]
                  ),
                metadataSource: metadata.querySelector('dd[data-metadata-key="来源"]')
                  === frame.metadataFrame.source,
                metadataSelection: frame.metadataFrame.selectionPreserved,
                metadataMutations: frame.metadataFrame.mutations === 0,
              }};
            }}"""
        )
        assert all(stable_review_inspector.values()), stable_review_inspector
        assert tag_decisions[-1]["tagID"] == TRAVEL_TAG_ID
        assert tag_decisions[-1]["action"] == "accept"
        assert tag_decisions[-1]["assetIDs"] == [REVIEW_IDS[0]]
        page.keyboard.down("Meta")
        page.locator('[data-review-index="1"] > .review-card-main').click()
        page.keyboard.up("Meta")
        page.wait_for_function(
            "() => state.review.selectedAssetIDs.size === 2 "
            "&& state.review.detailSelectionKey?.split('|').length === 2"
        )
        review_travel_reject = page.locator(
            f'#reviewTags [data-tag-id="{TRAVEL_TAG_ID}"][data-action="reject"]'
        )
        with page.expect_response("**/v1/tag-decisions/batch"):
            review_travel_reject.click()
        page.wait_for_function("() => !state.tagMutating && !state.review.mutating")
        assert tag_decisions[-1]["tagID"] == TRAVEL_TAG_ID
        assert tag_decisions[-1]["action"] == "reject"
        assert set(tag_decisions[-1]["assetIDs"]) == set(REVIEW_IDS[:2])
        page.locator("#reviewInlineTagName").fill("网页审核新标签")
        with page.expect_response("**/v1/tags/create-and-apply"):
            page.locator("#reviewInlineTagForm").press("Enter")
        page.wait_for_function("() => !state.tagMutating && !state.review.mutating")
        assert created_tag_applications[-1] == {
            "name": "网页审核新标签",
            "assetIDs": REVIEW_IDS[:2],
        }
        page.locator(
            f'#reviewTags [data-tag-chip-action][data-tag-id="{NEW_REVIEW_TAG_ID}"]'
        ).wait_for()
        page.evaluate(
            f"""() => {{
              const container = document.querySelector("#reviewTags");
              window.__stableReviewInspectorSearchFrame = {{
                subject: container.querySelector(
                  '[data-inspector-tag-group-id="{SUBJECT_GROUP_ID}"]'
                ),
                scene: container.querySelector(
                  '[data-inspector-tag-group-id="{SCENE_GROUP_ID}"]'
                ),
                cat: container.querySelector(
                  '[data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]'
                ),
                travel: container.querySelector(
                  '[data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
                ),
                created: container.querySelector(
                  '[data-tag-chip-action][data-tag-id="{NEW_REVIEW_TAG_ID}"]'
                ),
              }};
            }}"""
        )
        page.locator("#reviewTagSearch").fill("旅行")
        assert page.locator("#reviewTags [data-tag-chip-action]").count() == 1
        assert page.locator(
            f'#reviewTags [data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
        ).is_visible()
        assert page.evaluate(
            f"""() => {{
              const frame = window.__stableReviewInspectorSearchFrame;
              const container = document.querySelector("#reviewTags");
              return container.querySelector(
                '[data-inspector-tag-group-id="{SCENE_GROUP_ID}"]'
              ) === frame.scene && container.querySelector(
                '[data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
              ) === frame.travel;
            }}"""
        )
        page.locator("#reviewTagSearch").fill("")
        stable_review_search = page.evaluate(
            f"""() => {{
              const frame = window.__stableReviewInspectorSearchFrame;
              const container = document.querySelector("#reviewTags");
              return {{
                subject: container.querySelector(
                  '[data-inspector-tag-group-id="{SUBJECT_GROUP_ID}"]'
                ) === frame.subject,
                scene: container.querySelector(
                  '[data-inspector-tag-group-id="{SCENE_GROUP_ID}"]'
                ) === frame.scene,
                cat: container.querySelector(
                  '[data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]'
                ) === frame.cat,
                travel: container.querySelector(
                  '[data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
                ) === frame.travel,
                created: container.querySelector(
                  '[data-tag-chip-action][data-tag-id="{NEW_REVIEW_TAG_ID}"]'
                ) === frame.created,
                focus: document.activeElement?.id === "reviewTagSearch",
              }};
            }}"""
        )
        assert all(stable_review_search.values()), stable_review_search
        page.locator('[data-review-index="0"] > .review-card-main').click()
        page.wait_for_function(
            f"() => state.review.selectedAssetIDs.size === 1 "
            f"&& state.review.detail?.assetID === '{REVIEW_IDS[0]}' "
            "&& !state.review.detailLoadingAssetID"
        )
        assert any(query.get("cursor") == ["review-page-2"] for query in review_queue_queries)
        review_pending_override[0] = 73
        review_task.update({
            "taskStatus": "running",
            "checkedCount": 41,
            "totalCount": 120,
            "skippedCount": 6,
        })
        page.evaluate("() => loadReviewOverview()")
        page.wait_for_function(
            "() => document.querySelector('#reviewSummary').textContent === "
            "'正在分析 · 已检查 41/120 · 跳过 6 · 待审核 73 条 · 已载入 3 条'"
        )
        page.screenshot(
            path="/tmp/imageall-review-authoritative-summary.png",
            full_page=True,
        )

        # A stale overview must never claim a smaller pending total while the
        # queue still exposes a continuation beyond its loaded window.
        review_pending_override[0] = 2
        page.evaluate(
            """() => {
              const overview = currentReviewQueueOverview();
              overview.pendingSuggestionCount = 2;
              state.review.nextCursor = 'stale-overview-page';
              renderReviewCollectionSummary();
            }"""
        )
        stale_summary = page.locator("#reviewSummary").inner_text()
        assert stale_summary == (
            "正在分析 · 已检查 41/120 · 跳过 6 · 已载入 3 条 · 还有更多"
        )
        assert "待审核 2 条" not in stale_summary
        page.evaluate(
            """() => {
              state.review.overviewLoadedScopeKey = 'previous-source-scope';
              renderReviewCollectionSummary();
            }"""
        )
        assert page.locator("#reviewSummary").inner_text() == "已载入 3 条 · 还有更多"

        # Overview refreshes while the queue is open must immediately redraw
        # the header rather than leaving the previous running state behind.
        review_pending_override[0] = None
        review_task.update({
            "taskStatus": "waiting",
            "checkedCount": 0,
            "totalCount": None,
            "skippedCount": 0,
        })
        page.evaluate("() => { state.review.nextCursor = null; return loadReviewOverview(); }")
        page.wait_for_function(
            "() => document.querySelector('#reviewSummary').textContent === "
            "'等待运行 · 待审核 3 条'"
        )
        review_task.update({
            "taskStatus": "completed",
            "checkedCount": 12,
            "totalCount": 12,
            "skippedCount": 0,
        })
        page.evaluate("() => loadReviewOverview()")
        page.wait_for_function(
            "() => document.querySelector('#reviewSummary').textContent === '待审核 3 条'"
        )
        first_review_card = page.locator(f'[data-review-index="0"]')
        first_review_main = first_review_card.locator(":scope > .review-card-main")
        first_review_favorite = first_review_card.locator(":scope > .review-card-favorite")
        assert first_review_main.get_attribute("aria-pressed") == "true"
        page.locator("#reviewSummary").hover()
        first_review_main.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for()
        assert page.locator("#persistentHelp").get_attribute("data-kind") == "review"
        queue_help_detail = page.locator("#persistentHelpDetail").inner_text()
        assert "当前主项目并已选择" in queue_help_detail
        assert "Command/Ctrl-A 全选已载入项目" in queue_help_detail
        assert "触控长按" in queue_help_detail
        assert "P X U" in first_review_main.get_attribute("aria-keyshortcuts")
        assert "Shift+F10" in first_review_main.get_attribute("aria-keyshortcuts")
        page.locator("#reviewSummary").hover()
        page.wait_for_function(
            "() => document.querySelector('#persistentHelp').classList.contains('hidden')"
        )
        review_queue_before_resize = page.evaluate(
            """() => {
              const pane = document.querySelector('#reviewQueuePane');
              const grid = document.querySelector('#reviewGrid');
              grid.style.paddingBottom = '960px';
              pane.scrollTop = 160;
              return {
                selectedIndex: state.review.selectedIndex,
                selectedAssetIDs: [...state.review.selectedAssetIDs].sort(),
                nextCursor: state.review.nextCursor,
                scrollTop: pane.scrollTop,
              };
            }"""
        )
        assert review_queue_before_resize["scrollTop"] > 0
        review_queue_handle = page.locator("#reviewQueueResizeHandle")
        review_queue_handle_box = review_queue_handle.bounding_box()
        assert review_queue_handle_box is not None
        review_queue_drag_x = (
            review_queue_handle_box["x"] + review_queue_handle_box["width"] / 2
        )
        review_queue_drag_y = (
            review_queue_handle_box["y"] + min(120, review_queue_handle_box["height"] / 2)
        )
        page.mouse.move(review_queue_drag_x, review_queue_drag_y)
        page.mouse.down()
        page.mouse.move(review_queue_drag_x - 50, review_queue_drag_y, steps=6)
        page.mouse.up()
        page.wait_for_function("() => state.layout.reviewInspectorWidth === 350")
        assert review_queue_handle.get_attribute("aria-valuenow") == "350"
        assert page.evaluate(
            "() => ({ selectedIndex: state.review.selectedIndex, "
            "selectedAssetIDs: [...state.review.selectedAssetIDs].sort(), "
            "nextCursor: state.review.nextCursor, "
            "scrollTop: document.querySelector('#reviewQueuePane').scrollTop })"
        ) == review_queue_before_resize
        review_queue_handle.focus()
        page.keyboard.press("Home")
        assert review_queue_handle.get_attribute("aria-valuenow") == "240"
        page.keyboard.press("ArrowLeft")
        assert review_queue_handle.get_attribute("aria-valuenow") == "250"
        assert page.evaluate(
            "() => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
            ".reviewInspectorWidth"
        ) == 250
        page.evaluate(
            "() => { state.layout.reviewInspectorWidth = 380; renderLayoutPreferences(); "
            "loadWorkspacePreferences(); renderLayoutPreferences(); }"
        )
        assert review_queue_handle.get_attribute("aria-valuenow") == "250"
        review_queue_handle.dblclick()
        assert review_queue_handle.get_attribute("aria-valuenow") == "300"
        page.set_viewport_size({"width": 390, "height": 844})
        assert review_queue_handle.is_hidden()
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#reviewGrid").evaluate(
            "element => { element.style.paddingBottom = ''; "
            "element.closest('#reviewQueuePane').scrollTop = 0; }"
        )
        page.screenshot(path="/tmp/imageall-review-queue-split.png", full_page=True)
        first_review_main.focus()
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        assert page.locator("#commandContextLabel").inner_text() == "当前：建议审核队列"
        assert page.locator('[data-command-id="selectAll"]').count() == 1
        assert page.locator('[data-command-id="media:video"]').count() == 1
        assert page.locator('[data-command-id="openReviewSources"]').count() == 1
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('review-card-main')"
        )
        page.keyboard.press("ArrowRight")
        assert page.evaluate("() => state.review.selectedIndex") == 1
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 1
        assert page.evaluate(
            "id => document.activeElement?.closest('[data-review-asset-id]')"
            "?.dataset.reviewAssetId === id "
            "&& document.querySelectorAll('#reviewGrid .review-card-main[tabindex=\"0\"]')"
            ".length === 1 "
            "&& document.querySelectorAll('#reviewGrid .review-card-favorite[tabindex=\"0\"]')"
            ".length === 1",
            REVIEW_IDS[1],
        )
        page.keyboard.down("Shift")
        page.keyboard.press("ArrowRight")
        page.keyboard.up("Shift")
        assert page.evaluate("() => state.review.selectedIndex") == 2
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 2
        page.keyboard.press("Home")
        assert page.evaluate("() => state.review.selectedIndex") == 0
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 1
        page.keyboard.press("End")
        assert page.evaluate("() => state.review.selectedIndex") == 2
        page.keyboard.press("PageUp")
        assert page.evaluate("() => state.review.selectedIndex") == 0
        page.keyboard.press("PageDown")
        assert page.evaluate("() => state.review.selectedIndex") == 2
        page.keyboard.press("Home")
        page.keyboard.press("Space")
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        review_shortcut_request_count = len(asset_queries)
        page.keyboard.press("?")
        page.locator("#shortcutDialog[open]").wait_for()
        assert page.locator("#shortcutContextLabel").inner_text() == (
            "当前：全屏预览 · 建议审核队列"
        )
        assert page.locator('[data-shortcut-id="previewZoom"]').count() == 1
        assert page.locator('[data-shortcut-id="previewReviewDecision"]').count() == 1
        assert page.locator('[data-shortcut-id="reviewDecision"]').count() == 0
        assert page.locator('[data-shortcut-id="galleryNavigate"]').count() == 0
        page.keyboard.press("Escape")
        page.locator("#shortcutDialog").wait_for(state="hidden")
        assert page.locator("#lightbox:not(.hidden)").is_visible()
        assert len(asset_queries) == review_shortcut_request_count
        page.keyboard.press("Space")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('review-card-main')"
        )
        review_selection_before_layout = page.evaluate(
            "() => ({ selectedIndex: state.review.selectedIndex, "
            "selectedAssetIDs: [...state.review.selectedAssetIDs], "
            "scrollTop: document.querySelector('#reviewQueuePane').scrollTop })"
        )
        page.evaluate(
            "() => { globalThis.__densityPreservedReviewCard = "
            "document.querySelector('#reviewGrid .review-card'); }"
        )
        review_density_button = page.locator("#reviewGridDensityButton")
        review_density_button.click()
        review_density_menu = page.locator("#reviewGridDensityPopover:not(.hidden)")
        review_density_menu.wait_for()
        assert review_density_menu.locator("[data-grid-density]").all_inner_texts() == [
            "微缩", "精细", "紧凑", "标准", "大图", "较大", "很大", "特大", "巨大",
        ]
        assert review_density_menu.locator(
            '[data-grid-density="3"]'
        ).get_attribute("aria-checked") == "true"
        assert page.evaluate(
            "() => migrateLegacyGridDensity(4) === 3 "
            "&& migrateLegacyGridDensity(8) === 5"
        )
        page.wait_for_function(
            "() => document.activeElement?.dataset.gridDensity === '3'"
        )
        page.wait_for_function(
            "() => !state.loadingAssets "
            "&& !state.assetLoadPromise "
            "&& !state.queuedAssetLoadOptions "
            "&& state.assetRenderedQuerySignature === assetQuerySignature()"
        )
        review_density_history_queries = len(asset_queries)
        review_density_history = page.evaluate(
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
        assert review_density_history["route"] == "review"
        assert review_density_history["navigationLevel"] == "layoutMenu"
        assert review_density_history["baseLevel"] == "workspace"
        assert review_density_history["kind"] == "reviewGridDensity"
        assert "layoutMenuFocusedValue" not in review_density_history["serialized"]
        assert "layoutMenuReturnFocus" not in review_density_history["serialized"]
        page.evaluate("() => history.back()")
        review_density_menu.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'reviewGridDensityButton'"
        )
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        assert len(asset_queries) == review_density_history_queries
        page.evaluate("() => history.forward()")
        review_density_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.gridDensity === '3'"
        )
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        assert len(asset_queries) == review_density_history_queries
        page.keyboard.press("Home")
        assert page.evaluate(
            "() => document.activeElement?.dataset.gridDensity === '0'"
        )
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.gridDensity === '8'"
        )
        page.keyboard.press("Escape")
        assert review_density_menu.is_hidden()
        assert page.evaluate(
            "() => document.activeElement?.id === 'reviewGridDensityButton'"
        )
        review_density_button.click()
        page.screenshot(path="/tmp/imageall-density-menu-desktop.png", full_page=True)
        review_density_menu.locator('[data-grid-density="8"]').click()
        assert review_density_button.get_attribute("aria-expanded") == "false"
        assert review_density_button.get_attribute("aria-label") == "缩略图大小：巨大"
        assert page.locator("#gridDensityButton").get_attribute("aria-label") == "缩略图大小：巨大"
        assert page.locator("#slimmingGridDensityButton").get_attribute("aria-label") == "缩略图大小：巨大"
        assert page.evaluate(
            "() => getComputedStyle(document.documentElement)"
            ".getPropertyValue('--asset-min-width').trim()"
        ) == "620px"
        stored_giant_layout = page.evaluate(
            "() => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
        )
        assert stored_giant_layout["density"] == 8
        assert stored_giant_layout["densityScaleVersion"] == 2
        review_density_button.click()
        page.locator(
            '#reviewGridDensityPopover:not(.hidden) [data-grid-density="5"]'
        ).click()
        assert page.evaluate(
            "() => getComputedStyle(document.documentElement)"
            ".getPropertyValue('--asset-min-width').trim()"
        ) == "245px"
        assert page.evaluate(
            "() => globalThis.__densityPreservedReviewCard "
            "=== document.querySelector('#reviewGrid .review-card')"
        )
        assert page.evaluate(
            """() => {
              const original = loadAssets;
              let calls = 0;
              loadAssets = (...args) => { calls += 1; return original(...args); };
              try { applyGridDensity(8); applyGridDensity(5); return calls; }
              finally { loadAssets = original; }
            }"""
        ) == 0
        aspect_controls = [
            "#thumbnailAspectButton",
            "#reviewThumbnailAspectButton",
            "#slimmingThumbnailAspectButton",
        ]
        for selector in aspect_controls:
            control = page.locator(selector)
            assert control.get_attribute("data-aspect-mode") == "square"
            assert control.get_attribute("aria-label") == "缩略图比例：正方形"
            assert control.locator(".thumbnail-aspect-label").text_content() == "正方形"
        assert "当前缩略图为正方形" in page.locator(
            "#reviewThumbnailAspectButton"
        ).get_attribute("data-help-detail")
        page.evaluate(
            "() => { globalThis.__aspectPreservedReviewCard = "
            "document.querySelector('#reviewGrid .review-card'); }"
        )
        aspect_asset_load_calls = page.evaluate(
            """() => {
              const original = loadAssets;
              let calls = 0;
              loadAssets = (...args) => { calls += 1; return original(...args); };
              try {
                document.querySelector('#reviewThumbnailAspectButton').click();
                return calls;
              } finally { loadAssets = original; }
            }"""
        )
        assert aspect_asset_load_calls == 0
        page.wait_for_function(
            "() => [...document.querySelectorAll('#reviewGrid .review-card img')]"
            ".every(image => image.naturalWidth > 1 && image.naturalHeight > 1)"
        )
        assert page.evaluate(
            "() => [...document.querySelectorAll('#reviewGrid .review-card img')]"
            ".map(image => [image.naturalWidth, image.naturalHeight])"
        ) == [[1200, 900], [900, 1200], [512, 512]]
        assert page.locator("#reviewGrid").get_attribute("class").find("original-aspect") >= 0
        assert page.locator("#assetGrid").get_attribute("class").find("original-aspect") >= 0
        for selector in aspect_controls:
            control = page.locator(selector)
            assert control.get_attribute("data-aspect-mode") == "original"
            assert control.get_attribute("aria-label") == "缩略图比例：原比例"
            assert control.locator(".thumbnail-aspect-label").text_content() == "原比例"
            assert control.get_attribute("aria-pressed") is None
        assert "当前优先显示已手动缓存的原比例缩略图" in page.locator(
            "#reviewThumbnailAspectButton"
        ).get_attribute("data-help-detail")
        assert page.evaluate(
            "() => globalThis.__aspectPreservedReviewCard "
            "=== document.querySelector('#reviewGrid .review-card')"
        )
        first_box = first_review_card.bounding_box()
        second_box = page.locator('[data-review-index="1"]').bounding_box()
        assert first_box is not None and second_box is not None
        assert abs(first_box["width"] / first_box["height"] - 4 / 3) < 0.08, first_box
        assert abs(second_box["width"] / second_box["height"] - 3 / 4) < 0.08, second_box
        third_box = page.locator('[data-review-index="2"]').bounding_box()
        assert third_box is not None
        assert abs(third_box["width"] / third_box["height"] - 1) < 0.08, third_box
        assert {item["assetID"] for item in thumbnail_queries if item["aspect"] == "original"} \
            >= set(REVIEW_IDS)
        review_selection_after_layout = page.evaluate(
            "() => ({ selectedIndex: state.review.selectedIndex, "
            "selectedAssetIDs: [...state.review.selectedAssetIDs], "
            "scrollTop: document.querySelector('#reviewQueuePane').scrollTop })"
        )
        assert review_selection_after_layout == review_selection_before_layout, (
            review_selection_before_layout,
            review_selection_after_layout,
        )
        stored_layout = page.evaluate(
            "() => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
        )
        assert stored_layout["density"] == 5
        assert stored_layout["densityScaleVersion"] == 2
        assert stored_layout["aspectMode"] == "original"
        original_review_count = len(review_items)
        marquee_review_ids = []
        for index in range(1, 37):
            asset_id = f"92000000-0000-4000-8000-{index:012d}"
            marquee_review_ids.append(asset_id)
            favorite_states[asset_id] = False
            review_items.append({
                **review_items[0],
                "assetID": asset_id,
                "fileName": f"REVIEW_MARQUEE_{index:03d}.JPG",
            })
        page.evaluate(
            "() => loadReviewQueue({ preserveLoadedWindow: true })"
        )
        page.wait_for_function(
            "expected => state.review.items.length === expected",
            arg=len(review_items),
        )
        review_queue_query_count_before_marquee = len(review_queue_queries)
        review_marquee_scroll, review_marquee_selection_before_refresh = drag_marquee_to_bottom_edge(
            page,
            "#reviewQueuePane",
            "#reviewGrid",
        )
        review_marquee_selection = page.evaluate(
            "() => [...state.review.selectedAssetIDs]"
        )
        assert review_marquee_scroll > 80
        assert any(
            asset_id.startswith("92000000-0000-4000-8000-")
            for asset_id in review_marquee_selection_before_refresh
        ), review_marquee_selection_before_refresh
        assert REVIEW_IDS[0] in review_marquee_selection
        assert any(
            asset_id.startswith("92000000-0000-4000-8000-")
            for asset_id in review_marquee_selection
        ), review_marquee_selection
        assert len(review_queue_queries) > review_queue_query_count_before_marquee
        review_items[:] = review_items[:original_review_count]
        for asset_id in marquee_review_ids:
            favorite_states.pop(asset_id)
        page.evaluate(
            """() => {
              document.querySelector('#reviewQueuePane').scrollTop = 0;
              return loadReviewQueue({ preserveLoadedWindow: true });
            }"""
        )
        page.wait_for_function(
            "expected => !state.review.marquee && !state.review.loading "
            "&& state.review.items.length === expected",
            arg=len(REVIEW_IDS),
        )
        page.keyboard.press("Meta+K")
        page.locator('[data-command-id="selectAll"]').click()
        page.wait_for_function(
            "() => state.review.selectedAssetIDs.size === state.review.items.length"
        )
        assert set(page.evaluate("() => [...state.review.selectedAssetIDs]")) == set(REVIEW_IDS)
        page.keyboard.press("Meta+K")
        assert page.locator('[data-command-id="reviewAcceptSelection"]').count() == 1
        assert page.locator('[data-command-id="reviewRejectSelection"]').count() == 1
        assert page.locator('[data-command-id="reviewDeferSelection"]').count() == 1
        page.screenshot(path="/tmp/imageall-review-command-actions.png", full_page=True)
        page.keyboard.press("Escape")
        review_action_title = page.locator("#reviewInspectorSelectionTitle")
        review_favorite_action = page.locator("#reviewInspectorFavoriteButton")
        review_unfavorite_action = page.locator("#reviewInspectorUnfavoriteButton")
        review_delete_action = page.locator("#reviewInspectorDeleteButton")
        assert review_action_title.inner_text() == "已选择 3 张照片"
        assert review_favorite_action.is_visible()
        assert review_unfavorite_action.is_visible()
        assert review_delete_action.is_visible()
        assert review_favorite_action.is_enabled()
        assert review_unfavorite_action.is_enabled()
        assert review_delete_action.is_enabled()
        with page.expect_response("**/v1/favorites"):
            review_favorite_action.click()
        page.wait_for_function(
            "() => state.review.items.every(item => item.favorite?.isFavorite === true)"
        )
        assert set(favorite_mutations[-1]["assetIDs"]) == set(REVIEW_IDS)
        assert favorite_mutations[-1]["isFavorite"] is True
        with page.expect_response("**/v1/favorites"):
            review_unfavorite_action.click()
        page.wait_for_function(
            "() => state.review.items.every(item => item.favorite?.isFavorite === false)"
        )
        assert favorite_mutations[-1]["isFavorite"] is False
        first_review_main.click()
        page.wait_for_function("() => state.review.selectedAssetIDs.size === 1")
        review_scroll_top = page.locator("#reviewQueuePane").evaluate("element => element.scrollTop")
        page.wait_for_function(
            "() => !state.loadingAssets "
            "&& !state.assetLoadPromise "
            "&& !state.queuedAssetLoadOptions "
            "&& state.assetRenderedQuerySignature === assetQuerySignature()"
        )
        review_context_snapshot = page.evaluate(
            "() => ({ selectedIndex: state.review.selectedIndex, "
            "selectedAssetIDs: [...state.review.selectedAssetIDs], "
            "selectionAnchorIndex: state.review.selectionAnchorIndex, "
            "itemIDs: state.review.items.map(item => item.assetID), "
            "nextCursor: state.review.nextCursor, "
            "scrollTop: document.querySelector('#reviewQueuePane').scrollTop })"
        )
        review_context_asset_query_count = len(asset_queries)
        review_context_decision_count = len(review_decisions)
        first_review_main.click(button="right")
        review_context_menu = page.locator("#reviewContextMenu:not(.hidden)")
        review_context_menu.wait_for()
        assert page.locator("#reviewContextMenuTitle").inner_text() == (
            "REVIEW_1.JPG · 相似特征建议"
        )
        review_context_preview = page.locator("#reviewPreviewContextAction")
        review_context_favorite = page.locator("#reviewFavoriteContextAction")
        assert "单图查看" in review_context_preview.inner_text()
        assert review_context_favorite.inner_text() == "加入红心"
        assert review_context_favorite.get_attribute("data-favorite") == "false"
        page.wait_for_function(
            "() => document.activeElement?.id === 'reviewPreviewContextAction'"
        )
        review_context_history = page.evaluate(
            """() => {
              const entry = history.state?.imageAllWorkspace;
              return {
                route: entry?.route,
                navigationLevel: entry?.navigationLevel,
                kind: entry?.context?.contextMenuKind,
                contextKeys: Object.keys(entry?.context || {}),
              };
            }"""
        )
        assert review_context_history["route"] == "review"
        assert review_context_history["navigationLevel"] == "contextMenu"
        assert review_context_history["kind"] == "review"
        assert all(
            key in {"contextMenuKind", "contextMenuBaseLevel"}
            for key in review_context_history["contextKeys"]
            if key.startswith("contextMenu")
        )
        page.evaluate("() => history.back()")
        review_context_menu.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('review-card-main')"
        )
        assert len(asset_queries) == review_context_asset_query_count
        assert len(review_decisions) == review_context_decision_count
        page.evaluate("() => history.forward()")
        review_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'reviewPreviewContextAction'"
        )
        assert page.evaluate(
            "() => ({ selectedIndex: state.review.selectedIndex, "
            "selectedAssetIDs: [...state.review.selectedAssetIDs], "
            "selectionAnchorIndex: state.review.selectionAnchorIndex, "
            "itemIDs: state.review.items.map(item => item.assetID), "
            "nextCursor: state.review.nextCursor, "
            "scrollTop: document.querySelector('#reviewQueuePane').scrollTop })"
        ) == review_context_snapshot
        assert len(asset_queries) == review_context_asset_query_count
        assert len(review_decisions) == review_context_decision_count
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('review-card-main')"
        )
        first_review_main.press("Shift+F10")
        review_context_menu.wait_for()
        with page.expect_response("**/v1/favorites"):
            review_context_favorite.click()
        page.wait_for_function(
            f"() => state.review.items.find(item => item.assetID === '{REVIEW_IDS[0]}')"
            "?.favorite?.isFavorite === true"
        )
        assert favorite_mutations[-1]["assetIDs"] == [REVIEW_IDS[0]]
        assert favorite_mutations[-1]["isFavorite"] is True
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('review-card-main')"
        )
        first_review_main.click(button="right")
        assert review_context_favorite.inner_text() == "取消红心"
        with page.expect_response("**/v1/favorites"):
            review_context_favorite.click()
        page.wait_for_function(
            f"() => state.review.items.find(item => item.assetID === '{REVIEW_IDS[0]}')"
            "?.favorite?.isFavorite === false"
        )
        review_main_bounds = first_review_main.bounding_box()
        assert review_main_bounds is not None
        review_long_press_point = {
            "x": review_main_bounds["x"] + min(44, review_main_bounds["width"] / 2),
            "y": review_main_bounds["y"] + min(44, review_main_bounds["height"] / 2),
        }
        page.evaluate(
            """point => document.querySelector('[data-review-index="0"] > .review-card-main')
              .dispatchEvent(new PointerEvent('pointerdown', {
                bubbles: true,
                pointerId: 93,
                pointerType: 'touch',
                button: 0,
                clientX: point.x,
                clientY: point.y,
                isPrimary: true,
              }))""",
            review_long_press_point,
        )
        page.wait_for_timeout(580)
        review_context_menu.wait_for()
        assert review_context_favorite.inner_text() == "加入红心"
        page.screenshot(path="/tmp/imageall-review-long-press-menu.png", full_page=True)
        review_context_preview.click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate(
            "() => ({ selectedIndex: state.review.selectedIndex, "
            "selectedAssetIDs: [...state.review.selectedAssetIDs], "
            "selectionAnchorIndex: state.review.selectionAnchorIndex, "
            "itemIDs: state.review.items.map(item => item.assetID), "
            "nextCursor: state.review.nextCursor, "
            "scrollTop: document.querySelector('#reviewQueuePane').scrollTop })"
        ) == review_context_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('review-card-main')"
        )
        assert page.evaluate(
            "() => ({ selectedIndex: state.review.selectedIndex, "
            "selectedAssetIDs: [...state.review.selectedAssetIDs], "
            "selectionAnchorIndex: state.review.selectionAnchorIndex, "
            "itemIDs: state.review.items.map(item => item.assetID), "
            "nextCursor: state.review.nextCursor, "
            "scrollTop: document.querySelector('#reviewQueuePane').scrollTop })"
        ) == review_context_snapshot
        assert len(asset_queries) == review_context_asset_query_count
        assert len(review_decisions) == review_context_decision_count
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
        page.keyboard.press("Meta+K")
        page.locator('[data-command-id="showAll"]').click()
        page.locator("#reviewWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )
        page.evaluate("() => history.back()")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for()
        page.locator("#reviewQueueLayout:not(.hidden)").wait_for()
        assert page.locator("#reviewTagSelect").input_value() == CAT_TAG_ID
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route === 'review'"
        )
        page.wait_for_function(
            "assetID => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise "
            "&& !state.review.loading "
            "&& state.review.loadedScopeKey === currentReviewScopeKey() "
            "&& state.review.selectedAssetIDs.size === 1 "
            "&& state.review.selectedAssetIDs.has(assetID)",
            arg=REVIEW_IDS[0],
        )

        page.set_viewport_size({"width": 390, "height": 844})
        assert first_review_favorite.is_visible()
        review_selection_mode = page.locator("#reviewSelectionModeButton")
        review_select_all = page.locator("#reviewSelectAllButton")
        assert review_selection_mode.is_visible()
        review_selection_mode.click()
        assert review_selection_mode.get_attribute("aria-pressed") == "true"
        assert review_selection_mode.inner_text() == "完成"
        assert review_select_all.is_visible()
        second_review_card = page.locator('[data-review-index="1"]')
        second_review_card.hover()
        page.evaluate(
            """() => {
              const card = document.querySelector('[data-review-index="1"]');
              const mark = card.querySelector(':scope > .review-selection-mark');
              const frame = {
                card,
                main: card.querySelector(':scope > .review-card-main'),
                image: card.querySelector(':scope > .review-card-main > img'),
                mark,
                markText: mark.firstChild,
                scrollTop: document.querySelector('#reviewQueuePane').scrollTop,
                added: 0,
                removed: 0,
              };
              frame.observer = new MutationObserver((records) => {
                for (const record of records) {
                  frame.added += record.addedNodes.length;
                  frame.removed += record.removedNodes.length;
                }
              });
              frame.observer.observe(mark, { childList: true, subtree: true });
              frame.main.focus({ preventScroll: true });
              const range = document.createRange();
              range.selectNodeContents(frame.markText);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              window.__reviewSelectionMarkFrame = frame;
              selectReviewIndex(1, { additive: true });
            }"""
        )
        page.wait_for_function("() => state.review.selectedAssetIDs.size === 2")
        page.wait_for_function(
            "() => getComputedStyle(document.querySelector("
            "'[data-review-index=\"1\"] > .review-selection-mark'"
            ")).opacity === '1'"
        )
        review_selection_mark_continuity = page.evaluate(
            """() => {
              const frame = window.__reviewSelectionMarkFrame;
              const card = document.querySelector('[data-review-index="1"]');
              const mark = card.querySelector(':scope > .review-selection-mark');
              const selection = getSelection();
              frame.observer.disconnect();
              return {
                card: card === frame.card,
                main: frame.main === card.querySelector(':scope > .review-card-main'),
                image: frame.image === frame.main.querySelector(':scope > img'),
                mark: mark === frame.mark,
                markText: frame.markText === mark.firstChild,
                selected: card.classList.contains('selected') && mark.textContent === '✓',
                visible: getComputedStyle(mark).visibility === 'visible'
                  && getComputedStyle(mark).opacity === '1',
                selectionNode: selection.anchorNode === frame.markText,
                hovered: card.matches(':hover'),
                focused: document.activeElement === frame.main,
                scroll: document.querySelector('#reviewQueuePane').scrollTop === frame.scrollTop,
                zeroChildMutations: frame.added === 0 && frame.removed === 0,
              };
            }"""
        )
        assert all(review_selection_mark_continuity.values()), (
            review_selection_mark_continuity
        )
        page.locator('[data-review-index="2"] > .review-card-main').click()
        page.wait_for_function("() => state.review.selectedAssetIDs.size === 3")
        assert review_select_all.is_disabled()
        page.locator('[data-review-index="1"] > .review-card-main').click()
        page.wait_for_function("() => state.review.selectedAssetIDs.size === 2")
        page.wait_for_function(
            "() => !document.querySelector('#reviewSelectAllButton').disabled"
        )
        review_select_all.click()
        page.wait_for_function("() => state.review.selectedAssetIDs.size === 3")
        page.screenshot(
            path="/tmp/imageall-review-touch-selection-active-390.png",
            full_page=True,
        )
        review_double_click_snapshot = page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.review.selectedAssetIDs].sort(),
              selectedIndex: state.review.selectedIndex,
              selectionAnchorIndex: state.review.selectionAnchorIndex,
              scrollTop: document.querySelector('#reviewQueuePane').scrollTop,
            })"""
        )
        page.locator('[data-review-index="1"] > .review-card-main').dblclick()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "REVIEW_2.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.review.selectedAssetIDs].sort(),
              selectedIndex: state.review.selectedIndex,
              selectionAnchorIndex: state.review.selectionAnchorIndex,
              scrollTop: document.querySelector('#reviewQueuePane').scrollTop,
            })"""
        ) == review_double_click_snapshot
        assert page.evaluate("() => state.lightboxPreservesSelection") is True
        page.locator("#lightboxNextButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_3.JPG')"
        )
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.review.selectedAssetIDs].sort(),
              selectedIndex: state.review.selectedIndex,
              selectionAnchorIndex: state.review.selectionAnchorIndex,
              scrollTop: document.querySelector('#reviewQueuePane').scrollTop,
            })"""
        ) == review_double_click_snapshot
        page.keyboard.press("Escape")
        page.locator("#lightbox").wait_for(state="hidden")
        assert page.evaluate(
            """() => ({
              selectedAssetIDs: [...state.review.selectedAssetIDs].sort(),
              selectedIndex: state.review.selectedIndex,
              selectionAnchorIndex: state.review.selectionAnchorIndex,
              scrollTop: document.querySelector('#reviewQueuePane').scrollTop,
            })"""
        ) == review_double_click_snapshot
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('review-card-main')"
        )
        review_selection_mode.click()
        assert review_selection_mode.get_attribute("aria-pressed") == "false"
        assert review_selection_mode.inner_text() == "选择"
        assert review_select_all.is_hidden()
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 1
        review_selection_mode.click()
        page.locator('[data-review-index="1"] > .review-card-main').click()
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 2
        page.keyboard.press("Escape")
        assert page.locator("#reviewWorkspace").is_visible()
        assert review_selection_mode.get_attribute("aria-pressed") == "false"
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 1
        page.wait_for_function(
            "() => document.activeElement?.id === 'reviewSelectionModeButton'"
        )
        first_review_main.click()
        assert page.evaluate("() => state.review.selectedIndex") == 0
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 1
        review_toolbar_bounds = page.evaluate(
            "() => Object.fromEntries(["
            "'reviewTagSelect', 'reviewSourceFilterButton', 'reviewSuggestionLimitControl', "
            "'reviewThumbnailAspectButton', 'reviewGridDensityButton', "
            "'reviewSelectionModeButton', 'refreshReviewButton'"
            "].map(id => { const rect = document.getElementById(id).getBoundingClientRect(); "
            "return [id, { left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom }]; }))"
        )
        assert all(
            bounds["left"] >= 0
            and bounds["right"] <= 390
            and bounds["top"] >= 0
            and bounds["bottom"] <= 844
            for bounds in review_toolbar_bounds.values()
        ), review_toolbar_bounds
        review_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert review_dimensions["scroll"] <= review_dimensions["viewport"], review_dimensions
        review_density_button.click()
        mobile_density_bounds = page.locator(
            "#reviewGridDensityPopover:not(.hidden)"
        ).evaluate(
            "element => { const rect = element.getBoundingClientRect(); return ({ "
            "left: rect.left, right: rect.right, top: rect.top, bottom: rect.bottom, "
            "width: innerWidth, height: innerHeight, scroll: document.documentElement.scrollWidth "
            "}); }"
        )
        assert mobile_density_bounds["left"] >= 8, mobile_density_bounds
        assert mobile_density_bounds["right"] <= mobile_density_bounds["width"] - 8, (
            mobile_density_bounds
        )
        assert mobile_density_bounds["top"] >= 8, mobile_density_bounds
        assert mobile_density_bounds["bottom"] <= mobile_density_bounds["height"] - 8, (
            mobile_density_bounds
        )
        assert mobile_density_bounds["scroll"] <= mobile_density_bounds["width"], (
            mobile_density_bounds
        )
        page.screenshot(path="/tmp/imageall-density-menu-390.png", full_page=True)
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.id === 'reviewGridDensityButton'"
        )
        page.screenshot(path="/tmp/imageall-review-card-favorite-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})

        prefetched_review_2_path = f"/v1/assets/{REVIEW_IDS[1]}/preview?r=2"
        review_2_preview_count_before_prefetch = sum(
            prefetched_review_2_path in url for url in preview_requests
        )
        page.locator("#reviewOpenLightboxButton").click()
        page.locator("#lightboxReviewActions:not(.hidden)").wait_for()
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        page.wait_for_function(
            "path => state.lightboxPreviewPrefetches instanceof Map "
            "&& state.lightboxPreviewPrefetches.get(path)?.status === 'ready'",
            arg=prefetched_review_2_path,
        )
        prefetched_review_2_request_count = sum(
            prefetched_review_2_path in url for url in preview_requests
        )
        assert prefetched_review_2_request_count == review_2_preview_count_before_prefetch + 1, [
            url for url in preview_requests if prefetched_review_2_path in url
        ]
        assert page.evaluate(
            "() => [...state.lightboxPreviewPrefetches.keys()]"
            ".every(path => path.includes('/preview') && !path.includes('/original'))"
        )
        held_frame_path = "/v1/assets/frame-hold/preview"
        previous_frame = page.evaluate(
            """path => {
              const image = document.querySelector('#lightboxImage');
              const originalFetch = window.fetch.bind(window);
              window.__imageAllOriginalFetch = originalFetch;
              window.__imageAllOriginalDecode = HTMLImageElement.prototype.decode;
              window.__imageAllHeldDecode = null;
              HTMLImageElement.prototype.decode = function() {
                if (!this.isConnected && !window.__imageAllHeldDecode) {
                  return new Promise(resolve => {
                    window.__imageAllHeldDecode = { resolve };
                  });
                }
                return window.__imageAllOriginalDecode.call(this);
              };
              window.fetch = (input, options) => {
                const requestPath = typeof input === 'string' ? input : input?.url;
                if (requestPath === path) {
                  return new Promise((resolve, reject) => {
                    window.__imageAllHeldFrame = { resolve, reject };
                  });
                }
                return originalFetch(input, options);
              };
              const previous = {
                src: image.getAttribute('src'),
                visiblePath: image.dataset.protectedVisiblePath,
              };
              setProtectedImageSource(image, path, {
                priority: 'high',
                forceFetch: true,
                preserveCurrent: true,
              });
              return {
                previous,
                currentSrc: image.getAttribute('src'),
                requestedPath: image.dataset.protectedPath,
                visiblePath: image.dataset.protectedVisiblePath,
                transitioning: image.classList.contains('protected-image-transitioning'),
                busy: image.getAttribute('aria-busy'),
              };
            }""",
            held_frame_path,
        )
        assert previous_frame["previous"]["src"]
        assert previous_frame["currentSrc"] == previous_frame["previous"]["src"]
        assert previous_frame["requestedPath"] == held_frame_path
        assert previous_frame["visiblePath"] == previous_frame["previous"]["visiblePath"]
        assert previous_frame["transitioning"] is True
        assert previous_frame["busy"] == "true"
        held_png = base64.b64encode(PNG_BYTES).decode("ascii")
        page.evaluate(
            """payload => {
              const bytes = Uint8Array.from(atob(payload), character => character.charCodeAt(0));
              window.__imageAllHeldFrame.resolve(new Response(bytes, {
                status: 200,
                headers: { 'Content-Type': 'image/png' },
              }));
            }""",
            held_png,
        )
        page.wait_for_function("() => Boolean(window.__imageAllHeldDecode)")
        held_after_fetch = page.evaluate(
            """() => {
              const image = document.querySelector('#lightboxImage');
              return {
                src: image.getAttribute('src'),
                visiblePath: image.dataset.protectedVisiblePath,
                requestedPath: image.dataset.protectedPath,
                transitioning: image.classList.contains('protected-image-transitioning'),
                busy: image.getAttribute('aria-busy'),
              };
            }"""
        )
        assert held_after_fetch == {
            "src": previous_frame["previous"]["src"],
            "visiblePath": previous_frame["previous"]["visiblePath"],
            "requestedPath": held_frame_path,
            "transitioning": True,
            "busy": "true",
        }
        page.evaluate(
            """() => {
              HTMLImageElement.prototype.decode = window.__imageAllOriginalDecode;
              window.__imageAllHeldDecode.resolve();
            }"""
        )
        page.wait_for_function(
            "path => document.querySelector('#lightboxImage').dataset.protectedVisiblePath === path "
            "&& !document.querySelector('#lightboxImage')"
            ".classList.contains('protected-image-transitioning') "
            "&& document.querySelector('#lightboxImage').getAttribute('aria-busy') === 'false'",
            arg=held_frame_path,
        )
        resolved_frame_src = page.locator("#lightboxImage").get_attribute("src")
        assert resolved_frame_src != previous_frame["previous"]["src"]
        held_failure_path = "/v1/assets/frame-failure/preview"
        pending_failure = page.evaluate(
            """path => {
              const image = document.querySelector('#lightboxImage');
              window.fetch = (input, options) => {
                const requestPath = typeof input === 'string' ? input : input?.url;
                if (requestPath === path) {
                  return new Promise(resolve => {
                    window.__imageAllHeldFrameFailure = { resolve };
                  });
                }
                return window.__imageAllOriginalFetch(input, options);
              };
              const previousSrc = image.getAttribute('src');
              setProtectedImageSource(image, path, {
                priority: 'high',
                forceFetch: true,
                preserveCurrent: true,
              });
              return {
                previousSrc,
                currentSrc: image.getAttribute('src'),
                transitioning: image.classList.contains('protected-image-transitioning'),
              };
            }""",
            held_failure_path,
        )
        assert pending_failure == {
            "previousSrc": resolved_frame_src,
            "currentSrc": resolved_frame_src,
            "transitioning": True,
        }
        page.evaluate(
            """() => window.__imageAllHeldFrameFailure.resolve(new Response(
              JSON.stringify({ message: 'synthetic frame failure' }),
              { status: 503, headers: { 'Content-Type': 'application/json' } }
            ))"""
        )
        page.wait_for_function(
            "() => !document.querySelector('#lightboxImage').hasAttribute('src') "
            "&& !document.querySelector('#lightboxImage')"
            ".classList.contains('protected-image-transitioning') "
            "&& document.querySelector('#lightboxImage').getAttribute('aria-busy') === 'false'"
        )
        page.evaluate(
            """path => {
              const image = document.querySelector('#lightboxImage');
              window.fetch = window.__imageAllOriginalFetch;
              setProtectedImageSource(image, path, {
                priority: 'high',
                forceFetch: true,
                preserveCurrent: true,
              });
            }""",
            f"/v1/assets/{REVIEW_IDS[0]}/preview?r=1",
        )
        page.wait_for_function(
            "path => document.querySelector('#lightboxImage').dataset.protectedVisiblePath === path",
            arg=f"/v1/assets/{REVIEW_IDS[0]}/preview?r=1",
        )
        review_lightbox_layout = page.evaluate(
            """() => {
              const lightbox = document.querySelector('#lightbox');
              const queue = document.querySelector('#reviewQueuePane');
              const detail = document.querySelector('.review-detail-pane');
              const lightboxBounds = lightbox.getBoundingClientRect();
              const queueBounds = queue.getBoundingClientRect();
              const detailBounds = detail.getBoundingClientRect();
              return {
                docked: lightbox.classList.contains('review-docked'),
                modal: lightbox.getAttribute('aria-modal'),
                appInert: document.querySelector('#appView').inert,
                reviewInert: document.querySelector('#reviewWorkspace').inert,
                queueInert: queue.inert,
                titlebarInert: document.querySelector('.titlebar').inert,
                sidebarInert: document.querySelector('#sourceSidebar').inert,
                frameMatches: Math.abs(lightboxBounds.left - queueBounds.left) < 1
                  && Math.abs(lightboxBounds.top - queueBounds.top) < 1
                  && Math.abs(lightboxBounds.right - queueBounds.right) < 1
                  && Math.abs(lightboxBounds.bottom - queueBounds.bottom) < 1,
                detailClear: lightboxBounds.right <= detailBounds.left + 1,
              };
            }"""
        )
        assert review_lightbox_layout == {
            "docked": True,
            "modal": "false",
            "appInert": False,
            "reviewInert": False,
            "queueInert": True,
            "titlebarInert": True,
            "sidebarInert": True,
            "frameMatches": True,
            "detailClear": True,
        }, review_lightbox_layout
        page.locator("#reviewTagSearch").focus()
        page.locator("#reviewTagSearch").fill("旅行")
        assert page.locator(
            f'#reviewTags [data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
        ).is_visible()
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        page.locator("#reviewTagSearch").press("Escape")
        assert page.locator("#reviewTagSearch").input_value() == ""
        assert page.evaluate("() => state.review.tagSearchText") == ""
        assert page.evaluate("() => document.activeElement?.id") == "reviewTagSearch"
        assert page.locator("#lightbox").is_visible()
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        page.locator("#lightboxZoomInButton").focus()
        zoom_controls = page.locator("#lightboxZoomControls")
        assert zoom_controls.is_visible()
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        assert page.locator("#commandContextLabel").inner_text() == "当前：全屏预览 · 建议审核队列"
        assert "关闭全屏预览" in page.locator(
            '[data-command-id="returnWorkspace"]'
        ).inner_text()
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.id === 'lightboxZoomInButton'"
        )
        lightbox_jobs_before = catalog_job_fetches[0]
        lightbox_previews_before = len(preview_requests)
        page.keyboard.press("j")
        page.locator("#jobsPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'review' "
            "&& history.state?.imageAllWorkspace?.navigationLevel === 'jobs' "
            "&& history.state?.imageAllWorkspace?.context?.jobsBaseLevel === 'lightbox'"
        )
        assert catalog_job_fetches[0] == lightbox_jobs_before + 1
        assert page.locator("#lightbox:not(.hidden)").is_visible()
        assert page.locator("#jobsPopover").evaluate(
            "element => Number(getComputedStyle(element).zIndex)"
        ) > page.locator("#lightbox").evaluate(
            "element => Number(getComputedStyle(element).zIndex)"
        )
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        page.screenshot(
            path="/tmp/imageall-lightbox-activity-shortcut.png",
            full_page=True,
        )
        page.keyboard.press("j")
        page.locator("#jobsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.navigationLevel === 'lightbox'"
        )
        page.wait_for_function(
            "() => document.activeElement?.id === 'lightboxZoomInButton'"
        )
        assert len(preview_requests) == lightbox_previews_before
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.locator("#lightboxZoomPercentage").inner_text() == "100%"
        assert page.locator("#lightboxZoomOutButton").is_disabled()
        page.locator("#lightboxZoomInButton").click()
        assert page.locator("#lightboxZoomPercentage").inner_text() == "125%"
        assert "scale(1.25)" in page.locator("#lightboxImage").get_attribute("style")
        page.locator("#lightboxStage").dispatch_event(
            "wheel", {"deltaY": -100, "deltaMode": 0}
        )
        page.wait_for_function("() => state.lightboxViewportScale > 1.25")
        page.locator("#lightboxZoomResetButton").click()
        assert page.locator("#lightboxZoomPercentage").inner_text() == "100%"
        page.locator("#lightboxStage").dblclick(position={"x": 100, "y": 100})
        assert page.locator("#lightboxZoomPercentage").inner_text() == "200%"
        page.wait_for_function(
            "() => document.querySelector('#lightboxImage').naturalWidth === 1200"
        )
        constrained = page.evaluate(
            "() => constrainedLightboxOffset(999, -999, 2, { "
            "viewportWidth: 100, viewportHeight: 100, fittedWidth: 100, fittedHeight: 75 })"
        )
        assert constrained == {"x": 50, "y": -25}, constrained
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_function(
            "() => !document.querySelector('#lightbox').classList.contains('review-docked')"
            " && document.querySelector('#lightbox').getAttribute('aria-modal') === 'true'"
            " && document.querySelector('#appView').inert"
            " && document.querySelector('#reviewWorkspace').inert"
        )
        zoom_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth, "
            "toolbarRight: document.querySelector('.lightbox-toolbar-actions')"
            ".getBoundingClientRect().right })"
        )
        assert zoom_dimensions["scroll"] <= zoom_dimensions["viewport"], zoom_dimensions
        assert zoom_dimensions["toolbarRight"] <= zoom_dimensions["viewport"], zoom_dimensions
        stage_box = page.locator("#lightboxStage").bounding_box()
        assert stage_box is not None
        drag_start_x = stage_box["x"] + stage_box["width"] / 2
        drag_start_y = stage_box["y"] + stage_box["height"] / 2
        page.mouse.move(drag_start_x, drag_start_y)
        page.mouse.down()
        page.mouse.move(drag_start_x + 90, drag_start_y, steps=6)
        page.mouse.up()
        dragged_viewport = page.evaluate(
            "() => ({ x: state.lightboxViewportOffsetX, "
            "y: state.lightboxViewportOffsetY, dragging: "
            "document.querySelector('#lightboxStage').classList.contains('dragging') })"
        )
        assert dragged_viewport["x"] > 70, dragged_viewport
        assert dragged_viewport["y"] == 0, dragged_viewport
        assert dragged_viewport["dragging"] is False, dragged_viewport
        lightbox_original = page.locator("#lightboxViewOriginalButton")
        assert lightbox_original.is_visible()
        assert lightbox_original.is_enabled()
        assert lightbox_original.get_attribute("aria-pressed") == "false"
        assert page.locator("#lightboxViewOriginalButtonLabel").inner_text() == "查看原图"
        assert page.locator("#lightboxOpenOriginalButton").is_hidden()
        lightbox_original.click()
        page.wait_for_function(
            f"() => document.querySelector('#lightboxImage').dataset.protectedPath "
            f"=== '/v1/assets/{REVIEW_IDS[0]}/original?r=1'"
        )
        assert lightbox_original.get_attribute("aria-pressed") == "true"
        assert page.locator("#lightboxViewOriginalButtonLabel").inner_text() == "标准预览"
        assert viewed_originals[-1] == REVIEW_IDS[0]
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        assert page.locator("#lightboxZoomPercentage").inner_text() == "200%"
        page.screenshot(path="/tmp/imageall-lightbox-zoom-390.png", full_page=True)
        page.keyboard.press("0")
        assert page.locator("#lightboxZoomPercentage").inner_text() == "100%"
        assert page.evaluate("() => state.lightboxViewportOffsetX") == 0
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_function(
            "() => document.querySelector('#lightbox').classList.contains('review-docked')"
            " && !document.querySelector('#appView').inert"
            " && !document.querySelector('#reviewWorkspace').inert"
            " && document.querySelector('#reviewQueuePane').inert"
        )
        page.locator("#lightboxNextButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_2.JPG')"
        )
        assert sum(prefetched_review_2_path in url for url in preview_requests) \
            == prefetched_review_2_request_count
        prefetched_review_3_path = f"/v1/assets/{REVIEW_IDS[2]}/preview?r=3"
        page.wait_for_function(
            "path => state.lightboxPreviewPrefetches.get(path)?.status === 'ready' "
            "&& state.lightboxPreviewPrefetches.size === 2",
            arg=prefetched_review_3_path,
        )
        assert page.evaluate(
            "() => [...state.lightboxPreviewPrefetches.keys()]"
            ".every(path => path.includes('/preview') && !path.includes('/original'))"
        )
        assert page.locator("#lightboxViewOriginalButton").get_attribute("aria-pressed") == "false"
        next_preview_path = page.locator("#lightboxImage").get_attribute("data-protected-path")
        assert f"/v1/assets/{REVIEW_IDS[1]}/preview" in next_preview_path
        assert "/original" not in next_preview_path
        assert page.locator("#lightboxZoomPercentage").inner_text() == "100%"
        original_failures.add(REVIEW_IDS[1])
        page.locator("#lightboxViewOriginalButton").click()
        page.wait_for_function(
            f"() => state.lightboxOriginalAssetID === null "
            f"&& document.querySelector('#lightboxImage').dataset.protectedPath"
            f"?.includes('/v1/assets/{REVIEW_IDS[1]}/preview')"
        )
        assert "合成原图当前不可用" in page.locator("#toast").inner_text()
        assert viewed_originals[-1] == REVIEW_IDS[1]
        assert page.evaluate("() => state.lightboxPreviewPrefetches.size <= 2")
        page.locator("#lightboxPreviousButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_1.JPG')"
        )
        page.wait_for_function(
            "() => !document.querySelector('#lightboxFavoriteButton').disabled"
        )
        assert page.locator("#lightboxFavoriteButton").is_visible()
        review_lightbox_delete = page.locator("#lightboxDeleteButton")
        assert review_lightbox_delete.is_visible()
        assert review_lightbox_delete.is_enabled()
        assert "REVIEW_1.JPG" in review_lightbox_delete.get_attribute("aria-label")
        page.locator("#lightboxFavoriteButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxFavoriteButton')?.dataset.favorite === 'true' "
            "&& document.querySelector('#lightboxDeleteButton').disabled"
        )
        assert favorite_mutations[-1]["assetIDs"] == [REVIEW_IDS[0]]
        assert favorite_mutations[-1]["isFavorite"] is True
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        page.screenshot(path="/tmp/imageall-review-lightbox-synthetic.png", full_page=True)

        review_delete_action = page.locator("#reviewInspectorDeleteButton")
        page.wait_for_function(
            "() => document.querySelector('#reviewInspectorDeleteButton').disabled"
        )
        assert "红心保护" in review_delete_action.get_attribute("title")
        assert "红心保护" in review_lightbox_delete.get_attribute("aria-label")
        assert "请先取消红心再删除" in page.locator(
            "#reviewInspectorActionStatus"
        ).inner_text()
        page.locator("#lightboxFavoriteButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxFavoriteButton')?.dataset.favorite === 'false' "
            "&& !document.querySelector('#reviewInspectorDeleteButton').disabled "
            "&& !document.querySelector('#lightboxDeleteButton').disabled"
        )
        assert favorite_mutations[-1]["assetIDs"] == [REVIEW_IDS[0]]
        assert favorite_mutations[-1]["isFavorite"] is False
        page.evaluate(
            """assetID => {
              globalThis.__reviewDeleteSchedulePagination = scheduleReviewAutoPagination;
              if (state.review.autoLoadFrame != null) {
                cancelAnimationFrame(state.review.autoLoadFrame);
                state.review.autoLoadFrame = null;
              }
              scheduleReviewAutoPagination = () => {};
              state.review.items = state.review.items.slice(0, 1);
              state.review.nextCursor = "review-page-2";
              state.review.selectedIndex = 0;
              state.review.selectedAssetIDs = new Set([assetID]);
              state.review.selectionAnchorIndex = 0;
              renderReview();
              renderLightbox();
            }""",
            REVIEW_IDS[0],
        )
        assert page.evaluate("() => state.review.items.length") == 1
        assert page.evaluate("() => state.review.nextCursor") == "review-page-2"
        page.keyboard.press("Delete")
        page.locator("#confirmDialog[open]").wait_for()
        page.keyboard.press("Escape")
        page.locator("#confirmDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'lightboxDeleteButton'"
        )
        review_lightbox_delete.click()
        page.locator("#confirmDialog[open]").wait_for()
        assert page.locator("#confirmDialog").get_attribute("data-tone") == "danger"
        review_delete_confirmation = page.locator("#confirmDialogMessage").inner_text()
        assert "文件夹来源会在身份核验后永久删除" in review_delete_confirmation
        assert "Apple Photos 项只会进入系统“最近删除”" in review_delete_confirmation
        assert not submitted_review_removals
        page.locator("#confirmActionButton").click()
        page.wait_for_function(
            "() => document.querySelector('#reviewInspectorActionStatus')"
            ".textContent.includes('等待 Mac')"
        )
        assert page.evaluate(
            "() => [...state.galleryRemoval.contexts.values()][0].reviewItemIDs"
        ) == [REVIEW_IDS[0]]
        assert len(submitted_review_removals) == 1
        review_removal_payload = submitted_review_removals[0]
        assert review_removal_payload["scope"] == "gallerySelection"
        assert review_removal_payload["jobID"] is None
        assert review_removal_payload["clusterID"] is None
        assert review_removal_payload["mode"] == "releaseSourceSpace"
        assert review_removal_payload["assetIDs"] == [REVIEW_IDS[0]]

        review_items[:] = review_items[1:]
        review_removal["request"].update({
            "phase": "completed",
            "progress": {
                "phase": "completedAsset",
                "completedAssetCount": 1,
                "totalAssetCount": 1,
                "copiedBytes": 0,
                "totalFileBytes": 0,
            },
            "audit": {
                "hiddenAssetIDs": [REVIEW_IDS[0]],
                "recycledEntryIDs": [],
                "permanentlyDeletedAssetIDs": [REVIEW_IDS[0]],
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
            "message": "已永久删除 1 张，来源空间已可回收",
            "updatedAtMs": 1_700_000_021_000,
        })
        page.wait_for_function(
            f"() => state.review.items.length === 2 "
            f"&& state.review.items[0].assetID === '{REVIEW_IDS[1]}' "
            f"&& state.review.selectedAssetIDs.size === 1 "
            f"&& state.review.selectedAssetIDs.has('{REVIEW_IDS[1]}') "
            f"&& state.lightboxAssetID === '{REVIEW_IDS[1]}' "
            "&& state.galleryRemoval.contexts.size === 0 "
            "&& document.querySelector('#lightboxTitle').textContent.includes('REVIEW_2.JPG') "
            "&& document.querySelector('#reviewFileName').textContent === 'REVIEW_2.JPG' "
            f"&& history.state?.imageAllWorkspace?.context?.reviewLightbox?.assetID === '{REVIEW_IDS[1]}'"
        )
        assert page.locator("#lightboxDeleteButton").is_visible()
        assert page.locator("#lightboxDeleteButton").is_enabled()
        page.evaluate(
            "() => { scheduleReviewAutoPagination = globalThis.__reviewDeleteSchedulePagination; }"
        )
        page.screenshot(path="/tmp/imageall-review-lightbox-delete.png", full_page=True)
        assert page.locator("#lightbox").get_attribute("aria-modal") == "false"
        assert page.locator("#reviewQueuePane").evaluate("element => element.inert")
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.evaluate("() => history.forward()")
        page.wait_for_function(
            f"() => !document.querySelector('#lightbox').classList.contains('hidden') "
            f"&& state.lightboxAssetID === '{REVIEW_IDS[1]}' "
            "&& document.querySelector('#lightboxTitle').textContent.includes('REVIEW_2.JPG')"
        )
        assert REVIEW_IDS[0] not in page.evaluate(
            "() => JSON.stringify(history.state.imageAllWorkspace.context)"
        )

        review_items.insert(1, {
            **review_items[0],
            "suggestionOrigin": "personalModel",
            "score": 0.84,
        })
        page.evaluate(
            """assetID => {
              if (state.review.autoLoadFrame != null) {
                cancelAnimationFrame(state.review.autoLoadFrame);
                state.review.autoLoadFrame = null;
              }
              scheduleReviewAutoPagination = () => {};
              state.review.items = state.review.items.slice(0, 1);
              state.review.nextCursor = "review-page-2";
              state.review.selectedIndex = 0;
              state.review.selectedAssetIDs = new Set([assetID]);
              state.review.selectionAnchorIndex = 0;
              renderReview();
              renderLightbox();
            }""",
            REVIEW_IDS[1],
        )
        defer_cursor_query_count = sum(
            query.get("cursor") == ["review-page-2"]
            for query in review_queue_queries
        )
        defer_decision_count = len(review_decisions)
        page.keyboard.press("u")
        page.wait_for_function(
            f"() => state.review.items.length === 3 "
            f"&& state.review.items[1].assetID === '{REVIEW_IDS[1]}' "
            "&& state.review.items[1].suggestionOrigin === 'personalModel' "
            f"&& state.review.selectedIndex === 1 "
            f"&& state.review.selectedAssetIDs.size === 1 "
            f"&& state.review.selectedAssetIDs.has('{REVIEW_IDS[1]}') "
            f"&& state.review.selectionAnchorIndex === 1 "
            f"&& state.lightboxAssetID === '{REVIEW_IDS[1]}' "
            f"&& state.lightboxReviewKey === '{REVIEW_IDS[1]}:personalModel' "
            "&& document.querySelector('#lightboxTitle').textContent.includes('REVIEW_2.JPG') "
            "&& document.querySelector('#lightboxPosition').textContent === '2 / 3' "
            "&& document.querySelector('#reviewFileName').textContent === 'REVIEW_2.JPG' "
            "&& document.querySelector('#reviewOrigin').textContent.includes('个性化模型建议') "
            f"&& history.state?.imageAllWorkspace?.context?.reviewItemKey === '{REVIEW_IDS[1]}:personalModel' "
            f"&& history.state?.imageAllWorkspace?.context?.reviewLightbox?.reviewKey === '{REVIEW_IDS[1]}:personalModel'"
        )
        assert sum(
            query.get("cursor") == ["review-page-2"]
            for query in review_queue_queries
        ) == defer_cursor_query_count + 1
        assert len(review_decisions) == defer_decision_count
        assert "没有修改标签决定" in page.locator("#toast").inner_text()
        assert page.locator(
            f'[data-review-key="{REVIEW_IDS[1]}:personalModel"] .review-card-main'
        ).get_attribute("aria-current") == "true"
        assert page.locator(
            f'[data-review-asset-id="{REVIEW_IDS[1]}"] .review-card-main[tabindex="0"]'
        ).count() == 1
        page.screenshot(path="/tmp/imageall-review-origin-row-defer.png", full_page=True)
        second_origin_key = f"{REVIEW_IDS[1]}:personalModel"
        second_origin_main = page.locator(
            f'[data-review-key="{second_origin_key}"] .review-card-main'
        )
        context_asset_query_count = len(asset_queries)
        context_decision_count = len(review_decisions)
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "reviewKey => document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        page.locator("#reviewOpenLightboxButton").click()
        page.wait_for_function(
            "reviewKey => state.lightboxReviewKey === reviewKey "
            "&& document.querySelector('#lightboxPosition').textContent === '2 / 3'",
            arg=second_origin_key,
        )
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "reviewKey => document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        page.locator("#reviewPreviewImage").dblclick()
        page.wait_for_function(
            "reviewKey => state.lightboxReviewKey === reviewKey "
            "&& document.querySelector('#lightboxPosition').textContent === '2 / 3'",
            arg=second_origin_key,
        )
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "reviewKey => document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        second_origin_main.focus()
        page.keyboard.press("Space")
        page.wait_for_function(
            "reviewKey => state.lightboxReviewKey === reviewKey "
            "&& document.querySelector('#lightboxPosition').textContent === '2 / 3'",
            arg=second_origin_key,
        )
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "reviewKey => document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        second_origin_main.focus()
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        page.locator('[data-command-id="previewSelection"]').click()
        page.wait_for_function(
            "reviewKey => state.lightboxReviewKey === reviewKey "
            "&& document.querySelector('#lightboxPosition').textContent === '2 / 3'",
            arg=second_origin_key,
        )
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "reviewKey => document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        assert len(asset_queries) == context_asset_query_count
        assert len(review_decisions) == context_decision_count
        second_origin_main.click(button="right")
        review_context_menu.wait_for()
        assert page.locator("#reviewContextMenuTitle").inner_text() == (
            "REVIEW_2.JPG · 个性化模型建议"
        )
        assert page.evaluate(
            "reviewKey => state.contextReviewKey === reviewKey "
            "&& state.contextMenuSession?.targetID === reviewKey",
            second_origin_key,
        )
        assert "个性化模型建议" in review_context_menu.get_attribute("aria-label")
        page.screenshot(
            path="/tmp/imageall-review-origin-context-menu.png",
            full_page=True,
        )
        page.evaluate("() => history.back()")
        review_context_menu.wait_for(state="hidden")
        page.wait_for_function(
            "reviewKey => document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        page.evaluate("() => history.forward()")
        review_context_menu.wait_for()
        assert page.evaluate(
            "reviewKey => state.contextReviewKey === reviewKey "
            "&& state.contextMenuSession?.targetID === reviewKey",
            second_origin_key,
        )
        page.keyboard.press("Escape")
        page.wait_for_function(
            "reviewKey => document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        second_origin_main.press("Shift+F10")
        review_context_menu.wait_for()
        assert page.evaluate(
            "reviewKey => state.contextReviewKey === reviewKey",
            second_origin_key,
        )
        with page.expect_response("**/v1/favorites"):
            review_context_favorite.click()
        page.wait_for_function(
            f"reviewKey => state.review.items.filter(item => item.assetID === '{REVIEW_IDS[1]}')"
            ".every(item => item.favorite?.isFavorite === true) "
            "&& document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        assert favorite_mutations[-1]["assetIDs"] == [REVIEW_IDS[1]]
        assert favorite_mutations[-1]["isFavorite"] is True
        second_origin_main.press("Shift+F10")
        review_context_menu.wait_for()
        assert review_context_favorite.inner_text() == "取消红心"
        with page.expect_response("**/v1/favorites"):
            review_context_favorite.click()
        page.wait_for_function(
            f"reviewKey => state.review.items.filter(item => item.assetID === '{REVIEW_IDS[1]}')"
            ".every(item => item.favorite?.isFavorite === false) "
            "&& document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        assert favorite_mutations[-1]["assetIDs"] == [REVIEW_IDS[1]]
        assert favorite_mutations[-1]["isFavorite"] is False
        second_origin_main.press("Shift+F10")
        review_context_menu.wait_for()
        review_context_preview.click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert page.evaluate(
            "reviewKey => state.lightboxReviewKey === reviewKey "
            "&& document.querySelector('#lightboxPosition').textContent === '2 / 3'",
            second_origin_key,
        )
        assert len(asset_queries) == context_asset_query_count
        assert len(review_decisions) == context_decision_count
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.wait_for_function(
            "reviewKey => document.activeElement?.closest('[data-review-key]')"
            "?.dataset.reviewKey === reviewKey",
            arg=second_origin_key,
        )
        page.evaluate("() => history.forward()")
        page.wait_for_function(
            f"() => !document.querySelector('#lightbox').classList.contains('hidden') "
            f"&& state.lightboxReviewKey === '{REVIEW_IDS[1]}:personalModel' "
            "&& document.querySelector('#lightboxPosition').textContent === '2 / 3' "
            "&& document.querySelector('#reviewOrigin').textContent.includes('个性化模型建议')"
        )
        page.keyboard.press("u")
        page.wait_for_function(
            f"() => state.review.selectedIndex === 2 "
            f"&& state.review.selectedAssetIDs.has('{REVIEW_IDS[2]}') "
            f"&& state.lightboxAssetID === '{REVIEW_IDS[2]}' "
            f"&& state.lightboxReviewKey === '{REVIEW_IDS[2]}:featurePrint' "
            "&& document.querySelector('#lightboxTitle').textContent.includes('REVIEW_3.JPG') "
            "&& document.querySelector('#lightboxPosition').textContent === '3 / 3'"
        )
        assert len(review_decisions) == defer_decision_count
        page.evaluate(
            "() => { scheduleReviewAutoPagination = globalThis.__reviewDeleteSchedulePagination; }"
        )
        page.locator("#lightboxPreviousButton").click()
        page.wait_for_function(
            f"() => state.lightboxReviewKey === '{REVIEW_IDS[1]}:personalModel' "
            "&& document.querySelector('#lightboxTitle').textContent.includes('REVIEW_2.JPG')"
        )

        accept_review_action = page.locator(
            '#lightboxReviewActions [data-action="accept"]'
        )
        page.wait_for_function(
            "() => !document.querySelector("
            "'#lightboxReviewActions [data-action=\"accept\"]'"
            ").disabled"
        )
        assert accept_review_action.is_enabled()
        with page.expect_response("**/v1/review/decisions/batch"):
            accept_review_action.click()
        page.wait_for_function("() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_3.JPG')")
        assert review_decisions[-1]["action"] == "accept"
        terminal_defer_decision_count = len(review_decisions)
        page.keyboard.press("u")
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_3.JPG') "
            "&& document.querySelector('#toast').textContent.includes('已到审核队列末尾')"
        )
        assert len(review_decisions) == terminal_defer_decision_count
        page.keyboard.press("x")
        page.locator("#lightbox").wait_for(state="hidden")
        assert page.evaluate("() => state.lightboxPreviewPrefetches.size") == 0
        assert page.evaluate("() => state.lightboxPreviewPrefetchTimer") is None
        assert review_decisions[-1]["action"] == "reject"
        page.wait_for_function(
            "() => state.review.items.length === 0 "
            "&& state.review.selectedAssetIDs.size === 0 "
            "&& document.querySelector('#reviewEmpty')?.offsetParent !== null"
        )
        assert page.locator("#reviewDetail").is_hidden()
        page.locator("#closeReviewButton").click()
        page.locator("#reviewWorkspace").wait_for(state="hidden")
        page.wait_for_function(f"() => state.assets.length === {len(IMAGE_IDS + IMAGE_PAGE_2_IDS)}")
        page.locator("#libraryScroll").evaluate("element => { element.scrollTop = 240; }")
        assert page.locator("#libraryScroll").evaluate("element => element.scrollTop") > 0

        media_session_snapshot_script = """() => ({
          mediaKind: state.mediaKind,
          assetIDs: state.assets.map(asset => asset.id),
          nextCursor: state.nextCursor,
          selectedSourceID: state.selectedSourceID,
          libraryScope: state.libraryScope,
          selectedAssetID: state.selectedAssetID,
          selectedDetailID: state.selectedDetail?.assetID || null,
          searchText: state.searchText,
          sort: state.sort,
          filters: structuredClone(state.filters),
          selectionMode: state.selectionMode,
          selectedAssetIDs: [...state.selectedAssetIDs].sort(),
          selectionAnchorID: state.selectionAnchorID,
          inspectorDismissed: state.inspectorDismissed,
          scrollTop: document.querySelector('#libraryScroll').scrollTop,
        })"""
        image_session_before_video = page.evaluate(media_session_snapshot_script)
        page.locator('[data-media-kind="video"]').click()
        video_card = page.locator(f'[data-asset-id="{VIDEO_ID}"]')
        video_card.wait_for()
        page.locator("#filterButton").click()
        assert page.locator(
            '#mediaTypeFilter [data-filter-media-kind="image"]:not(.hidden)'
        ).count() == 0
        assert page.locator(
            '#mediaTypeFilter [data-filter-media-kind="video"]:not(.hidden)'
        ).count() == 1
        assert page.locator('#mediaTypeFilter input[value="mp4mov"]').is_visible()
        page.locator("#closeFilterButton").click()
        page.locator("#filterPopover").wait_for(state="hidden")
        video_card_main = video_card.locator(":scope > .asset-card-main")
        assert video_card.locator(".asset-video-badge").inner_text() == "▶ 0:12"
        assert "视频" in video_card_main.get_attribute("aria-label")
        assert video_card_main.get_attribute("data-help-detail") is None
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
        page.evaluate(
            f"""() => {{
              const originalFetch = window.fetch.bind(window);
              window.__videoFavoriteRelease = null;
              window.fetch = (input, init) => {{
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/favorites") return originalFetch(input, init);
                return new Promise((resolve, reject) => {{
                  window.__videoFavoriteRelease = () => {{
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  }};
                }});
              }};
              const card = document.querySelector('[data-asset-id="{VIDEO_ID}"]');
              const badge = card.querySelector(":scope > .asset-video-badge");
              const icon = badge.querySelector('[data-asset-video-badge-part="icon"]');
              const duration = badge.querySelector(
                '[data-asset-video-badge-part="duration"]'
              );
              const frame = {{
                card,
                main: card.querySelector(":scope > .asset-card-main"),
                image: card.querySelector(":scope > .asset-card-main > img"),
                video: card.querySelector(":scope > .asset-hover-video"),
                badge,
                icon,
                iconText: icon.firstChild,
                duration,
                durationText: duration.firstChild,
                favorite: card.querySelector(":scope > .asset-card-favorite"),
                favoriteIcon: card.querySelector(
                  ":scope > .asset-card-favorite > .media-favorite-icon"
                ),
                favoriteSync: card.querySelector(
                  ":scope > .asset-card-favorite > .media-favorite-sync"
                ),
                scrollTop: document.querySelector("#libraryScroll").scrollTop,
                added: 0,
                removed: 0,
              }};
              frame.favoriteIconText = frame.favoriteIcon.firstChild;
              frame.favoriteSyncText = frame.favoriteSync.firstChild;
              frame.observer = new MutationObserver((records) => {{
                for (const record of records) {{
                  frame.added += record.addedNodes.length;
                  frame.removed += record.removedNodes.length;
                }}
              }});
              frame.observer.observe(badge, {{ childList: true, subtree: true }});
              frame.observer.observe(frame.favorite, {{ childList: true, subtree: true }});
              window.__videoBadgeContinuityFrame = frame;
            }}"""
        )
        video_favorite = video_card.locator(":scope > .asset-card-favorite")
        video_favorite.click()
        page.wait_for_function("() => Boolean(window.__videoFavoriteRelease)")
        page.evaluate(
            """() => {
              const frame = window.__videoBadgeContinuityFrame;
              frame.playbackTime = frame.video.currentTime;
              frame.favorite.focus({ preventScroll: true });
              const range = document.createRange();
              range.setStart(frame.durationText, 1);
              range.setEnd(frame.durationText, frame.durationText.data.length);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              window.__videoFavoriteRelease();
            }"""
        )
        page.wait_for_function(
            "id => state.assets.find(asset => asset.id === id)?.favorite?.isFavorite === true",
            arg=VIDEO_ID,
        )
        video_badge_continuity = page.evaluate(
            """() => {
              const frame = window.__videoBadgeContinuityFrame;
              const card = document.querySelector(
                `[data-asset-id="${frame.card.dataset.assetId}"]`
              );
              const badge = card.querySelector(":scope > .asset-video-badge");
              const icon = badge.querySelector('[data-asset-video-badge-part="icon"]');
              const duration = badge.querySelector(
                '[data-asset-video-badge-part="duration"]'
              );
              const selection = getSelection();
              frame.observer.disconnect();
              return {
                card: frame.card === card,
                main: frame.main === card.querySelector(":scope > .asset-card-main"),
                image: frame.image === frame.main.querySelector(":scope > img"),
                video: frame.video === card.querySelector(":scope > .asset-hover-video"),
                playing: !frame.video.paused && frame.video.currentTime >= frame.playbackTime,
                badge: frame.badge === badge,
                icon: frame.icon === icon,
                iconText: frame.iconText === icon.firstChild,
                duration: frame.duration === duration,
                durationText: frame.durationText === duration.firstChild,
                favorite: frame.favorite === card.querySelector(
                  ":scope > .asset-card-favorite"
                ),
                favoriteIcon: frame.favoriteIcon === frame.favorite.querySelector(
                  ":scope > .media-favorite-icon"
                ),
                favoriteIconText: frame.favoriteIconText === frame.favoriteIcon.firstChild,
                favoriteSync: frame.favoriteSync === frame.favorite.querySelector(
                  ":scope > .media-favorite-sync"
                ),
                favoriteSyncText: frame.favoriteSyncText === frame.favoriteSync.firstChild,
                updatedFavorite: frame.favorite.getAttribute("aria-pressed") === "true",
                updatedIcon: frame.favoriteIcon.textContent === "♥",
                text: badge.textContent === "▶ 0:12",
                selected: selection.anchorNode === frame.durationText
                  && selection.toString() === "0:12",
                hovered: card.matches(":hover"),
                focused: document.activeElement === frame.favorite,
                scroll: document.querySelector("#libraryScroll").scrollTop === frame.scrollTop,
                zeroChildMutations: frame.added === 0 && frame.removed === 0,
              };
            }"""
        )
        assert all(video_badge_continuity.values()), video_badge_continuity
        assert favorite_mutations[-1]["assetIDs"] == [VIDEO_ID]
        assert favorite_mutations[-1]["isFavorite"] is True
        page.wait_for_timeout(700)
        assert page.locator("#persistentHelp").get_attribute("class").find("hidden") >= 0
        assert video_card_main.get_attribute("aria-pressed") == "false"
        assert page.locator("#libraryScroll").evaluate("element => element.scrollTop") == initial_scroll_top
        page.screenshot(path="/tmp/imageall-video-hover-synthetic.png", full_page=True)
        page.locator("#searchInput").hover()
        hover_video.wait_for(state="detached")
        assert media_requests, media_requests

        video_card.dblclick()
        page.locator("#lightboxVideo:not(.hidden)").wait_for()
        assert page.evaluate("() => state.lightboxPreviewPrefetches.size") == 0
        assert page.evaluate("() => state.lightboxPreviewPrefetchTimer") is None
        assert f"/v1/assets/{VIDEO_ID}/media?r=1" in page.locator("#lightboxVideo").get_attribute("src")
        assert page.locator("#lightboxImage").is_hidden()
        assert page.locator("#lightboxZoomControls").is_hidden()
        page.locator("#lightboxVideo").focus()
        assert page.evaluate(
            """() => document.querySelector('#lightboxVideo').dispatchEvent(
              new KeyboardEvent('keydown', {
                key: ' ', code: 'Space', bubbles: true, cancelable: true,
              })
            )"""
        )
        assert page.evaluate(
            """() => document.querySelector('#lightboxVideo').dispatchEvent(
              new KeyboardEvent('keydown', {
                key: 'ArrowRight', code: 'ArrowRight', bubbles: true, cancelable: true,
              })
            )"""
        )
        assert page.locator("#lightbox:not(.hidden)").is_visible()
        assert page.evaluate("() => document.activeElement?.id") == "lightboxVideo"
        lightbox_mac_player = page.locator("#lightboxOpenOriginalButton")
        assert lightbox_mac_player.is_visible()
        assert lightbox_mac_player.is_enabled()
        assert lightbox_mac_player.get_attribute("aria-label") == (
            "在 Mac 上用系统播放器打开CLIP_0001.MP4"
        )
        page.set_viewport_size({"width": 390, "height": 844})
        lightbox_toolbar_bounds = page.locator(".lightbox-toolbar").bounding_box()
        assert lightbox_toolbar_bounds is not None
        assert lightbox_toolbar_bounds["x"] >= 0
        assert lightbox_toolbar_bounds["x"] + lightbox_toolbar_bounds["width"] <= 390
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        page.screenshot(path="/tmp/imageall-video-lightbox-mac-player-390.png", full_page=True)
        lightbox_mac_player.click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('系统播放器')"
        )
        assert opened_originals == [REVIEW_IDS[0], VIDEO_ID]
        assert page.locator("#lightbox:not(.hidden)").is_visible()
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#closeLightboxButton").click()

        with page.expect_response("**/v1/assets?**"):
            page.evaluate(
                """() => {
                  const input = document.querySelector('#searchInput');
                  input.value = 'CLIP';
                  input.dispatchEvent(new InputEvent('input', {
                    bubbles: true,
                    inputType: 'insertText',
                    data: 'CLIP',
                  }));
                  document.querySelector('#searchForm').requestSubmit();
                }"""
            )
        page.wait_for_function(
            "() => state.searchText === 'CLIP' "
            "&& !state.loadingAssets "
            "&& !state.assetLoadPromise "
            "&& !state.queuedAssetLoadOptions "
            "&& state.assetRenderedQuerySignature === assetQuerySignature()"
        )
        sort_button = page.locator("#sortButton")
        assert page.locator("#sortButtonLabel").text_content() == "文件名升序"
        assert sort_button.get_attribute("aria-label") == "排序：文件名升序"
        sort_button.click()
        page.locator("#sortPopover:not(.hidden)").wait_for()
        assert sort_button.get_attribute("aria-expanded") == "true"
        assert page.locator(
            '#sortPopover [data-sort="fileNameAscending"]'
        ).get_attribute("aria-checked") == "true"
        with page.expect_response(
            lambda response: (
                "/v1/assets?" in response.url
                and parse_qs(urlparse(response.url).query).get("sort") == ["oldest"]
                and parse_qs(urlparse(response.url).query).get("cursor") == ["video-page-2"]
            )
        ):
            page.locator('#sortPopover [data-sort="oldest"]').click()
        page.wait_for_function("() => state.sort === 'oldest' && !state.loadingAssets")
        assert page.locator("#sortButtonLabel").text_content() == "最早优先"
        assert sort_button.get_attribute("aria-label") == "排序：最早优先"
        assert sort_button.get_attribute("aria-expanded") == "false"
        page.wait_for_function("() => document.activeElement?.id === 'sortButton'")
        page.wait_for_function(
            f"() => !state.loadingAssets "
            "&& !state.assetLoadPromise "
            "&& !state.queuedAssetLoadOptions "
            "&& state.assetRenderedQuerySignature === assetQuerySignature() "
            f"&& state.assets.length === {1 + len(VIDEO_PAGE_2_IDS)}"
        )
        sort_button.click()
        page.locator('#sortPopover [data-sort="oldest"]').press("ArrowUp")
        page.wait_for_function(
            "() => document.activeElement?.dataset?.sort === 'newest'"
        )
        page.locator('#sortPopover [data-sort="newest"]').press("Escape")
        assert page.locator("#sortPopover").is_hidden()
        page.wait_for_function("() => document.activeElement?.id === 'sortButton'")
        # Every toolbar surface can also be opened indirectly (for example from a
        # task row or the compact command menu). Those entry points must enforce
        # the same one-popover-at-a-time rule as direct pointer clicks, otherwise
        # the Mac-style sort menu can remain layered underneath the new surface.
        sort_button.click()
        page.locator("#sortPopover:not(.hidden)").wait_for()
        personal_replacement_history_length = page.evaluate("() => history.length")
        toolbar_asset_load_calls = page.evaluate(
            """() => {
              const original = loadAssets;
              let calls = 0;
              loadAssets = (...args) => { calls += 1; return original(...args); };
              try { openJobsPopover({ refreshProjection: false }); return calls; }
              finally { loadAssets = original; }
            }"""
        )
        assert toolbar_asset_load_calls == 0
        page.locator("#jobsPopover:not(.hidden)").wait_for()
        assert page.locator("#sortPopover").is_hidden()
        assert sort_button.get_attribute("aria-expanded") == "false"
        assert page.evaluate("() => history.length") == personal_replacement_history_length
        page.evaluate("() => closeJobsPopover({ restoreFocus: false })")

        sort_button.click()
        page.locator("#sortPopover:not(.hidden)").wait_for()
        toolbar_asset_load_calls = page.evaluate(
            """() => {
              const original = loadAssets;
              let calls = 0;
              loadAssets = (...args) => { calls += 1; return original(...args); };
              try { togglePersonalModelPopover(); return calls; }
              finally { loadAssets = original; }
            }"""
        )
        assert toolbar_asset_load_calls == 0
        page.locator("#personalModelPopover:not(.hidden)").wait_for()
        assert page.locator("#sortPopover").is_hidden()
        assert sort_button.get_attribute("aria-expanded") == "false"
        page.wait_for_function(
            "() => !state.loadingAssets && !state.assetLoadPromise "
            "&& !state.queuedAssetLoadOptions && !state.nextCursor "
            "&& state.assetRenderedQuerySignature === assetQuerySignature()"
        )
        personal_history_queries = len(asset_queries)
        page.locator("#rebuildPersonalAdamWButton").focus()
        page.locator("#personalModelPopover").evaluate(
            "element => { element.style.maxHeight = '84px'; "
            "element.style.overflowY = 'auto'; element.scrollTop = 36; }"
        )
        personal_menu_scroll = page.locator("#personalModelPopover").evaluate(
            "element => element.scrollTop"
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "actionMenu"
        personal_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert '"actionMenuKind":"personalModel"' in personal_history_payload
        assert "rebuildPersonalAdamWButton" not in personal_history_payload
        assert "actionMenuFocusedSelector" not in personal_history_payload
        assert "actionMenuScrollTop" not in personal_history_payload
        page.evaluate("() => history.back()")
        page.locator("#personalModelPopover").wait_for(state="hidden")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "workspace"
        page.wait_for_function(
            "() => document.activeElement?.id === 'personalModelButton'"
        )
        assert len(asset_queries) == personal_history_queries
        page.evaluate("() => history.forward()")
        page.locator("#personalModelPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'rebuildPersonalAdamWButton'"
        )
        assert page.locator("#personalModelPopover").evaluate(
            "element => element.scrollTop"
        ) == personal_menu_scroll
        assert len(asset_queries) == personal_history_queries
        page.screenshot(
            path="/tmp/imageall-toolbar-popover-personal.png",
            full_page=True,
        )
        page.keyboard.press("Escape")
        page.locator("#personalModelPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise "
            "&& !state.loadingAssets && !state.assetLoadPromise "
            "&& !state.queuedAssetLoadOptions "
            "&& state.assetRenderedQuerySignature === assetQuerySignature()"
        )

        original_toolbar_mode = page.locator("#appView").get_attribute(
            "data-toolbar-display-mode"
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#appView").evaluate(
            "element => { element.dataset.toolbarDisplayMode = 'iconAndTitle'; }"
        )
        toolbar_mode_labels = [
            "#sortButtonLabel",
            "#filterButton .library-toolbar-label",
            "#selectionModeButton .library-toolbar-label",
            "#personalModelButton .library-toolbar-label",
            "#thumbnailAspectButton .thumbnail-aspect-label",
            "#gridDensityButtonLabel",
        ]
        for selector in toolbar_mode_labels:
            assert page.locator(selector).is_visible(), selector
        page.set_viewport_size({"width": 2200, "height": 960})
        titlebar_toolbar_labels = [
            "#sidebarVisibilityLabel",
            "#commandButtonLabel",
            "#undoTagButtonLabel",
            "#toolbarConnectFolderLabel",
            "#toolbarExportPortableDataLabel",
            "#storageStatusLabel",
            "#jobsButtonLabel",
            "#currentSourceRefreshLabel",
            "#inspectorVisibilityLabel",
        ]
        for selector in titlebar_toolbar_labels:
            assert page.locator(selector).is_visible(), selector
        native_titlebar_buttons = page.locator(
            "#storageButton, #jobsButton, #currentSourceRefreshButton"
        )
        assert native_titlebar_buttons.evaluate_all(
            "buttons => buttons.every(button => "
            "button.classList.contains('library-toolbar-mode-button'))"
        )
        assert page.locator("#storageStatusLabel").inner_text() == "预览缓存"
        assert page.locator("#jobsButtonLabel").inner_text() == "活动"
        assert page.locator("#currentSourceRefreshLabel").inner_text() in {
            "立即重扫",
            "立即同步",
        }
        page.wait_for_function(
            """() => {
              const sort = document.querySelector('#sortButton')?.getBoundingClientRect();
              const close = document.querySelector('#closeInspectorButton')?.getBoundingClientRect();
              return sort && close && (sort.right <= close.left || sort.left >= close.right
                || sort.bottom <= close.top || sort.top >= close.bottom);
            }"""
        )
        sort_button.click()
        page.screenshot(path="/tmp/imageall-sort-menu-desktop.png", full_page=True)
        page.locator('#sortPopover [data-sort="oldest"]').press("Escape")
        page.locator("#appView").evaluate(
            "element => { element.dataset.toolbarDisplayMode = 'iconOnly'; }"
        )
        for selector in toolbar_mode_labels + titlebar_toolbar_labels:
            assert page.locator(selector).is_hidden(), selector
        assert page.locator(
            "#sidebarVisibilityButton, #commandButton, #toolbarConnectFolderButton, "
            "#toolbarExportPortableDataButton, #storageButton, #jobsButton, "
            "#currentSourceRefreshButton, #inspectorVisibilityButton"
        ).evaluate_all(
            "buttons => buttons.every(button => [29, 30].includes("
            "Math.round(button.getBoundingClientRect().width)))"
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        compact_library_buttons = page.locator(
            "#sortButton, #filterButton, #selectionModeButton, #personalModelButton, "
            "#thumbnailAspectButton, #gridDensityButton"
        )
        assert compact_library_buttons.evaluate_all(
            "buttons => buttons.every(button => Math.round(button.getBoundingClientRect().width) === 29)"
        )
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        if page.locator("#inspector.open #closeInspectorButton").is_visible():
            page.locator("#closeInspectorButton").click()
        page.wait_for_function(
            "() => !document.querySelector('#inspector').classList.contains('open')"
        )
        sort_button.click()
        page.locator("#sortPopover:not(.hidden)").wait_for()
        toolbar_asset_load_calls = page.evaluate(
            """() => {
              const original = loadAssets;
              let calls = 0;
              loadAssets = (...args) => { calls += 1; return original(...args); };
              try { openCompactToolbarMenu(); return calls; }
              finally { loadAssets = original; }
            }"""
        )
        assert toolbar_asset_load_calls == 0
        page.locator("#compactToolbarMenu:not(.hidden)").wait_for()
        assert page.locator("#sortPopover").is_hidden()
        assert sort_button.get_attribute("aria-expanded") == "false"
        assert page.locator(
            '[data-compact-toolbar-target="toolbarConnectFolderButton"]'
        ).is_visible()
        assert page.locator(
            '[data-compact-toolbar-target="toolbarExportPortableDataButton"]'
        ).is_visible()
        assert page.locator(
            '[data-compact-toolbar-target="storageButton"]'
        ).is_visible()
        assert page.locator(
            '[data-compact-toolbar-target="currentSourceRefreshButton"]'
        ).is_visible()
        assert page.locator("#jobsButton").is_visible()
        page.evaluate("() => closeCompactToolbarMenu({ restoreFocus: false })")
        page.wait_for_timeout(350)
        page.wait_for_function(
            "() => !state.loadingAssets && !state.assetLoadPromise "
            "&& !state.queuedAssetLoadOptions && !state.nextCursor "
            "&& state.assetRenderedQuerySignature === assetQuerySignature()"
        )
        sort_button.click()
        page.locator("#sortPopover:not(.hidden)").wait_for()
        sort_history_queries = len(asset_queries)
        sort_history_state = page.evaluate(
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
        assert sort_history_state["route"] == "gallery"
        assert sort_history_state["navigationLevel"] == "layoutMenu"
        assert sort_history_state["baseLevel"] == "workspace"
        assert sort_history_state["kind"] == "sort"
        assert "layoutMenuFocusedValue" not in sort_history_state["serialized"]
        assert "layoutMenuReturnFocus" not in sort_history_state["serialized"]
        page.evaluate("() => history.back()")
        page.locator("#sortPopover").wait_for(state="hidden")
        page.wait_for_function("() => document.activeElement?.id === 'sortButton'")
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        assert len(asset_queries) == sort_history_queries, (
            asset_queries[sort_history_queries:]
        )
        page.evaluate("() => history.forward()")
        page.locator("#sortPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.sort === 'oldest'"
        )
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        assert len(asset_queries) == sort_history_queries, (
            asset_queries[sort_history_queries:]
        )
        sort_popover_bounds = page.locator("#sortPopover").bounding_box()
        assert sort_popover_bounds is not None
        assert sort_popover_bounds["x"] >= 8
        assert sort_popover_bounds["x"] + sort_popover_bounds["width"] <= 382
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        page.screenshot(path="/tmp/imageall-sort-menu-390.png", full_page=True)
        page.locator('#sortPopover [data-sort="oldest"]').press("Escape")
        page.locator("#sortPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        page.wait_for_timeout(350)
        page.wait_for_function(
            "() => !state.loadingAssets && !state.assetLoadPromise "
            "&& !state.queuedAssetLoadOptions "
            "&& state.assetRenderedQuerySignature === assetQuerySignature()"
        )
        gallery_density_history_queries = len(asset_queries)
        page.locator("#gridDensityButton").click()
        page.locator("#gridDensityPopover:not(.hidden)").wait_for()
        gallery_density_history = page.evaluate(
            """() => {
              const entry = history.state?.imageAllWorkspace;
              return {
                route: entry?.route,
                navigationLevel: entry?.navigationLevel,
                kind: entry?.context?.layoutMenuKind,
              };
            }"""
        )
        assert gallery_density_history == {
            "route": "gallery",
            "navigationLevel": "layoutMenu",
            "kind": "galleryGridDensity",
        }
        page.evaluate("() => history.back()")
        page.locator("#gridDensityPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'gridDensityButton'"
        )
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        assert len(asset_queries) == gallery_density_history_queries, (
            asset_queries[gallery_density_history_queries:]
        )
        page.evaluate("() => history.forward()")
        page.locator("#gridDensityPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.gridDensity === '5'"
        )
        page.wait_for_function(
            "() => !state.workspaceNavigation.applyingHistory "
            "&& !state.workspaceNavigation.pendingReturnPromise"
        )
        assert len(asset_queries) == gallery_density_history_queries, (
            asset_queries[gallery_density_history_queries:]
        )
        page.keyboard.press("Escape")
        page.locator("#gridDensityPopover").wait_for(state="hidden")
        assert page.evaluate("() => state.searchText === 'CLIP' && state.sort === 'oldest'")
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#appView").evaluate(
            "(element, mode) => { element.dataset.toolbarDisplayMode = mode; }",
            original_toolbar_mode,
        )

        # Storage maintenance must expose the same long-term retention policy
        # and analysis-time clear lock as Mac before the user reaches a native
        # approval. The disabled action must not emit a request.
        page.locator("#storageButton").click()
        page.locator("#storageDialog[open]").wait_for()
        page.wait_for_function("() => !state.storageMaintenance.loading")
        assert page.locator("#photosOriginalsPolicy").inner_text() == (
            "保留策略：默认长期保留，不自动过期或按容量淘汰；仅由你在这里手动清理。"
        )
        assert page.locator("#photosOriginalsBlocked").is_visible()
        assert page.locator("#photosOriginalsBlocked").inner_text() == (
            "相同检测运行期间不能清理；暂停或完成后可操作。"
        )
        assert page.locator("#clearPhotosOriginalsButton").is_disabled()
        page.locator("#clearPhotosOriginalsButton").click(force=True)
        page.wait_for_timeout(50)
        assert storage_requests == []
        page.screenshot(path="/tmp/imageall-storage-analysis-lock.png")
        page.set_viewport_size({"width": 390, "height": 844})
        storage_bounds = page.locator("#storageDialog").bounding_box()
        assert storage_bounds is not None
        assert storage_bounds["x"] >= 0
        assert storage_bounds["x"] + storage_bounds["width"] <= 390
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        page.screenshot(path="/tmp/imageall-storage-analysis-lock-390.png")
        page.set_viewport_size({"width": 1440, "height": 960})

        storage_snapshot["clearPhotosOriginalsAvailability"] = {
            "isAvailable": True,
            "reason": None,
        }
        page.wait_for_function(
            "() => !state.storageMaintenance.loading "
            "&& !document.querySelector('#clearPhotosOriginalsButton').disabled",
            timeout=2500,
        )
        assert page.locator("#photosOriginalsBlocked").is_hidden()
        page.locator("#storageCloseButton").click()
        page.locator("#storageDialog").wait_for(state="hidden")

        page.wait_for_function(
            f"() => state.assets.length === {1 + len(VIDEO_PAGE_2_IDS)}"
        )
        page.locator("#libraryScroll").evaluate("element => { element.scrollTop = 180; }")
        assert page.locator("#libraryScroll").evaluate("element => element.scrollTop") > 0
        video_card_main.click()
        page.wait_for_function(
            f"() => state.selectedDetail?.assetID === '{VIDEO_ID}'"
        )
        video_session_before_image = page.evaluate(media_session_snapshot_script)

        page.locator('[data-media-kind="image"]').click()
        page.wait_for_function("() => state.mediaKind === 'image' && !state.loadingAssets")
        assert page.evaluate(media_session_snapshot_script) == image_session_before_video
        page.locator('[data-media-kind="video"]').click()
        page.wait_for_function("() => state.mediaKind === 'video' && !state.loadingAssets")
        assert page.evaluate(media_session_snapshot_script) == video_session_before_image
        page.locator('[data-media-kind="image"]').click()
        page.wait_for_function("() => state.mediaKind === 'image' && !state.loadingAssets")
        assert page.evaluate(media_session_snapshot_script) == image_session_before_video
        page.locator(f'[data-quick-tag-id="{CAT_TAG_ID}"]').click()
        page.wait_for_function("() => !state.loadingAssets && !state.refreshingWorkspace")
        workspace_notice.update({
            "id": "notice-mobile-action",
            "severity": "warning",
            "message": "来源仍有待处理回收项目，删除没有在后台继续。",
            "actions": [{
                "id": "openRecycleBin",
                "kind": "openRecycleBin",
                "title": "前往回收站",
                "sourceID": SOURCE_ID,
            }],
        })
        page.evaluate(
            "notice => { state.workspaceNotice.notice = notice; renderWorkspaceNotice(); }",
            workspace_notice,
        )
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        if page.locator("#closeInspectorButton").is_visible():
            page.locator("#closeInspectorButton").click()
        page.locator("#toast").wait_for(state="hidden")
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        mobile_notice_debug = page.evaluate(
            """
            () => ({
              notice: state.workspaceNotice.notice,
              bannerClass: document.querySelector('#workspaceNoticeBanner').className,
              actions: document.querySelector('#workspaceNoticeActions').innerHTML,
            })
            """
        )
        assert page.locator(
            '[data-workspace-notice-action-id="openRecycleBin"]'
        ).is_visible(), mobile_notice_debug
        assert page.locator("#dismissWorkspaceNoticeButton").is_visible()
        assert page.locator("#activeFilterBar").is_visible()
        page.screenshot(path="/tmp/imageall-filter-review-lightbox-synthetic.png", full_page=True)

        page.set_viewport_size({"width": 2200, "height": 960})
        storage_request_count = len(storage_requests)
        page.locator("#toolbarExportPortableDataButton").click()
        page.locator("#storageDialog[open]").wait_for()
        page.wait_for_function(
            "() => state.storageMaintenance.snapshot?.requests?.some("
            "request => request.action === 'exportPortableData')"
        )
        assert len(storage_requests) == storage_request_count + 1
        assert storage_requests[-1]["action"] == "exportPortableData"
        page.locator("#storageCloseButton").click()
        page.wait_for_function(
            "() => document.activeElement?.id === 'storageButton'"
        )

        # Main-gallery refresh continuity is deliberately separate from restoring
        # top-level workspaces. Rebuild a realistic browsing context through the
        # same controls a user touches, then prove a normal refresh keeps the safe
        # context while discarding a potentially sensitive search string.
        page.set_viewport_size({"width": 900, "height": 600})
        page.evaluate("() => clearAllLibraryConditions()")
        page.wait_for_function("() => !state.loadingAssets && state.filters.tagConditions.length === 0")
        page.locator(f'button.sidebar-row[data-source-id="{SOURCE_ID}"]').click()
        page.wait_for_function(
            f"() => state.selectedSourceID === '{SOURCE_ID}' && !state.loadingAssets"
        )
        page.locator("#filterButton").click()
        page.locator('#availabilityFilter input[value="available"]').check()
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        page.locator("#applyFiltersButton").click()
        page.locator("#filterPopover").wait_for(state="hidden")
        page.locator("#sortButton").evaluate("button => button.click()")
        page.locator('#sortPopover [data-sort="oldest"]').click()
        page.wait_for_function(
            f"() => state.sort === 'oldest' && !state.loadingAssets "
            f"&& state.assets.length === {len(IMAGE_IDS + IMAGE_PAGE_2_IDS)}"
        )
        page.locator("#selectionModeButton").click()
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"] > .asset-card-main').click()
        page.locator(f'[data-asset-id="{IMAGE_IDS[1]}"] > .asset-card-main').click(
            modifiers=["Meta"]
        )
        page.locator("#libraryScroll").evaluate(
            "element => { element.scrollTop = Math.min(320, element.scrollHeight); }"
        )
        page.wait_for_function(
            "() => document.querySelector('#libraryScroll').scrollTop > 0"
        )
        page.wait_for_function(
            f"() => history.state?.imageAllWorkspace?.context?.gallerySourceID === '{SOURCE_ID}' "
            "&& history.state.imageAllWorkspace.context.gallerySort === 'oldest' "
            "&& history.state.imageAllWorkspace.context.galleryFilters.availabilities.includes('available') "
            "&& history.state.imageAllWorkspace.context.gallerySelectedAssetIDs.length === 2 "
            "&& history.state.imageAllWorkspace.context.galleryScrollTop > 0"
        )
        private_search = "PRIVATE /Users/example/secret/IMG_0042.JPG"
        page.evaluate(
            "value => { state.searchText = value; document.querySelector('#searchInput').value = value; "
            "checkpointActiveWorkspaceHistory(); }",
            private_search,
        )
        history_before_refresh = page.evaluate("() => JSON.stringify(history.state)")
        assert private_search not in history_before_refresh
        assert "CAT_0001.JPG" not in history_before_refresh

        page.reload(wait_until="networkidle")
        page.wait_for_function(
            f"() => !document.querySelector('#appView').classList.contains('hidden') "
            f"&& !state.loadingAssets && state.selectedSourceID === '{SOURCE_ID}' "
            f"&& state.assets.length === {len(IMAGE_IDS + IMAGE_PAGE_2_IDS)}"
        )
        page.wait_for_function(
            "() => document.querySelector('#libraryScroll').scrollTop > 0"
        )
        gallery_after_refresh = page.evaluate(
            """() => ({
              route: visibleWorkspaceRoute(),
              mediaKind: state.mediaKind,
              sourceID: state.selectedSourceID,
              scope: state.libraryScope,
              sort: state.sort,
              filters: structuredClone(state.filters),
              selectionMode: state.selectionMode,
              selectedAssetID: state.selectedAssetID,
              selectedAssetIDs: [...state.selectedAssetIDs].sort(),
              anchorID: state.selectionAnchorID,
              loadedCount: state.assets.length,
              scrollTop: document.querySelector('#libraryScroll').scrollTop,
              searchText: state.searchText,
              searchInput: document.querySelector('#searchInput').value,
              history: JSON.stringify(history.state),
            })"""
        )
        assert gallery_after_refresh["route"] == "gallery"
        assert gallery_after_refresh["mediaKind"] == "image"
        assert gallery_after_refresh["sourceID"] == SOURCE_ID
        assert gallery_after_refresh["scope"] == "all"
        assert gallery_after_refresh["sort"] == "oldest"
        assert gallery_after_refresh["filters"]["availabilities"] == ["available"]
        assert gallery_after_refresh["selectionMode"] is True
        assert gallery_after_refresh["selectedAssetID"] == IMAGE_IDS[1]
        assert gallery_after_refresh["selectedAssetIDs"] == sorted(IMAGE_IDS)
        assert gallery_after_refresh["anchorID"] == IMAGE_IDS[1]
        assert gallery_after_refresh["loadedCount"] == len(IMAGE_IDS + IMAGE_PAGE_2_IDS)
        assert gallery_after_refresh["scrollTop"] > 0
        assert gallery_after_refresh["searchText"] == ""
        assert gallery_after_refresh["searchInput"] == ""
        assert private_search not in gallery_after_refresh["history"]
        assert "CAT_0001.JPG" not in gallery_after_refresh["history"]

        # Deleting the loaded page tail in the main-gallery lightbox must keep
        # moving forward into the next keyset page, matching the Mac single-photo
        # flow instead of falling back to the old previous item. The replacement
        # also has to replace the lightbox history payload so Forward cannot
        # revive the now-hidden asset.
        page.set_viewport_size({"width": 1440, "height": 960})
        page.evaluate(
            """() => {
              setSelectionMode(false);
              globalThis.__galleryDeleteAutoPaginate = autoPaginateIfNeeded;
              autoPaginateIfNeeded = () => {};
              state.assets = state.assets.slice(0, 2);
              state.nextCursor = "image-page-2";
              renderAssets();
            }"""
        )
        page_tail_gallery_main = page.locator(
            f'[data-asset-id="{IMAGE_IDS[1]}"] > .asset-card-main'
        )
        page_tail_gallery_main.click()
        page.wait_for_function(
            f"() => state.selectedDetail?.assetID === '{IMAGE_IDS[1]}'"
        )
        page.locator("#openLightboxButton").click()
        page.locator("#lightbox:not(.hidden)").wait_for()
        assert "TRIP_0002.JPG" in page.locator("#lightboxTitle").inner_text()
        gallery_delete = page.locator("#lightboxDeleteButton")
        assert gallery_delete.is_enabled()
        gallery_delete.click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#confirmActionButton").click()
        page.wait_for_function(
            "() => state.galleryRemoval.contexts.size === 1 "
            "&& document.querySelector('#lightboxDeleteButton').disabled"
        )
        assert page.evaluate(
            "() => [...state.galleryRemoval.contexts.values()][0].assetIDs"
        ) == IMAGE_IDS
        assert submitted_review_removals[-1]["assetIDs"] == [IMAGE_IDS[1]]
        assert submitted_review_removals[-1]["scope"] == "gallerySelection"

        hidden_gallery_asset_ids.add(IMAGE_IDS[1])
        review_removal["request"].update({
            "phase": "completed",
            "progress": {
                "phase": "completedAsset",
                "completedAssetCount": 1,
                "totalAssetCount": 1,
                "copiedBytes": 0,
                "totalFileBytes": 0,
            },
            "audit": {
                "hiddenAssetIDs": [IMAGE_IDS[1]],
                "recycledEntryIDs": [],
                "permanentlyDeletedAssetIDs": [IMAGE_IDS[1]],
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
            "message": "已删除当前照片并继续浏览下一张",
            "updatedAtMs": 1_700_000_022_000,
        })
        page.wait_for_function(
            f"() => state.galleryRemoval.contexts.size === 0 "
            f"&& state.assets.every(asset => asset.id !== '{IMAGE_IDS[1]}') "
            f"&& state.lightboxAssetID === '{IMAGE_PAGE_2_IDS[0]}' "
            f"&& state.selectedAssetID === '{IMAGE_PAGE_2_IDS[0]}' "
            f"&& state.selectedDetail?.assetID === '{IMAGE_PAGE_2_IDS[0]}' "
            "&& document.querySelector('#lightboxTitle').textContent.includes('PHOTO_0003.JPG') "
            f"&& history.state?.imageAllWorkspace?.context?.galleryLightbox?.assetID === '{IMAGE_PAGE_2_IDS[0]}'",
            timeout=5_000,
        )
        assert page.locator("#lightboxPosition").inner_text().startswith("2 / ")
        assert page.evaluate("() => state.lightboxPreservesSelection") is False
        page.evaluate(
            "() => { autoPaginateIfNeeded = globalThis.__galleryDeleteAutoPaginate; }"
        )
        page.screenshot(
            path="/tmp/imageall-gallery-lightbox-delete-continuity.png",
            full_page=True,
        )
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.evaluate("() => history.forward()")
        page.wait_for_function(
            f"() => !document.querySelector('#lightbox').classList.contains('hidden') "
            f"&& state.lightboxAssetID === '{IMAGE_PAGE_2_IDS[0]}' "
            "&& document.querySelector('#lightboxTitle').textContent.includes('PHOTO_0003.JPG')"
        )
        assert IMAGE_IDS[1] not in page.evaluate(
            "() => JSON.stringify(history.state.imageAllWorkspace.context)"
        )

        # The same continuation must not collapse a deliberate multi-selection.
        # Make the previewed item the selection primary, remove it, and require
        # the surviving neighbor to become the repaired primary and anchor.
        page.locator("#lightboxBackButton").click()
        page.locator("#lightbox").wait_for(state="hidden")
        page.locator("#selectionModeButton").click()
        next_gallery_main = page.locator(
            f'[data-asset-id="{IMAGE_PAGE_2_IDS[1]}"] > .asset-card-main'
        )
        current_gallery_main = page.locator(
            f'[data-asset-id="{IMAGE_PAGE_2_IDS[0]}"] > .asset-card-main'
        )
        next_gallery_main.click()
        current_gallery_main.click(modifiers=["Meta"])
        page.wait_for_function(
            f"() => state.selectedAssetIDs.size === 2 "
            f"&& state.selectedAssetID === '{IMAGE_PAGE_2_IDS[0]}' "
            f"&& state.selectionAnchorID === '{IMAGE_PAGE_2_IDS[0]}'"
        )
        current_gallery_main.dblclick()
        page.wait_for_function(
            f"() => state.lightboxAssetID === '{IMAGE_PAGE_2_IDS[0]}' "
            "&& state.lightboxPreservesSelection "
            "&& state.selectedAssetIDs.size === 2"
        )
        page.locator("#lightboxDeleteButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#confirmActionButton").click()
        page.wait_for_function("() => state.galleryRemoval.contexts.size === 1")
        hidden_gallery_asset_ids.add(IMAGE_PAGE_2_IDS[0])
        review_removal["request"].update({
            "phase": "completed",
            "progress": {
                "phase": "completedAsset",
                "completedAssetCount": 1,
                "totalAssetCount": 1,
                "copiedBytes": 0,
                "totalFileBytes": 0,
            },
            "audit": {
                "hiddenAssetIDs": [IMAGE_PAGE_2_IDS[0]],
                "recycledEntryIDs": [],
                "permanentlyDeletedAssetIDs": [IMAGE_PAGE_2_IDS[0]],
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
            "message": "已删除多选预览并保留剩余选择",
            "updatedAtMs": 1_700_000_023_000,
        })
        page.wait_for_function(
            f"() => state.galleryRemoval.contexts.size === 0 "
            f"&& state.lightboxAssetID === '{IMAGE_PAGE_2_IDS[1]}' "
            "&& state.lightboxPreservesSelection "
            "&& state.selectedAssetIDs.size === 1 "
            f"&& state.selectedAssetIDs.has('{IMAGE_PAGE_2_IDS[1]}') "
            f"&& state.selectedAssetID === '{IMAGE_PAGE_2_IDS[1]}' "
            f"&& state.selectionAnchorID === '{IMAGE_PAGE_2_IDS[1]}' "
            "&& document.querySelector('#lightboxTitle').textContent.includes('PHOTO_0004.JPG')"
        )
        assert page.locator("#lightboxDeleteButton").is_enabled()

        assert not page_errors, page_errors
        unexpected_console_errors = [
            message for message in console_errors
            if "status of 409" not in message
            and "status of 500" not in message
            and "status of 503" not in message
        ]
        unexpected_http_errors = [
            response for response in http_errors
            if response["status"] not in {409, 500, 503}
        ]
        assert not unexpected_console_errors, {
            "console": unexpected_console_errors,
            "http": unexpected_http_errors,
        }
        assert not unexpected_http_errors, unexpected_http_errors
        browser.close()

    print(
        "filter/review/lightbox browser flow passed; "
        f"asset queries={len(asset_queries)}; tag decisions={len(tag_decisions)}; "
        f"review decisions={len(review_decisions)}; source actions={len(source_actions)}; "
        f"media requests={len(media_requests)}; favorites={len(favorite_mutations)}; "
        f"storage requests={len(storage_requests)}"
    )


if __name__ == "__main__":
    main()
