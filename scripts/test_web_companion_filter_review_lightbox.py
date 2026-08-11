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
        REVIEW_IDS[2]: (1600, 900),
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
    review_decisions = []
    review_queue_queries = []
    source_actions = []
    source_requests = []
    media_requests = []
    opened_originals = []
    favorite_mutations = []
    thumbnail_queries = []
    workspace_notice_actions = []
    recycle_queries = []
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
                    "capabilities": ["sourceManagement", "favorites", "workspaceNotices"],
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
        page.route(
            "**/v1/workspace-notice",
            lambda route: fulfill_json(route, {"notice": workspace_notice or None}),
        )

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
            if payload["action"] == "refreshAll":
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
            fulfill_json(route, {"items": items, "nextCursor": next_cursor})

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
        def route_review_queue(route):
            query = parse_qs(urlparse(route.request.url).query)
            review_queue_queries.append(query)
            items = projected_review_items()
            if query.get("cursor") == ["review-page-2"]:
                fulfill_json(route, {"items": items[2:], "nextCursor": None})
            elif len(items) > 2:
                fulfill_json(
                    route,
                    {"items": items[:2], "nextCursor": "review-page-2"},
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
        page.locator('[data-workspace-notice-action-id="openRecycleBin"]').click()
        page.wait_for_function(
            "() => state.workspaceNotice.notice?.id === 'notice-source-recycle-new'"
        )
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
        assert page.locator("#slimmingRecycleSourceSelect").input_value() == SOURCE_ID
        page.locator("#closeSlimmingButton").click()
        page.locator("#slimmingWorkspace.hidden").wait_for(state="attached")

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
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#applyFiltersButton").click()
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
        page.locator("#tagMatchMode").focus()
        page.locator("#tagMatchMode").select_option("any")
        page.wait_for_function(
            "() => document.querySelector('#filterLiveStatus').dataset.state === 'ready'"
        )
        assert page.locator("#filterPopover").is_visible()
        assert page.evaluate("() => document.activeElement?.id") == "tagMatchMode"
        assert any(query.get("tagMatchMode") == ["any"] for query in asset_queries)
        page.locator("#applyFiltersButton").click()
        page.locator("#activeFilterRelation:not(.hidden)").wait_for()
        assert "旅行 已拒绝" in page.locator("#activeFilterSummary").inner_text()
        page.wait_for_function(
            "() => document.querySelector('[data-active-filter-match=\"any\"]').getAttribute('aria-pressed') === 'true'"
        )
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
        assert page.locator("#emptyClearAllConditionsButton").is_visible()
        page.locator("#emptyClearAllConditionsButton").click()
        page.locator(f'[data-asset-id="{IMAGE_IDS[0]}"]').wait_for()
        page.wait_for_function("() => document.activeElement?.id === 'filterButton'")
        assert "q" not in asset_queries[-1]
        assert "availabilities" not in asset_queries[-1]

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
        page.locator("#searchInput").focus()
        page.keyboard.press("Tab")
        first_asset_main.focus()
        persistent_help.wait_for(timeout=1_000)
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
        page.keyboard.press("Shift+F10")
        asset_context_menu = page.locator("#assetContextMenu:not(.hidden)")
        asset_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.contextAction === 'preview'"
        )
        assert asset_context_menu.get_attribute("aria-label") == "CAT_0001.JPG 项目操作"
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.contextAction"
        ) == "filterSource"
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

        page.keyboard.press("ContextMenu")
        asset_context_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.contextAction === 'preview'"
        )
        page.keyboard.press("End")
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
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.querySelector('.asset-card.batch-selected') === null"
        )

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
        page.set_viewport_size({"width": 1440, "height": 960})
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
        page.locator("#reviewOverview:not(.hidden)").wait_for()
        review_cat_card = page.locator(f'[data-review-overview-tag-id="{CAT_TAG_ID}"]')
        review_cat_card.wait_for()
        page.wait_for_function(
            "() => !state.review.overviewLoading "
            "&& !state.librarySuggestions.loading "
            "&& !state.sampleSuggestions.loading "
            "&& !state.generalSettings.loading"
        )
        review_cat_card.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for()
        assert page.locator("#persistentHelp").get_attribute("data-kind") == "review"
        assert page.locator("#persistentHelpTitle").inner_text() == "审核“猫”"
        review_help_detail = page.locator("#persistentHelpDetail").inner_text()
        assert "P 属于、X 不属于、U 稍后" in review_help_detail
        review_help_bounds = page.locator("#persistentHelp").bounding_box()
        assert review_help_bounds is not None
        assert review_help_bounds["x"] >= 8 and review_help_bounds["y"] >= 8
        assert review_help_bounds["x"] + review_help_bounds["width"] <= 1432
        assert page.locator("#persistentHelp").is_visible()
        page.screenshot(path="/tmp/imageall-review-persistent-help.png", full_page=True)
        page.mouse.move(4, 4)
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
        assert review_handle.is_hidden()
        assert page.evaluate("() => document.documentElement.scrollWidth <= 390")
        review_group_toggle = page.locator("[data-review-overview-group-toggle]").first
        review_group_toggle.focus()
        page.keyboard.press("Tab")
        assert page.evaluate(
            "() => document.activeElement?.dataset?.reviewOverviewTagId"
        ) == CAT_TAG_ID
        page.locator("#persistentHelp:not(.hidden)").wait_for()
        assert page.locator("#persistentHelp").get_attribute("data-kind") == "review"
        narrow_review_help_bounds = page.locator("#persistentHelp").bounding_box()
        assert narrow_review_help_bounds is not None
        assert narrow_review_help_bounds["x"] >= 8
        assert narrow_review_help_bounds["x"] + narrow_review_help_bounds["width"] <= 382
        assert narrow_review_help_bounds["y"] >= 8
        page.wait_for_timeout(180)
        page.screenshot(path="/tmp/imageall-review-persistent-help-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})
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
        assert any(query.get("cursor") == ["review-page-2"] for query in review_queue_queries)
        first_review_card = page.locator(f'[data-review-index="0"]')
        first_review_main = first_review_card.locator(":scope > .review-card-main")
        first_review_favorite = first_review_card.locator(":scope > .review-card-favorite")
        assert first_review_main.get_attribute("aria-pressed") == "true"
        first_review_main.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for()
        assert page.locator("#persistentHelp").get_attribute("data-kind") == "review"
        queue_help_detail = page.locator("#persistentHelpDetail").inner_text()
        assert "当前主项目并已选择" in queue_help_detail
        assert "Command/Ctrl-A 全选已载入项目" in queue_help_detail
        assert "P X U" in first_review_main.get_attribute("aria-keyshortcuts")
        page.mouse.move(4, 4)
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
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.classList.contains('review-card-main')"
        )
        page.keyboard.press("ArrowRight")
        assert page.evaluate("() => state.review.selectedIndex") == 1
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 1
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
        page.locator("#reviewGridDensitySlider").fill("8")
        assert page.locator("#gridDensitySlider").input_value() == "8"
        assert page.locator("#slimmingGridDensitySlider").input_value() == "8"
        assert page.evaluate(
            "() => getComputedStyle(document.documentElement)"
            ".getPropertyValue('--asset-min-width').trim()"
        ) == "268px"
        page.locator("#reviewThumbnailAspectButton").click()
        page.wait_for_function(
            "() => [...document.querySelectorAll('#reviewGrid .review-card img')]"
            ".every(image => image.naturalWidth > 1 && image.naturalHeight > 1)"
        )
        assert page.evaluate(
            "() => [...document.querySelectorAll('#reviewGrid .review-card img')]"
            ".map(image => [image.naturalWidth, image.naturalHeight])"
        ) == [[1200, 900], [900, 1200], [1600, 900]]
        assert page.locator("#reviewGrid").get_attribute("class").find("original-aspect") >= 0
        assert page.locator("#assetGrid").get_attribute("class").find("original-aspect") >= 0
        assert page.locator("#thumbnailAspectButton").get_attribute("aria-pressed") == "true"
        assert page.locator("#slimmingThumbnailAspectButton").get_attribute("aria-pressed") == "true"
        assert page.locator("#reviewThumbnailAspectButton").get_attribute("aria-pressed") == "true"
        first_box = first_review_card.bounding_box()
        second_box = page.locator('[data-review-index="1"]').bounding_box()
        assert first_box is not None and second_box is not None
        assert abs(first_box["width"] / first_box["height"] - 4 / 3) < 0.08, first_box
        assert abs(second_box["width"] / second_box["height"] - 3 / 4) < 0.08, second_box
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
        assert stored_layout["density"] == 8
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
        with page.expect_response("**/v1/favorites"):
            page.locator('[data-command-id="favoriteSelection"]').click()
        page.wait_for_function(
            "() => state.review.items.every(item => item.favorite?.isFavorite === true)"
        )
        assert set(favorite_mutations[-1]["assetIDs"]) == set(REVIEW_IDS)
        assert favorite_mutations[-1]["isFavorite"] is True
        page.keyboard.press("Meta+K")
        with page.expect_response("**/v1/favorites"):
            page.locator('[data-command-id="unfavoriteSelection"]').click()
        page.wait_for_function(
            "() => state.review.items.every(item => item.favorite?.isFavorite === false)"
        )
        assert favorite_mutations[-1]["isFavorite"] is False
        first_review_main.click()
        page.wait_for_function("() => state.review.selectedAssetIDs.size === 1")
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

        page.set_viewport_size({"width": 390, "height": 844})
        assert first_review_favorite.is_visible()
        review_selection_mode = page.locator("#reviewSelectionModeButton")
        review_select_all = page.locator("#reviewSelectAllButton")
        assert review_selection_mode.is_visible()
        review_selection_mode.click()
        assert review_selection_mode.get_attribute("aria-pressed") == "true"
        assert review_selection_mode.inner_text() == "完成"
        assert review_select_all.is_visible()
        page.locator('[data-review-index="1"] > .review-card-main').click()
        page.locator('[data-review-index="2"] > .review-card-main').click()
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 3
        assert review_select_all.is_disabled()
        page.locator('[data-review-index="1"] > .review-card-main').click()
        page.wait_for_function("() => state.review.selectedAssetIDs.size === 2")
        assert review_select_all.is_enabled()
        review_select_all.click()
        assert page.evaluate("() => state.review.selectedAssetIDs.size") == 3
        page.screenshot(
            path="/tmp/imageall-review-touch-selection-active-390.png",
            full_page=True,
        )
        page.locator('[data-review-index="1"] > .review-card-main').dispatch_event("dblclick")
        assert page.locator("#lightbox").is_hidden()
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
            "'reviewThumbnailAspectButton', 'reviewSelectionModeButton', 'refreshReviewButton'"
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
        page.screenshot(path="/tmp/imageall-review-card-favorite-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})

        page.locator("#reviewOpenLightboxButton").click()
        page.locator("#lightboxReviewActions:not(.hidden)").wait_for()
        assert "REVIEW_1.JPG" in page.locator("#lightboxTitle").inner_text()
        zoom_controls = page.locator("#lightboxZoomControls")
        assert zoom_controls.is_visible()
        page.locator("#lightboxZoomInButton").focus()
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
        page.screenshot(path="/tmp/imageall-lightbox-zoom-390.png", full_page=True)
        page.keyboard.press("0")
        assert page.locator("#lightboxZoomPercentage").inner_text() == "100%"
        assert page.evaluate("() => state.lightboxViewportOffsetX") == 0
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#lightboxNextButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_2.JPG')"
        )
        assert page.locator("#lightboxZoomPercentage").inner_text() == "100%"
        page.locator("#lightboxPreviousButton").click()
        page.wait_for_function(
            "() => document.querySelector('#lightboxTitle').textContent.includes('REVIEW_1.JPG')"
        )
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
        accept_review_action = page.locator(
            '#lightboxReviewActions [data-action="accept"]'
        )
        assert accept_review_action.is_enabled()
        with page.expect_response("**/v1/review/decisions/batch"):
            accept_review_action.click()
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
        assert f"/v1/assets/{VIDEO_ID}/media?r=1" in page.locator("#lightboxVideo").get_attribute("src")
        assert page.locator("#lightboxImage").is_hidden()
        assert page.locator("#lightboxZoomControls").is_hidden()
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
        assert opened_originals == [VIDEO_ID]
        assert page.locator("#lightbox:not(.hidden)").is_visible()
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator("#closeLightboxButton").click()

        page.locator("#searchInput").fill("CLIP")
        page.locator("#searchInput").press("Enter")
        page.wait_for_function("() => state.searchText === 'CLIP' && !state.loadingAssets")
        page.locator("#sortSelect").select_option("oldest")
        page.wait_for_function("() => state.sort === 'oldest' && !state.loadingAssets")
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

        assert not page_errors, page_errors
        unexpected_console_errors = [
            message for message in console_errors
            if "status of 409" not in message and "status of 500" not in message
        ]
        unexpected_http_errors = [
            response for response in http_errors
            if response["status"] not in {409, 500}
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
        f"media requests={len(media_requests)}; favorites={len(favorite_mutations)}"
    )


if __name__ == "__main__":
    main()
