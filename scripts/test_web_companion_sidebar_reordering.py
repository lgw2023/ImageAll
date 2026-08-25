#!/usr/bin/env python3
import base64
import json
import re
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8808"
SOURCE_PHOTOS = "10000000-0000-4000-8000-000000000001"
SOURCE_FOLDER = "10000000-0000-4000-8000-000000000002"
GROUP_SUBJECT = "20000000-0000-4000-8000-000000000001"
GROUP_SCENE = "20000000-0000-4000-8000-000000000002"
TAG_CAT = "30000000-0000-4000-8000-000000000001"
TAG_DOG = "30000000-0000-4000-8000-000000000002"
TAG_TRAVEL = "30000000-0000-4000-8000-000000000003"
ASSET_ID = "40000000-0000-4000-8000-000000000001"
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
    tags = [
        {"id": TAG_CAT, "displayName": "猫", "state": "active", "groupID": GROUP_SUBJECT},
        {"id": TAG_DOG, "displayName": "狗", "state": "active", "groupID": GROUP_SUBJECT},
        {"id": TAG_TRAVEL, "displayName": "旅行", "state": "active", "groupID": GROUP_SCENE},
    ]
    groups = [
        {
            "id": GROUP_SUBJECT,
            "displayName": "主体",
            "sortOrder": 0,
            "isSystem": False,
        },
        {
            "id": GROUP_SCENE,
            "displayName": "场景",
            "sortOrder": 1,
            "isSystem": True,
        },
    ]
    tag_moves = []
    tag_renames = []
    archived_tag_ids = []
    group_renames = []
    asset_queries = []
    folder_queries = []
    folder_retry_attempts = [0]
    folder_search_retry_attempts = [0]
    folder_pagination_attempts = [0]
    fail_next_move = [False]
    page_errors = []
    console_errors = []
    unsupported_requests = []
    unexpected_tag_decisions = []
    test_phase = ["setup"]

    def source_names(page):
        return page.locator("#sourceList [data-source-id] > span:nth-child(2)").all_inner_texts()

    def sidebar_group_names(page, group_id):
        return page.locator(
            f'#tagNavigation [data-tag-drop-group-id="{group_id}"] [data-quick-tag-id]'
        ).all_inner_texts()

    def inspector_group_names(page, container, group_id):
        return page.locator(
            f'#{container} [data-inspector-tag-group-id="{group_id}"] '
            ".inspector-tag-chip strong"
        ).all_inner_texts()

    def sidebar_group_toggle(page, group_id):
        return page.locator(
            f'#tagNavigation [data-sidebar-tag-group-toggle="{group_id}"]'
        )

    def inspector_group_toggle(page, container, group_id):
        return page.locator(
            f'#{container} [data-inspector-tag-group-toggle="{group_id}"]'
        )

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
            lambda response: unsupported_requests.append(
                f"{response.request.method} {response.url}"
            ) if response.status == 501 else None,
        )
        page.on(
            "request",
            lambda request: unexpected_tag_decisions.append(
                {
                    "phase": test_phase[0],
                    "payload": request.post_data_json,
                }
            ) if request.url.endswith("/v1/tag-decisions/batch") else None,
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
                {"authenticated": True, "authMode": "account", "username": "test"},
            ),
        )
        page.route(
            "**/v1/capabilities",
            lambda route: fulfill_json(
                route,
                {
                    "protocolVersion": 1,
                    "hostID": "50000000-0000-4000-8000-000000000001",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                    "capabilities": ["folderHierarchy"],
                },
            ),
        )
        page.route(
            "**/v1/sources",
            lambda route: fulfill_json(route, [
                {
                    "id": SOURCE_PHOTOS,
                    "kind": "photos",
                    "displayName": "Apple Photos",
                    "state": "active",
                },
                {
                    "id": SOURCE_FOLDER,
                    "kind": "folder",
                    "displayName": "Downloads",
                    "state": "active",
                },
            ]),
        )
        page.route("**/v1/tags", lambda route: fulfill_json(route, list(tags)))
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(route, list(groups)),
        )
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))

        def source_folders(route):
            parsed = urlparse(route.request.url)
            query = parse_qs(parsed.query)
            folder_queries.append(query)
            search = query.get("q", [""])[0]
            parent = query.get("parentRelativePath", [None])[0]
            offset = int(query.get("offset", ["0"])[0])
            if search:
                if search == "retry-query":
                    folder_search_retry_attempts[0] += 1
                    if folder_search_retry_attempts[0] <= 2:
                        fulfill_json(route, {
                            "code": "temporarilyUnavailable",
                            "message": "测试目录搜索暂时失败",
                        }, status=503)
                        return
                    fulfill_json(route, {
                        "folders": [{
                            "sourceID": SOURCE_FOLDER,
                            "relativePath": "Retry Search/Recovered",
                            "parentRelativePath": "Retry Search",
                            "name": "Recovered",
                        }],
                        "totalCount": 1,
                        "nextOffset": None,
                    })
                    return
                search_result_paths = {
                    "%_": ("Literal %_/Match", "Literal %_"),
                    "button-query": ("Button Search/Match", "Button Search"),
                    "enter-query": ("Enter Search/Match", "Enter Search"),
                }
                result_path = search_result_paths.get(search)
                folders = [{
                    "sourceID": SOURCE_FOLDER,
                    "relativePath": result_path[0],
                    "parentRelativePath": result_path[1],
                    "name": "Match",
                }] if result_path else []
                fulfill_json(route, {
                    "folders": folders,
                    "totalCount": len(folders),
                    "nextOffset": None,
                })
                return
            if parent == "Retry":
                folder_retry_attempts[0] += 1
                if folder_retry_attempts[0] <= 2:
                    fulfill_json(route, {
                        "code": "temporarilyUnavailable",
                        "message": "测试目录暂时无法读取",
                    }, status=503)
                    return
                fulfill_json(route, {
                    "folders": [{
                        "sourceID": SOURCE_FOLDER,
                        "relativePath": "Retry/Recovered",
                        "parentRelativePath": "Retry",
                        "name": "Recovered",
                    }],
                    "totalCount": 1,
                    "nextOffset": None,
                })
                return
            if parent == "Trips":
                fulfill_json(route, {
                    "folders": [{
                        "sourceID": SOURCE_FOLDER,
                        "relativePath": "Trips/2026",
                        "parentRelativePath": "Trips",
                        "name": "2026",
                    }],
                    "totalCount": 1,
                    "nextOffset": None,
                })
                return
            if parent == "Literal %_":
                fulfill_json(route, {
                    "folders": [{
                        "sourceID": SOURCE_FOLDER,
                        "relativePath": "Literal %_/Match",
                        "parentRelativePath": "Literal %_",
                        "name": "Match",
                    }],
                    "totalCount": 1,
                    "nextOffset": None,
                })
                return
            if offset >= 200:
                fulfill_json(route, {
                    "folders": [{
                        "sourceID": SOURCE_FOLDER,
                        "relativePath": "Vault",
                        "parentRelativePath": None,
                        "name": "Vault",
                    }],
                    "totalCount": 501,
                    "nextOffset": None,
                })
                return
            if offset >= 100:
                folder_pagination_attempts[0] += 1
                if folder_pagination_attempts[0] == 1:
                    fulfill_json(route, {
                        "code": "temporarilyUnavailable",
                        "message": "测试目录续页暂时失败",
                    }, status=503)
                    return
                fulfill_json(route, {
                    "folders": [{
                        "sourceID": SOURCE_FOLDER,
                        "relativePath": "Archive",
                        "parentRelativePath": None,
                        "name": "Archive",
                    }],
                    "totalCount": 501,
                    "nextOffset": 200,
                })
                return
            fulfill_json(route, {
                "folders": [
                    {
                        "sourceID": SOURCE_FOLDER,
                        "relativePath": "Trips",
                        "parentRelativePath": None,
                        "name": "Trips",
                    },
                    {
                        "sourceID": SOURCE_FOLDER,
                        "relativePath": "Literal %_",
                        "parentRelativePath": None,
                        "name": "Literal %_",
                    },
                    {
                        "sourceID": SOURCE_FOLDER,
                        "relativePath": "Retry",
                        "parentRelativePath": None,
                        "name": "Retry",
                    },
                ],
                "totalCount": 501,
                "nextOffset": 100,
            })

        page.route("**/v1/source-folders?**", source_folders)

        def asset_page(route):
            asset_queries.append(route.request.url)
            query = parse_qs(urlparse(route.request.url).query)
            folder_path = query.get("folderRelativePath", [None])[0]
            fulfill_json(route, {
                "items": [{
                    "id": ASSET_ID,
                    "fileName": "FOLDER.JPG" if folder_path else "SYNTHETIC.JPG",
                    "sourceID": SOURCE_FOLDER if folder_path else SOURCE_PHOTOS,
                    "sourceDisplayName": "Downloads" if folder_path else "Apple Photos",
                    "relativePath": f"{folder_path}/FOLDER.JPG" if folder_path else None,
                    "availability": "available",
                    "contentRevision": 1,
                    "acceptedTagCount": 1,
                    "rejectedTagCount": 0,
                }],
                "nextCursor": None,
            })

        page.route("**/v1/assets?**", asset_page)

        def asset_detail(route):
            fulfill_json(route, {
                "assetID": ASSET_ID,
                "sourceID": SOURCE_PHOTOS,
                "sourceName": "Apple Photos",
                "fileName": "SYNTHETIC.JPG",
                "relativePath": None,
                "mediaType": "public.jpeg",
                "availability": "available",
                "contentRevision": 1,
                "acceptedTagCount": 1,
                "rejectedTagCount": 0,
                "width": 1200,
                "height": 900,
                "tags": [
                    {
                        "tagID": tag["id"],
                        "displayName": tag["displayName"],
                        "decision": "accepted" if tag["id"] == TAG_CAT else "unknown",
                    }
                    for tag in tags
                ],
                "pendingSuggestions": [],
            })

        page.route(re.compile(r".*/v1/assets/[0-9a-f-]+$"), asset_detail)
        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )
        page.route(
            "**/v1/tags/selection?**",
            lambda route: fulfill_json(route, [
                {
                    "tagID": tag["id"],
                    "acceptedCount": 1 if tag["id"] == TAG_CAT else 0,
                    "rejectedCount": 0,
                    "unknownCount": 0 if tag["id"] == TAG_CAT else 1,
                }
                for tag in tags
            ]),
        )
        page.route(
            "**/v1/tags/selection",
            lambda route: fulfill_json(route, [
                {
                    "tagID": tag["id"],
                    "acceptedCount": 1 if tag["id"] == TAG_CAT else 0,
                    "rejectedCount": 0,
                    "unknownCount": 0 if tag["id"] == TAG_CAT else 1,
                }
                for tag in tags
            ]),
        )
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

        def move_tag(route):
            tag_id = urlparse(route.request.url).path.split("/")[-2]
            payload = route.request.post_data_json
            tag_moves.append({"tagID": tag_id, **payload})
            if fail_next_move[0]:
                fail_next_move[0] = False
                fulfill_json(
                    route,
                    {"code": "conflict", "message": "synthetic move denied"},
                    status=409,
                )
                return
            for tag in tags:
                if tag["id"] == tag_id:
                    tag["groupID"] = payload["groupID"]
                    moved = dict(tag)
                    break
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "tag": moved,
                    "replayed": False,
                },
            )

        page.route(re.compile(r".*/v1/tags/[0-9a-f-]+/move$"), move_tag)

        def rename_tag(route):
            tag_id = urlparse(route.request.url).path.split("/")[-2]
            payload = route.request.post_data_json
            tag_renames.append({"tagID": tag_id, **payload})
            tag = next(item for item in tags if item["id"] == tag_id)
            tag["displayName"] = payload["name"]
            fulfill_json(route, {"operationID": payload["operationID"], "tag": tag})

        def archive_tag(route):
            tag_id = urlparse(route.request.url).path.split("/")[-2]
            payload = route.request.post_data_json
            archived_tag_ids.append(tag_id)
            tag = next(item for item in tags if item["id"] == tag_id)
            tag["state"] = "archived"
            fulfill_json(route, {"operationID": payload["operationID"], "tag": tag})

        def rename_group(route):
            group_id = urlparse(route.request.url).path.split("/")[-2]
            payload = route.request.post_data_json
            group_renames.append({"groupID": group_id, **payload})
            group = next(item for item in groups if item["id"] == group_id)
            group["displayName"] = payload["name"]
            fulfill_json(route, {"operationID": payload["operationID"], "group": group})

        page.route(re.compile(r".*/v1/tags/[0-9a-f-]+/rename$"), rename_tag)
        page.route(re.compile(r".*/v1/tags/[0-9a-f-]+/archive$"), archive_tag)
        page.route(re.compile(r".*/v1/tag-groups/[0-9a-f-]+/rename$"), rename_group)

        test_phase[0] = "initial-load"
        page.goto(BASE_URL, wait_until="networkidle")
        placeholder_state = page.evaluate(
            """() => ({
              appVisible: !document.querySelector('#appView').classList.contains('hidden'),
              inspectorHidden: document.querySelector('#workspace').classList.contains('inspector-hidden'),
              placeholderHidden: document.querySelector('#inspectorPlaceholder').classList.contains('hidden'),
              selectedAssetID: state.selectedAssetID,
              selectedDetailID: state.selectedDetail?.assetID || null,
              sourceCount: state.sources.length,
            })"""
        )
        assert page.locator("#inspectorPlaceholderTagEditor").is_visible(), (
            placeholder_state,
            page_errors,
            console_errors,
        )
        assert inspector_group_names(
            page, "inspectorPlaceholderTags", GROUP_SUBJECT
        ) == ["猫", "狗"]

        test_phase[0] = "folder-hierarchy"
        assert not folder_queries
        photos_source = page.locator(
            f'#sourceList .sidebar-row[data-source-id="{SOURCE_PHOTOS}"]'
        )
        photos_source.focus()
        photos_source.press("ArrowRight")
        assert photos_source.get_attribute("aria-expanded") is None
        assert not folder_queries

        folder_source = page.locator(
            f'#sourceList .sidebar-row[data-source-id="{SOURCE_FOLDER}"]'
        )
        folder_source.locator("[data-folder-source-toggle]").click()
        page.wait_for_function("() => document.querySelectorAll('[data-folder-path]').length === 3")
        assert folder_queries[-1].get("limit") == ["100"]
        assert page.locator(
            f'[data-folder-search-source-id="{SOURCE_FOLDER}"]'
        ).is_visible()
        assert page.locator("#sourceList").get_attribute("role") == "tree"
        assert folder_source.get_attribute("role") == "treeitem"
        assert folder_source.get_attribute("aria-level") == "1"
        assert folder_source.get_attribute("aria-expanded") == "true"
        assert folder_source.get_attribute("aria-owns") == (
            f"source-folder-tree-{SOURCE_FOLDER}"
        )
        folder_capacity = page.locator(".source-folder-capacity")
        assert folder_capacity.inner_text() == "共 501 个子文件夹，按需显示"
        assert "每次读取最多 100 个" in folder_capacity.get_attribute(
            "data-help-detail"
        )
        tree_navigation_asset_query_count = len(asset_queries)

        trips = page.locator(
            f'[data-folder-source-id="{SOURCE_FOLDER}"][data-folder-path="Trips"]'
        )
        assert trips.get_attribute("role") == "treeitem"
        assert trips.get_attribute("aria-level") == "2"
        assert trips.get_attribute("data-help-owner") == (
            f"folder:{SOURCE_FOLDER}:tree:Trips"
        )
        trips.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert page.locator("#persistentHelpTitle").inner_text() == "Trips"
        folder_help_detail = page.locator("#persistentHelpDetail").inner_text()
        for expected in [
            "只显示“Trips”目录及其所有子目录中的媒体",
            "右方向键展开",
            "左方向键折叠或返回上级",
        ]:
            assert expected in folder_help_detail, (expected, folder_help_detail)
        assert page.locator("#persistentHelp").get_attribute("data-kind") == "source"
        assert trips.get_attribute("title") is None
        page.evaluate("() => renderSources()")
        page.wait_for_function(
            "sourceID => persistentHelpTarget?.isConnected "
            "&& persistentHelpTarget?.dataset.helpOwner === "
            "`folder:${sourceID}:tree:Trips` "
            "&& document.querySelector('#persistentHelpTitle').textContent === 'Trips'",
            arg=SOURCE_FOLDER,
        )
        page.screenshot(
            path="/tmp/imageall-web-folder-scope-help.png",
            full_page=True,
        )
        page.mouse.move(720, 500)
        page.locator("#persistentHelp").wait_for(state="hidden")
        folder_source.focus()
        folder_source.press("ArrowRight")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Trips'"
        )
        trips.press("ArrowRight")
        page.wait_for_function(
            "() => Boolean(document.querySelector('[data-folder-path=\"Trips/2026\"]'))"
        )
        assert trips.get_attribute("aria-expanded") == "true"
        trips.press("ArrowRight")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Trips/2026'"
        )
        trip_2026 = page.locator('[data-folder-path="Trips/2026"]')
        assert trip_2026.get_attribute("aria-level") == "3"
        assert trip_2026.get_attribute("data-folder-parent-path") == "Trips"
        trip_2026.press("ArrowLeft")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Trips'"
        )
        trips.press("ArrowLeft")
        assert trips.get_attribute("aria-expanded") == "false"
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Trips'"
        )
        trips.press("ArrowLeft")
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.sourceId === sourceID",
            arg=SOURCE_FOLDER,
        )
        folder_source.press("ArrowRight")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Trips'"
        )
        trips.press("ArrowRight")
        trips.press("ArrowRight")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Trips/2026'"
        )
        assert len(asset_queries) == tree_navigation_asset_query_count
        page.locator('[data-folder-path="Trips/2026"] .folder-name').click()
        page.wait_for_function(
            "() => document.querySelector('#folderBreadcrumb')"
            ".classList.contains('hidden') === false"
        )
        assert "2026" in page.locator("#libraryTitle").inner_text()
        folder_asset_query = parse_qs(urlparse(asset_queries[-1]).query)
        assert folder_asset_query["folderSourceID"] == [SOURCE_FOLDER]
        assert folder_asset_query["folderRelativePath"] == ["Trips/2026"]
        page.wait_for_function(
            "() => JSON.stringify(history.state).includes('galleryFolderSessionID')"
        )
        history_payload = page.evaluate("() => JSON.stringify(history.state)")
        assert "Trips/2026" not in history_payload
        assert "galleryFolderSessionID" in history_payload
        page.screenshot(
            path="/tmp/imageall-web-folder-hierarchy.png",
            full_page=True,
        )

        current_breadcrumb = page.locator(
            f'#folderBreadcrumb [data-folder-breadcrumb-source-id="{SOURCE_FOLDER}"]'
            '[data-folder-breadcrumb-path="Trips/2026"]'
        )
        current_breadcrumb.focus()
        current_breadcrumb.press("Enter")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderBreadcrumbPath === 'Trips/2026'"
        )
        page.wait_for_timeout(300)
        assert len(asset_queries) == tree_navigation_asset_query_count + 1

        ancestor_breadcrumb = page.locator(
            f'#folderBreadcrumb [data-folder-breadcrumb-source-id="{SOURCE_FOLDER}"]'
            '[data-folder-breadcrumb-path="Trips"]'
        )
        ancestor_breadcrumb.focus()
        with page.expect_request(
            lambda request: "/v1/assets?" in request.url
        ) as ancestor_request_info:
            ancestor_breadcrumb.press("Enter")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderBreadcrumbPath === 'Trips'"
        )
        ancestor_asset_query = parse_qs(
            urlparse(ancestor_request_info.value.url).query
        )
        assert ancestor_asset_query["folderRelativePath"] == ["Trips"]
        page.screenshot(
            path="/tmp/imageall-web-folder-breadcrumb-focus.png",
            full_page=True,
        )

        with page.expect_request(
            lambda request: "/v1/assets?" in request.url
        ) as root_request_info:
            page.locator(
                f'#folderBreadcrumb [data-folder-breadcrumb-source-id="{SOURCE_FOLDER}"]'
            ).first.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('#folderBreadcrumb').classList.contains('hidden')"
        )
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.sourceId === sourceID",
            arg=SOURCE_FOLDER,
        )
        root_asset_query = parse_qs(urlparse(root_request_info.value.url).query)
        assert "folderRelativePath" not in root_asset_query

        page.locator(
            '[data-folder-path="Trips"]:not([data-folder-search-result]) .folder-name'
        ).click()
        page.wait_for_function(
            "() => !document.querySelector('#folderBreadcrumb').classList.contains('hidden')"
        )
        page.set_viewport_size({"width": 390, "height": 844})
        with page.expect_request(
            lambda request: "/v1/assets?" in request.url
        ) as narrow_root_request_info:
            page.locator(
                f'#folderBreadcrumb [data-folder-breadcrumb-source-id="{SOURCE_FOLDER}"]'
            ).first.press("Enter")
        page.wait_for_function(
            "() => document.activeElement?.id === 'sidebarToggle'"
        )
        narrow_root_asset_query = parse_qs(
            urlparse(narrow_root_request_info.value.url).query
        )
        assert "folderRelativePath" not in narrow_root_asset_query
        assert page.evaluate(
            "() => document.documentElement.scrollWidth <= innerWidth"
        )
        page.set_viewport_size({"width": 1440, "height": 960})

        folder_search = page.locator(
            f'[data-folder-search-source-id="{SOURCE_FOLDER}"]'
        )
        folder_search_submit = page.locator(
            f'[data-folder-search-submit-source-id="{SOURCE_FOLDER}"]'
        )
        assert folder_search_submit.is_disabled()
        explicit_search_asset_query_count = len(asset_queries)
        page.evaluate(
            """({ sourceID, value }) => {
              const input = document.querySelector(
                `[data-folder-search-source-id="${CSS.escape(sourceID)}"]`
              );
              input.value = value;
              input.dispatchEvent(new Event('input', { bubbles: true }));
              const button = document.querySelector(
                `[data-folder-search-submit-source-id="${CSS.escape(sourceID)}"]`
              );
              button.focus();
              button.click();
            }""",
            {"sourceID": SOURCE_FOLDER, "value": "button-query"},
        )
        page.wait_for_function(
            "() => Boolean(document.querySelector("
            "'[data-folder-path=\"Button Search/Match\"]'"
            "))"
        )
        page.wait_for_timeout(300)
        assert sum(
            query.get("q") == ["button-query"] for query in folder_queries
        ) == 1
        page.wait_for_function(
            "sourceID => "
            "document.activeElement?.dataset.folderSearchSubmitSourceId === sourceID",
            arg=SOURCE_FOLDER,
        )
        assert folder_search.input_value() == "button-query"
        assert len(asset_queries) == explicit_search_asset_query_count
        folder_search.focus()
        folder_search.press("Escape")
        page.wait_for_function(
            "() => !document.querySelector('.source-folder-search-results')"
        )
        assert folder_search_submit.is_disabled()

        page.evaluate(
            """({ sourceID, value }) => {
              const input = document.querySelector(
                `[data-folder-search-source-id="${CSS.escape(sourceID)}"]`
              );
              input.value = value;
              input.dispatchEvent(new Event('input', { bubbles: true }));
              input.focus();
              input.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Enter',
                code: 'Enter',
                bubbles: true,
              }));
            }""",
            {"sourceID": SOURCE_FOLDER, "value": "enter-query"},
        )
        page.wait_for_function(
            "() => Boolean(document.querySelector("
            "'[data-folder-path=\"Enter Search/Match\"]'"
            "))"
        )
        page.wait_for_timeout(300)
        assert sum(
            query.get("q") == ["enter-query"] for query in folder_queries
        ) == 1
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.folderSearchSourceId === sourceID",
            arg=SOURCE_FOLDER,
        )
        assert folder_search.input_value() == "enter-query"
        assert len(asset_queries) == explicit_search_asset_query_count
        search_control_geometry = page.evaluate(
            """sourceID => {
              const sidebar = document.querySelector('#sourceSidebar');
              const controls = document.querySelector('.source-folder-search-controls');
              const input = document.querySelector(
                `[data-folder-search-source-id="${CSS.escape(sourceID)}"]`
              );
              const button = document.querySelector(
                `[data-folder-search-submit-source-id="${CSS.escape(sourceID)}"]`
              );
              const controlsRect = controls.getBoundingClientRect();
              const inputRect = input.getBoundingClientRect();
              const buttonRect = button.getBoundingClientRect();
              return {
                sidebarScrollLeft: sidebar.scrollLeft,
                controlsLeft: controlsRect.left,
                controlsRight: controlsRect.right,
                inputLeft: inputRect.left,
                inputRight: inputRect.right,
                buttonLeft: buttonRect.left,
                buttonRight: buttonRect.right,
                buttonWidth: buttonRect.width,
              };
            }""",
            SOURCE_FOLDER,
        )
        assert search_control_geometry["sidebarScrollLeft"] == 0, search_control_geometry
        assert search_control_geometry["inputLeft"] >= search_control_geometry["controlsLeft"]
        assert search_control_geometry["inputRight"] < search_control_geometry["buttonLeft"]
        assert search_control_geometry["buttonRight"] <= (
            search_control_geometry["controlsRight"] + 0.5
        )
        assert search_control_geometry["buttonWidth"] >= 27
        page.screenshot(
            path="/tmp/imageall-web-folder-search-submit.png",
            full_page=True,
        )
        folder_search.press("Escape")
        page.wait_for_function(
            "() => !document.querySelector('.source-folder-search-results')"
        )
        assert folder_search_submit.is_disabled()

        folder_search.fill("%_")
        page.wait_for_function(
            "() => Boolean(document.querySelector('[data-folder-path=\"Literal %_/Match\"]'))"
        )
        assert page.locator(".source-folder-search-results").is_visible()
        assert page.locator(
            '[data-folder-path="Trips"]:not([data-folder-search-result])'
        ).is_visible()
        assert folder_queries[-1].get("q") == ["%_"]
        assert folder_queries[-1].get("limit") == ["50"]
        search_result = page.locator(
            '[data-folder-search-result="true"]'
            '[data-folder-path="Literal %_/Match"]'
        )
        search_folder_query_count = len(folder_queries)
        search_result.focus()
        search_result.press("ArrowRight")
        assert search_result.get_attribute("aria-expanded") is None
        assert len(folder_queries) == search_folder_query_count
        search_result.click()
        page.wait_for_function(
            "() => Boolean(document.querySelector("
            "'[data-folder-path=\"Literal %_/Match\"]:not([data-folder-search-result])'"
            "))"
        )
        assert page.locator(
            '[data-folder-path="Literal %_"]:not([data-folder-search-result]) '
            '[data-folder-toggle]'
        ).inner_text() == "▾"
        assert "Match" in page.locator("#folderBreadcrumb").inner_text()
        folder_asset_query = parse_qs(urlparse(asset_queries[-1]).query)
        assert folder_asset_query["folderRelativePath"] == ["Literal %_/Match"]
        page.screenshot(
            path="/tmp/imageall-web-folder-search-context.png",
            full_page=True,
        )

        asset_query_count = len(asset_queries)
        folder_search = page.locator(
            f'[data-folder-search-source-id="{SOURCE_FOLDER}"]'
        )
        folder_search.focus()
        folder_search.press("Escape")
        page.wait_for_function(
            "() => !document.querySelector('.source-folder-search-results')"
        )
        assert folder_search.input_value() == ""
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.folderSearchSourceId === sourceID",
            arg=SOURCE_FOLDER,
        )
        assert page.locator(
            '[data-folder-path="Literal %_/Match"]:not([data-folder-search-result])'
        ).is_visible()
        assert len(asset_queries) == asset_query_count
        assert page.locator("#folderBreadcrumb").is_visible()

        retry_asset_query_count = len(asset_queries)
        retry_folder = page.locator(
            '[data-folder-path="Retry"]:not([data-folder-search-result])'
        )
        retry_folder.focus()
        retry_folder.press("ArrowRight")
        retry_button = page.locator(
            f'[data-folder-retry-source-id="{SOURCE_FOLDER}"]'
            '[data-folder-retry-parent-path="Retry"]'
        )
        retry_button.wait_for(state="visible")
        assert folder_retry_attempts[0] == 1
        assert retry_button.inner_text() == "重新载入子文件夹"
        assert "测试目录暂时无法读取" in page.locator(
            '[data-folder-path="Retry"] + .source-folder-status'
        ).inner_text()
        retry_button.focus()
        retry_button.press("ArrowUp")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Retry'"
        )
        retry_folder.press("ArrowDown")
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderRetryParentPath === 'Retry'"
        )
        page.screenshot(
            path="/tmp/imageall-web-folder-retry.png",
            full_page=True,
        )

        retry_button.click()
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderRetryParentPath === 'Retry'"
        )
        assert folder_retry_attempts[0] == 2
        retry_button.click()
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Retry/Recovered'"
        )
        assert folder_retry_attempts[0] == 3
        assert retry_button.count() == 0
        assert page.locator(
            '[data-folder-path="Retry/Recovered"]'
        ).get_attribute("aria-level") == "3"
        assert len(asset_queries) == retry_asset_query_count

        search_retry_asset_query_count = len(asset_queries)
        folder_search.fill("retry-query")
        search_retry_button = page.locator(
            f'[data-folder-search-retry-source-id="{SOURCE_FOLDER}"]'
        )
        search_retry_button.wait_for(state="visible")
        assert folder_search_retry_attempts[0] == 1
        assert folder_search.input_value() == "retry-query"
        assert search_retry_button.inner_text() == "搜索失败，重试"
        assert "测试目录搜索暂时失败" in page.locator(
            ".source-folder-search-summary"
        ).inner_text()
        assert page.locator(
            '[data-folder-path="Trips"]:not([data-folder-search-result])'
        ).is_visible()
        assert len(asset_queries) == search_retry_asset_query_count
        search_retry_button.focus()
        search_retry_button.press("ArrowUp")
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.sourceId === sourceID",
            arg=SOURCE_FOLDER,
        )
        folder_source = page.locator(
            f'#sourceList .sidebar-row[data-source-id="{SOURCE_FOLDER}"]'
        )
        folder_source.press("ArrowDown")
        page.wait_for_function(
            "sourceID => "
            "document.activeElement?.dataset.folderSearchRetrySourceId === sourceID",
            arg=SOURCE_FOLDER,
        )

        search_retry_button.click()
        page.wait_for_function(
            "sourceID => "
            "document.activeElement?.dataset.folderSearchRetrySourceId === sourceID",
            arg=SOURCE_FOLDER,
        )
        assert folder_search_retry_attempts[0] == 2
        page.screenshot(
            path="/tmp/imageall-web-folder-search-retry.png",
            full_page=True,
        )
        search_retry_button.click()
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === "
            "'Retry Search/Recovered'"
        )
        assert folder_search_retry_attempts[0] == 3
        assert search_retry_button.count() == 0
        assert folder_search.input_value() == "retry-query"
        assert page.locator(
            '[data-folder-path="Trips"]:not([data-folder-search-result])'
        ).is_visible()
        assert len(asset_queries) == search_retry_asset_query_count
        folder_search.focus()
        folder_search.press("Escape")
        page.wait_for_function(
            "() => !document.querySelector('.source-folder-search-results')"
        )
        assert folder_search.input_value() == ""
        assert len(asset_queries) == search_retry_asset_query_count

        pagination_asset_query_count = len(asset_queries)
        page.wait_for_function(
            "() => Boolean(document.querySelector('[data-folder-load-more]'))"
        )
        folder_load_more = page.locator("[data-folder-load-more]")
        folder_load_more.click()
        page.wait_for_function(
            "() => document.activeElement?.textContent?.startsWith('重试显示更多')"
        )
        assert folder_queries[-1].get("offset") == ["100"]
        assert folder_pagination_attempts[0] == 1
        assert folder_load_more.inner_text() == "重试显示更多（3 / 501）"
        assert "测试目录续页暂时失败" in page.locator(
            ".source-folder-status[role=status]"
        ).last.inner_text()
        assert page.locator(
            '[data-folder-path="Trips"]:not([data-folder-search-result])'
        ).is_visible()
        assert page.locator("[data-folder-retry-source-id]").count() == 0
        assert len(asset_queries) == pagination_asset_query_count
        page.screenshot(
            path="/tmp/imageall-web-folder-pagination-retry.png",
            full_page=True,
        )

        folder_load_more.click()
        page.wait_for_function(
            "() => Boolean(document.querySelector('[data-folder-path=\"Archive\"]'))"
        )
        assert folder_queries[-1].get("offset") == ["100"]
        assert folder_pagination_attempts[0] == 2
        page.wait_for_timeout(300)
        pagination_focus = page.evaluate(
            """() => ({
              tag: document.activeElement?.tagName,
              text: document.activeElement?.textContent,
              folderLoadMore: document.activeElement?.dataset.folderLoadMore,
              buttonCount: document.querySelectorAll('[data-folder-load-more]').length,
            })"""
        )
        assert pagination_focus["folderLoadMore"] is not None, pagination_focus
        assert folder_load_more.inner_text() == "显示更多（4 / 501）"
        assert len(asset_queries) == pagination_asset_query_count
        page.screenshot(
            path="/tmp/imageall-web-folder-pagination-focus.png",
            full_page=True,
        )

        folder_load_more.click()
        page.wait_for_function(
            "() => document.activeElement?.dataset.folderPath === 'Vault'"
        )
        assert folder_queries[-1].get("offset") == ["200"]
        assert page.locator("[data-folder-load-more]").count() == 0
        assert page.locator(
            '[data-folder-path="Vault"]:not([data-folder-search-result])'
        ).is_visible()
        assert len(asset_queries) == pagination_asset_query_count
        assert page.locator("#folderBreadcrumb").is_visible()

        page.set_viewport_size({"width": 390, "height": 844})
        assert page.evaluate("() => document.documentElement.scrollWidth <= innerWidth")
        page.set_viewport_size({"width": 1440, "height": 960})
        folder_source = page.locator(
            f'#sourceList .sidebar-row[data-source-id="{SOURCE_FOLDER}"]'
        )
        folder_source.locator("[data-folder-source-toggle]").click()
        assert page.locator("#sourceList [data-folder-tree-source-id]").count() == 0

        placeholder_dog = page.locator(
            f'#inspectorPlaceholderTags [data-tag-reorder-surface="placeholder"]'
            f'[data-tag-id="{TAG_DOG}"]'
        )
        placeholder_cat = page.locator(
            f'#inspectorPlaceholderTags [data-tag-reorder-surface="placeholder"]'
            f'[data-tag-id="{TAG_CAT}"]'
        )
        assert placeholder_dog.get_attribute("aria-disabled") == "true"
        assert placeholder_dog.get_attribute("draggable") == "true"
        assert page.evaluate(
            "id => !document.querySelector("
            "`#inspectorPlaceholderTags [data-tag-id=\"${id}\"]`"
            ").disabled",
            TAG_DOG,
        )
        test_phase[0] = "placeholder-reorder"
        placeholder_dog.drag_to(placeholder_cat)
        page.wait_for_function(
            "id => document.activeElement?.dataset.tagId === id "
            "&& document.activeElement?.dataset.tagReorderSurface === 'placeholder'",
            arg=TAG_DOG,
        )
        assert inspector_group_names(
            page, "inspectorPlaceholderTags", GROUP_SUBJECT
        ) == ["狗", "猫"]
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["狗", "猫"]
        assert not tag_moves
        placeholder_dog = page.locator(
            f'#inspectorPlaceholderTags [data-tag-reorder-surface="placeholder"]'
            f'[data-tag-id="{TAG_DOG}"]'
        )
        placeholder_dog.focus()
        placeholder_dog.press("Alt+ArrowDown")
        assert inspector_group_names(
            page, "inspectorPlaceholderTags", GROUP_SUBJECT
        ) == ["猫", "狗"]
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫", "狗"]
        assert not tag_moves
        page.screenshot(
            path="/tmp/imageall-inspector-placeholder-tags.png",
            full_page=True,
        )
        test_phase[0] = "source-reorder"
        assert source_names(page) == ["Apple Photos", "Downloads"]
        page.locator(f'#sourceList .sidebar-row[data-source-id="{SOURCE_FOLDER}"]').drag_to(
            page.locator(f'#sourceList .sidebar-row[data-source-id="{SOURCE_PHOTOS}"]')
        )
        page.wait_for_function(
            "id => document.querySelector('#sourceList [data-source-id]')?.dataset.sourceId === id",
            arg=SOURCE_FOLDER,
        )
        assert source_names(page) == ["Downloads", "Apple Photos"]
        page.wait_for_function(
            "id => document.activeElement?.dataset.sourceId === id",
            arg=SOURCE_FOLDER,
        )
        assert page.evaluate("() => document.activeElement?.dataset.sourceId") == SOURCE_FOLDER
        assert page.evaluate(
            "() => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
            ".sourceOrderIDs[0]"
        ) == SOURCE_FOLDER

        page.reload(wait_until="networkidle")
        assert source_names(page) == ["Downloads", "Apple Photos"]
        folder = page.locator(
            f'#sourceList .sidebar-row[data-source-id="{SOURCE_FOLDER}"]'
        )
        folder.focus()
        folder.press("Alt+ArrowDown")
        assert source_names(page) == ["Apple Photos", "Downloads"]

        photos = page.locator(
            f'#sourceList .sidebar-row[data-source-id="{SOURCE_PHOTOS}"]'
        )
        photos.click(button="right")
        source_menu = page.locator("#sourceContextMenu:not(.hidden)")
        source_menu.wait_for()
        assert source_menu.locator(
            '[data-source-context-action="moveEarlier"]'
        ).is_disabled()
        assert not source_menu.locator(
            '[data-source-context-action="moveLater"]'
        ).is_disabled()
        source_menu.locator('[data-source-context-action="moveLater"]').click()
        assert source_names(page) == ["Downloads", "Apple Photos"]
        page.wait_for_function(
            "id => document.activeElement?.dataset.sourceId === id",
            arg=SOURCE_PHOTOS,
        )
        photos.click(button="right")
        source_menu.locator('[data-source-context-action="moveEarlier"]').click()
        assert source_names(page) == ["Apple Photos", "Downloads"]
        page.wait_for_function(
            "id => document.activeElement?.dataset.sourceId === id",
            arg=SOURCE_PHOTOS,
        )

        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        scene_toggle = sidebar_group_toggle(page, GROUP_SCENE)
        assert subject_toggle.get_attribute("aria-expanded") == "true"
        assert subject_toggle.locator(".tag-navigation-group-count").inner_text() == "2"
        collapse_identity = page.evaluate(
            f"""() => {{
              const navigation = document.querySelector("#tagNavigation");
              const subject = navigation.querySelector(
                '[data-sidebar-tag-group-id="{GROUP_SUBJECT}"]'
              );
              const scene = navigation.querySelector(
                '[data-sidebar-tag-group-id="{GROUP_SCENE}"]'
              );
              const toggle = subject.querySelector(".tag-navigation-group-title");
              const cat = subject.querySelector('[data-quick-tag-id="{TAG_CAT}"]');
              const dog = subject.querySelector('[data-quick-tag-id="{TAG_DOG}"]');
              const placeholder = document.querySelector("#inspectorPlaceholderTags");
              const placeholderSubject = placeholder.querySelector(
                '[data-inspector-tag-group-id="{GROUP_SUBJECT}"]'
              );
              const placeholderScene = placeholder.querySelector(
                '[data-inspector-tag-group-id="{GROUP_SCENE}"]'
              );
              toggle.focus({{ preventScroll: true }});
              window.__stableSidebarCollapseFrame = {{
                subject,
                scene,
                toggle,
                list: subject.querySelector(".tag-navigation-group-tags"),
                cat,
                dog,
                placeholder,
                placeholderSubject,
                placeholderScene,
                placeholderCat: placeholderSubject.querySelector(
                  '[data-tag-chip-action][data-tag-id="{TAG_CAT}"]'
                ),
                placeholderDog: placeholderSubject.querySelector(
                  '[data-tag-chip-action][data-tag-id="{TAG_DOG}"]'
                ),
                placeholderTravel: placeholderScene.querySelector(
                  '[data-tag-chip-action][data-tag-id="{TAG_TRAVEL}"]'
                ),
              }};
              toggle.click();
              const frame = window.__stableSidebarCollapseFrame;
              return {{
                subject: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SUBJECT}"]'
                ) === frame.subject,
                scene: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SCENE}"]'
                ) === frame.scene,
                toggle: frame.subject.querySelector(".tag-navigation-group-title")
                  === frame.toggle,
                list: frame.subject.querySelector(".tag-navigation-group-tags")
                  === frame.list,
                cat: frame.subject.querySelector('[data-quick-tag-id="{TAG_CAT}"]')
                  === frame.cat,
                dog: frame.subject.querySelector('[data-quick-tag-id="{TAG_DOG}"]')
                  === frame.dog,
                placeholder: document.querySelector("#inspectorPlaceholderTags")
                  === frame.placeholder,
                placeholderSubject: frame.placeholder.querySelector(
                  '[data-inspector-tag-group-id="{GROUP_SUBJECT}"]'
                ) === frame.placeholderSubject,
                placeholderScene: frame.placeholder.querySelector(
                  '[data-inspector-tag-group-id="{GROUP_SCENE}"]'
                ) === frame.placeholderScene,
                placeholderCat: frame.placeholder.querySelector(
                  '[data-tag-chip-action][data-tag-id="{TAG_CAT}"]'
                ) === frame.placeholderCat,
                placeholderDog: frame.placeholder.querySelector(
                  '[data-tag-chip-action][data-tag-id="{TAG_DOG}"]'
                ) === frame.placeholderDog,
                placeholderTravel: frame.placeholder.querySelector(
                  '[data-tag-chip-action][data-tag-id="{TAG_TRAVEL}"]'
                ) === frame.placeholderTravel,
                focus: document.activeElement === frame.toggle,
              }};
            }}"""
        )
        assert all(collapse_identity.values()), collapse_identity
        assert subject_toggle.get_attribute("aria-expanded") == "false"
        assert not page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').is_visible()
        page.reload(wait_until="networkidle")
        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        assert subject_toggle.get_attribute("aria-expanded") == "false"
        page.locator("#tagNavigationSearch").fill("猫")
        assert subject_toggle.get_attribute("aria-expanded") == "true"
        assert page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').is_visible()
        page.locator("#tagNavigationSearch").fill("")
        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        assert subject_toggle.get_attribute("aria-expanded") == "false"
        subject_toggle.focus()
        subject_toggle.press("ArrowDown")
        assert page.evaluate(
            "() => document.activeElement?.dataset.sidebarTagGroupToggle"
        ) == GROUP_SCENE
        subject_toggle.click()
        assert subject_toggle.get_attribute("aria-expanded") == "true"

        test_phase[0] = "sidebar-tag-reorder"
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫", "狗"]
        page.locator(f'[data-quick-tag-id="{TAG_DOG}"]').drag_to(
            page.locator(f'[data-quick-tag-id="{TAG_CAT}"]')
        )
        page.wait_for_function(
            "id => document.querySelector('#tagNavigation [data-quick-tag-id]')?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["狗", "猫"]
        assert not tag_moves

        test_phase[0] = "single-inspector-open"
        page.locator("#assetGrid > .asset-card").click()
        page.locator("#inspectorContent:not(.hidden)").wait_for()
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["狗", "猫"]

        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        page.wait_for_timeout(300)
        subject_toggle.click()
        page.wait_for_function(
            "groupID => document.querySelector("
            "`#tagNavigation [data-sidebar-tag-group-toggle=\"${groupID}\"]`"
            ")?.getAttribute('aria-expanded') === 'false' "
            "&& document.querySelector("
            "`#inspectorTags [data-inspector-tag-group-toggle=\"${groupID}\"]`"
            ")?.getAttribute('aria-expanded') === 'false' "
            "&& document.querySelector("
            "`#inspectorPlaceholderTags [data-inspector-tag-group-toggle=\"${groupID}\"]`"
            ")?.getAttribute('aria-expanded') === 'false'",
            arg=GROUP_SUBJECT,
        )
        assert subject_toggle.get_attribute("aria-expanded") == "false"
        single_subject_toggle = inspector_group_toggle(
            page, "inspectorTags", GROUP_SUBJECT
        )
        assert single_subject_toggle.get_attribute("aria-expanded") == "false"
        assert not page.locator(
            f'#inspectorTags [data-tag-chip-action][data-tag-id="{TAG_CAT}"]'
        ).is_visible()
        shared_preferences = page.evaluate(
            "() => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
        )
        assert GROUP_SUBJECT in shared_preferences["collapsedTagGroupIDs"]
        assert GROUP_SUBJECT in shared_preferences["collapsedSidebarTagGroupIDs"]
        assert GROUP_SUBJECT in shared_preferences["collapsedInspectorTagGroupIDs"]
        page.screenshot(
            path="/tmp/imageall-shared-tag-group-collapse.png",
            full_page=True,
        )

        page.reload(wait_until="networkidle")
        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        assert subject_toggle.get_attribute("aria-expanded") == "false"
        page.locator("#assetGrid > .asset-card").click()
        page.locator("#inspectorContent:not(.hidden)").wait_for()
        single_subject_toggle = inspector_group_toggle(
            page, "inspectorTags", GROUP_SUBJECT
        )
        assert single_subject_toggle.get_attribute("aria-expanded") == "false"
        single_subject_toggle.click()
        assert single_subject_toggle.get_attribute("aria-expanded") == "true"
        assert sidebar_group_toggle(page, GROUP_SUBJECT).get_attribute(
            "aria-expanded"
        ) == "true"
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["狗", "猫"]

        page.evaluate(
            f"""() => {{
              const navigation = document.querySelector("#tagNavigation");
              window.__stableSidebarMoveFrame = {{
                subject: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SUBJECT}"]'
                ),
                scene: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SCENE}"]'
                ),
                cat: navigation.querySelector('[data-quick-tag-id="{TAG_CAT}"]'),
                dog: navigation.querySelector('[data-quick-tag-id="{TAG_DOG}"]'),
                travel: navigation.querySelector('[data-quick-tag-id="{TAG_TRAVEL}"]'),
              }};
            }}"""
        )
        page.locator(f'[data-quick-tag-id="{TAG_DOG}"]').drag_to(
            page.locator(f'[data-quick-tag-id="{TAG_TRAVEL}"]')
        )
        page.wait_for_function("() => document.querySelector('#toastMessage').textContent.includes('移动到')")
        assert len(tag_moves) == 1
        assert tag_moves[0]["tagID"] == TAG_DOG
        assert tag_moves[0]["groupID"] == GROUP_SCENE
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫"]
        assert sidebar_group_names(page, GROUP_SCENE) == ["狗", "旅行"]
        assert inspector_group_names(page, "inspectorTags", GROUP_SCENE) == ["狗", "旅行"]
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        assert page.evaluate("() => document.activeElement?.dataset.quickTagId") == TAG_DOG
        move_identity = page.evaluate(
            f"""() => {{
              const frame = window.__stableSidebarMoveFrame;
              const navigation = document.querySelector("#tagNavigation");
              const dog = navigation.querySelector('[data-quick-tag-id="{TAG_DOG}"]');
              return {{
                subject: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SUBJECT}"]'
                ) === frame.subject,
                scene: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SCENE}"]'
                ) === frame.scene,
                cat: navigation.querySelector('[data-quick-tag-id="{TAG_CAT}"]')
                  === frame.cat,
                dog: dog === frame.dog,
                travel: navigation.querySelector('[data-quick-tag-id="{TAG_TRAVEL}"]')
                  === frame.travel,
                moved: dog.closest('[data-sidebar-tag-group-id]') === frame.scene,
                focus: document.activeElement === dog,
              }};
            }}"""
        )
        assert all(move_identity.values()), move_identity

        dog = page.locator(f'[data-quick-tag-id="{TAG_DOG}"]')
        dog.focus()
        dog.press("Alt+ArrowRight")
        assert sidebar_group_names(page, GROUP_SCENE) == ["旅行", "狗"]
        assert inspector_group_names(page, "inspectorTags", GROUP_SCENE) == ["旅行", "狗"]
        assert len(tag_moves) == 1

        page.evaluate(
            f"""() => {{
              const navigation = document.querySelector("#tagNavigation");
              window.__stableSidebarRollbackFrame = {{
                subject: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SUBJECT}"]'
                ),
                scene: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SCENE}"]'
                ),
                cat: navigation.querySelector('[data-quick-tag-id="{TAG_CAT}"]'),
                dog: navigation.querySelector('[data-quick-tag-id="{TAG_DOG}"]'),
                travel: navigation.querySelector('[data-quick-tag-id="{TAG_TRAVEL}"]'),
              }};
            }}"""
        )
        fail_next_move[0] = True
        page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').drag_to(
            page.locator(f'[data-quick-tag-id="{TAG_TRAVEL}"]')
        )
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('synthetic move denied')"
        )
        assert len(tag_moves) == 2
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫"]
        assert sidebar_group_names(page, GROUP_SCENE) == ["旅行", "狗"]
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["猫"]
        rollback_identity = page.evaluate(
            f"""() => {{
              const frame = window.__stableSidebarRollbackFrame;
              const navigation = document.querySelector("#tagNavigation");
              return {{
                subject: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SUBJECT}"]'
                ) === frame.subject,
                scene: navigation.querySelector(
                  '[data-sidebar-tag-group-id="{GROUP_SCENE}"]'
                ) === frame.scene,
                cat: navigation.querySelector('[data-quick-tag-id="{TAG_CAT}"]')
                  === frame.cat,
                dog: navigation.querySelector('[data-quick-tag-id="{TAG_DOG}"]')
                  === frame.dog,
                travel: navigation.querySelector('[data-quick-tag-id="{TAG_TRAVEL}"]')
                  === frame.travel,
              }};
            }}"""
        )
        assert all(rollback_identity.values()), rollback_identity

        test_phase[0] = "single-inspector-reorder"
        page.locator(
            f'#inspectorTags [data-tag-reorder-surface="single"][data-tag-id="{TAG_DOG}"]'
        ).drag_to(page.locator(
            f'#inspectorTags [data-tag-reorder-surface="single"][data-tag-id="{TAG_CAT}"]'
        ))
        page.wait_for_function(
            "id => document.activeElement?.dataset.tagId === id "
            "&& document.activeElement?.dataset.tagReorderSurface === 'single'",
            arg=TAG_DOG,
        )
        assert len(tag_moves) == 3
        assert tag_moves[-1]["tagID"] == TAG_DOG
        assert tag_moves[-1]["groupID"] == GROUP_SUBJECT
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["狗", "猫"]
        assert sidebar_group_names(page, GROUP_SCENE) == ["旅行"]
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["狗", "猫"]

        inspector_dog = page.locator(
            f'#inspectorTags [data-tag-reorder-surface="single"][data-tag-id="{TAG_DOG}"]'
        )
        inspector_dog.focus()
        inspector_dog.press("Alt+ArrowDown")
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["猫", "狗"]
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫", "狗"]
        assert len(tag_moves) == 3
        page.screenshot(path="/tmp/imageall-sidebar-reordering-wide.png", full_page=True)

        page.locator("#tagNavigationSearch").fill("猫")
        assert page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').get_attribute("draggable") == "false"
        page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').click(button="right")
        search_tag_menu = page.locator("#tagContextMenu:not(.hidden)")
        for action in [
            "moveEarlier",
            "moveLater",
            "movePreviousGroup",
            "moveNextGroup",
        ]:
            assert search_tag_menu.locator(
                f'[data-tag-context-action="{action}"]'
            ).is_disabled()
        page.keyboard.press("Escape")
        page.locator("#tagNavigationSearch").fill("")

        page.reload(wait_until="networkidle")
        assert source_names(page) == ["Apple Photos", "Downloads"]
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫", "狗"]
        assert sidebar_group_names(page, GROUP_SCENE) == ["旅行"]
        test_phase[0] = "selection-reorder"
        page.locator("#selectionModeButton").click()
        page.locator("#assetGrid > .asset-card").click()
        page.locator("#selectionInspector:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#selectionInspectorTags .inspector-tag-chip')"
        )
        page.wait_for_function(
            "() => !document.querySelector("
            "'#selectionInspectorTags [data-action=\"accept\"]'"
            ")?.disabled"
        )
        assert inspector_group_names(page, "selectionInspectorTags", GROUP_SUBJECT) == ["猫", "狗"]
        selection_dog = page.locator(
            f'#selectionInspectorTags [data-tag-reorder-surface="selection"]'
            f'[data-tag-id="{TAG_DOG}"]'
        )
        assert selection_dog.get_attribute("draggable") == "true"
        assert not selection_dog.is_disabled()
        selection_cat = page.locator(
            f'#selectionInspectorTags [data-tag-reorder-surface="selection"]'
            f'[data-tag-id="{TAG_CAT}"]'
        )
        assert not selection_cat.is_disabled()
        selection_dog.drag_to(selection_cat)
        page.wait_for_function(
            "id => document.activeElement?.dataset.tagId === id "
            "&& document.activeElement?.dataset.tagReorderSurface === 'selection'",
            arg=TAG_DOG,
        )
        selection_subject_order = inspector_group_names(
            page, "selectionInspectorTags", GROUP_SUBJECT
        )
        assert selection_subject_order == ["狗", "猫"], selection_subject_order
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["狗", "猫"]
        assert len(tag_moves) == 3

        test_phase[0] = "responsive-group-collapse"
        page.set_viewport_size({"width": 390, "height": 844})
        page.locator("#sidebarToggle").click()
        page.locator("#sourceSidebar.open").wait_for()
        scene_toggle = sidebar_group_toggle(page, GROUP_SCENE)
        scene_toggle.scroll_into_view_if_needed()
        scene_toggle.click()
        assert scene_toggle.get_attribute("aria-expanded") == "false"
        assert inspector_group_toggle(
            page, "selectionInspectorTags", GROUP_SCENE
        ).get_attribute("aria-expanded") == "false"
        page.locator("#sidebarToggle").click()
        page.wait_for_timeout(250)
        page.screenshot(
            path="/tmp/imageall-shared-tag-group-collapse-390.png",
            full_page=False,
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_timeout(100)
        selection_scene_toggle = inspector_group_toggle(
            page, "selectionInspectorTags", GROUP_SCENE
        )
        selection_scene_toggle.click()
        assert selection_scene_toggle.get_attribute("aria-expanded") == "true"
        assert sidebar_group_toggle(page, GROUP_SCENE).get_attribute(
            "aria-expanded"
        ) == "true"

        page.wait_for_timeout(300)
        test_phase[0] = "tag-filtering"
        dog_chip = page.locator(f'[data-quick-tag-id="{TAG_DOG}"]')
        travel_chip = page.locator(f'[data-quick-tag-id="{TAG_TRAVEL}"]')
        page.evaluate(
            f"""() => {{
              const navigation = document.querySelector("#tagNavigation");
              const dog = navigation.querySelector('[data-quick-tag-id="{TAG_DOG}"]');
              const travel = navigation.querySelector('[data-quick-tag-id="{TAG_TRAVEL}"]');
              const subject = navigation.querySelector(
                '[data-sidebar-tag-group-id="{GROUP_SUBJECT}"]'
              );
              const scene = navigation.querySelector(
                '[data-sidebar-tag-group-id="{GROUP_SCENE}"]'
              );
              const mutations = [];
              const observer = new MutationObserver((records) => mutations.push(...records));
              dog.focus({{ preventScroll: true }});
              observer.observe(travel, {{
                attributes: true,
                childList: true,
                characterData: true,
                subtree: true,
              }});
              observer.observe(scene, {{
                attributes: true,
                childList: true,
                characterData: true,
                subtree: true,
              }});
              window.__stableSidebarTagFrame = {{
                navigation,
                dog,
                travel,
                subject,
                scene,
                subjectToggle: subject.querySelector(".tag-navigation-group-title"),
                subjectList: subject.querySelector(".tag-navigation-group-tags"),
                sceneToggle: scene.querySelector(".tag-navigation-group-title"),
                sceneList: scene.querySelector(".tag-navigation-group-tags"),
                mutations,
                observer,
              }};
              dog.click();
            }}"""
        )
        page.wait_for_function("() => !state.loadingAssets && !state.assetLoadPromise")
        stable_sidebar_filter = page.evaluate(
            f"""() => {{
              const frame = window.__stableSidebarTagFrame;
              frame.mutations.push(...frame.observer.takeRecords());
              frame.observer.disconnect();
              const navigation = document.querySelector("#tagNavigation");
              const dog = navigation.querySelector('[data-quick-tag-id="{TAG_DOG}"]');
              const travel = navigation.querySelector('[data-quick-tag-id="{TAG_TRAVEL}"]');
              const subject = navigation.querySelector(
                '[data-sidebar-tag-group-id="{GROUP_SUBJECT}"]'
              );
              const scene = navigation.querySelector(
                '[data-sidebar-tag-group-id="{GROUP_SCENE}"]'
              );
              return {{
                navigation: navigation === frame.navigation,
                dog: dog === frame.dog,
                travel: travel === frame.travel,
                subject: subject === frame.subject,
                scene: scene === frame.scene,
                subjectToggle: subject.querySelector(".tag-navigation-group-title")
                  === frame.subjectToggle,
                subjectList: subject.querySelector(".tag-navigation-group-tags")
                  === frame.subjectList,
                sceneToggle: scene.querySelector(".tag-navigation-group-title")
                  === frame.sceneToggle,
                sceneList: scene.querySelector(".tag-navigation-group-tags")
                  === frame.sceneList,
                focus: document.activeElement === dog,
                selected: dog.dataset.tagFilterState === "included",
                unrelatedMutations: frame.mutations.length === 0,
              }};
            }}"""
        )
        assert all(stable_sidebar_filter.values()), stable_sidebar_filter
        assert dog_chip.get_attribute("data-tag-filter-state") == "included"
        travel_chip.click(modifiers=["Meta"])
        assert travel_chip.get_attribute("data-tag-filter-state") == "included"
        query = parse_qs(urlparse(asset_queries[-1]).query)
        assert set(query["acceptedTagIDs"][0].split(",")) == {TAG_DOG, TAG_TRAVEL}
        assert query["tagMatchMode"] == ["all"]

        dog_chip.click(modifiers=["Meta", "Alt"])
        assert dog_chip.get_attribute("data-tag-filter-state") == "excluded"
        assert dog_chip.get_attribute("aria-label") == "狗，已排除"
        query = parse_qs(urlparse(asset_queries[-1]).query)
        assert query["acceptedTagIDs"] == [TAG_TRAVEL]
        assert query["excludedTagIDs"] == [TAG_DOG]

        test_phase[0] = "tag-context-menu"
        if not page.evaluate("() => state.selectionMode"):
            page.locator("#selectionModeButton").click()
        page.locator("#assetGrid > .asset-card").first.click()
        page.wait_for_function("() => state.selectedAssetIDs.size > 0")
        new_tag_history_length = page.evaluate("() => history.length")
        new_tag_asset_query_count = len(asset_queries)
        page.locator("#sidebarNewTagButton").focus()
        page.locator("#sidebarNewTagButton").click()
        page.locator("#newTagDialog[open]").wait_for()
        assert page.evaluate("() => history.length") in {
            new_tag_history_length,
            new_tag_history_length + 1,
        }
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "newTag"
        page.locator("#newTagName").fill("浏览器历史草稿")
        new_tag_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "浏览器历史草稿" not in new_tag_history_payload
        page.evaluate("() => history.back()")
        page.locator("#newTagDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'sidebarNewTagButton'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#newTagDialog[open]").wait_for()
        assert page.locator("#newTagName").input_value() == "浏览器历史草稿"
        page.locator("#cancelNewTagFooterButton").click()
        page.locator("#newTagDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'sidebarNewTagButton'"
        )
        assert len(asset_queries) == new_tag_asset_query_count

        dog_chip.click(button="right")
        tag_menu = page.locator("#tagContextMenu:not(.hidden)")
        tag_menu.wait_for()
        assert tag_menu.locator("#tagContextMenuTitle").inner_text() == "标签 · 狗"
        assert tag_menu.locator("[data-tag-context-action]").all_inner_texts() == [
            "仅筛选此标签",
            "取消排除此标签",
            "在分组内前移",
            "在分组内后移",
            "移到上一分组",
            "移到下一分组",
            "重命名…",
            "归档标签",
        ]
        assert tag_menu.locator(
            '[data-tag-context-action="moveEarlier"]'
        ).is_disabled()
        assert not tag_menu.locator(
            '[data-tag-context-action="moveLater"]'
        ).is_disabled()
        page.screenshot(path="/tmp/imageall-tag-context-menu.png", full_page=True)
        tag_menu.locator('[data-tag-context-action="moveLater"]').click()
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫", "狗"]
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        dog_chip.click(button="right")
        tag_menu.locator('[data-tag-context-action="moveEarlier"]').click()
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["狗", "猫"]
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        page.evaluate("() => { state.online = false; }")
        dog_chip.click(button="right")
        assert not tag_menu.locator(
            '[data-tag-context-action="moveLater"]'
        ).is_disabled()
        assert tag_menu.locator(
            '[data-tag-context-action="moveNextGroup"]'
        ).is_disabled()
        page.keyboard.press("Escape")
        page.evaluate("() => { state.online = true; }")
        dog_chip.click(button="right")
        tag_menu.locator('[data-tag-context-action="filterOnly"]').click()
        assert dog_chip.get_attribute("data-tag-filter-state") == "included"
        assert travel_chip.get_attribute("data-tag-filter-state") == "none"
        page.wait_for_function("() => !state.loadingAssets")

        dog_chip.focus()
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        dog_chip.press("Shift+F10")
        tag_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.tagContextAction === 'filterOnly'"
        )
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.tagContextAction"
        ) == "archiveTag"
        page.keyboard.press("Escape")
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )

        dog_chip.click(button="right")
        tag_menu.locator('[data-tag-context-action="renameTag"]').click()
        page.locator("#tagManagerDialog[open]").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "tagManager"
        assert page.locator("#tagManagerTagSelect").input_value() == TAG_DOG
        assert page.evaluate("() => document.activeElement?.id") == "tagManagerTagName"
        manager_asset_query_count = len(asset_queries)
        page.evaluate("() => history.back()")
        page.locator("#tagManagerDialog").wait_for(state="hidden")
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        page.evaluate("() => history.forward()")
        page.locator("#tagManagerDialog[open]").wait_for()
        assert page.locator("#tagManagerTagSelect").input_value() == TAG_DOG
        assert page.evaluate("() => document.activeElement?.id") == "tagManagerTagName"
        assert len(asset_queries) == manager_asset_query_count
        page.locator("#tagManagerTagName").fill("狗狗")
        page.locator("#renameManagedTagButton").click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('狗狗')"
        )
        assert len(tag_renames) == 1
        page.locator("#closeTagManagerButton").click()
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        assert page.locator(f'[data-quick-tag-id="{TAG_DOG}"]').inner_text() == "狗狗"

        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        subject_toggle.focus()
        subject_toggle.press("Shift+F10")
        tag_menu.wait_for()
        assert tag_menu.locator("#tagContextMenuTitle").inner_text() == "标签分组 · 主体"
        tag_menu.locator('[data-tag-context-action="renameGroup"]').click()
        page.locator("#tagManagerDialog[open]").wait_for()
        assert page.locator("#tagManagerGroupSelect").input_value() == GROUP_SUBJECT
        assert page.evaluate("() => document.activeElement?.id") == "tagManagerGroupName"
        page.locator("#tagManagerGroupName").fill("主体分类")
        page.locator("#renameTagGroupButton").click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('主体分类')"
        )
        assert len(group_renames) == 1
        page.locator("#deleteTagGroupButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "confirmation"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.confirmationBaseLevel"
        ) == "tagManager"
        tag_confirmation_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "主体分类" not in tag_confirmation_history_payload
        assert "删除标签分组" not in tag_confirmation_history_payload
        page.evaluate("() => history.back()")
        page.locator("#confirmDialog").wait_for(state="hidden")
        assert page.locator("#tagManagerDialog").is_visible()
        assert page.locator("#tagManagerGroupName").input_value() == "主体分类"
        page.evaluate("() => history.forward()")
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#cancelConfirmButton").click()
        page.locator("#confirmDialog").wait_for(state="hidden")
        assert page.locator("#tagManagerDialog").is_visible()
        page.locator("#closeTagManagerButton").click()
        page.wait_for_function(
            "id => document.activeElement?.dataset.sidebarTagGroupToggle === id",
            arg=GROUP_SUBJECT,
        )
        assert subject_toggle.locator("strong").inner_text() == "主体分类"

        subject_toggle.click(button="right")
        tag_menu.locator('[data-tag-context-action="deleteGroup"]').click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "主体分类" in page.locator("#confirmDialogMessage").inner_text()
        page.locator("#cancelConfirmButton").click()
        page.wait_for_function(
            "id => document.activeElement?.dataset.sidebarTagGroupToggle === id",
            arg=GROUP_SUBJECT,
        )

        cat_chip = page.locator(f'[data-quick-tag-id="{TAG_CAT}"]')
        cat_chip.click(button="right")
        tag_menu.locator('[data-tag-context-action="archiveTag"]').click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#confirmActionButton").click()
        page.wait_for_function(
            "id => !document.querySelector(`[data-quick-tag-id=\"${id}\"]`)",
            arg=TAG_CAT,
        )
        assert archived_tag_ids == [TAG_CAT]
        page.wait_for_function(
            "id => document.activeElement?.dataset.sidebarTagGroupToggle === id",
            arg=GROUP_SUBJECT,
        )

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        page.locator("#sidebarToggle").click()
        page.locator("#sourceSidebar.open").wait_for()
        mobile_dog_chip = page.locator(f'[data-quick-tag-id="{TAG_DOG}"]')
        mobile_dog_chip.scroll_into_view_if_needed()
        mobile_dog_bounds = mobile_dog_chip.bounding_box()
        assert mobile_dog_bounds is not None
        mobile_dog_point = {
            "x": mobile_dog_bounds["x"] + mobile_dog_bounds["width"] / 2,
            "y": mobile_dog_bounds["y"] + mobile_dog_bounds["height"] / 2,
        }
        page.evaluate(
            """({ tagID, point }) => {
              document.querySelector(`[data-quick-tag-id="${tagID}"]`).dispatchEvent(
                new PointerEvent('pointerdown', {
                  bubbles: true,
                  pointerId: 94,
                  pointerType: 'touch',
                  button: 0,
                  clientX: point.x,
                  clientY: point.y,
                  isPrimary: true,
                })
              );
            }""",
            {"tagID": TAG_DOG, "point": mobile_dog_point},
        )
        page.wait_for_timeout(580)
        tag_menu.wait_for()
        assert not tag_menu.locator(
            '[data-tag-context-action="moveNextGroup"]'
        ).is_disabled()
        assert tag_menu.locator(
            '[data-tag-context-action="movePreviousGroup"]'
        ).is_disabled()
        page.screenshot(
            path="/tmp/imageall-sidebar-touch-ordering-390.png",
            full_page=False,
        )
        previous_tag_move_count = len(tag_moves)
        tag_menu.locator('[data-tag-context-action="moveNextGroup"]').click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('移动到')"
        )
        assert len(tag_moves) == previous_tag_move_count + 1
        assert tag_moves[-1]["tagID"] == TAG_DOG
        assert tag_moves[-1]["groupID"] == GROUP_SCENE
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        page.screenshot(path="/tmp/imageall-sidebar-reordering-synthetic.png", full_page=True)

        assert not page_errors, page_errors
        assert not unexpected_tag_decisions, unexpected_tag_decisions
        unexpected_console_errors = [
            message for message in console_errors
            if "status of 409" not in message and "status of 503" not in message
        ]
        assert not unexpected_console_errors, {
            "console": unexpected_console_errors,
            "unsupportedRequests": unsupported_requests,
            "unexpectedTagDecisions": unexpected_tag_decisions,
        }
        assert any("status of 409" in message for message in console_errors)
        assert sum("status of 503" in message for message in console_errors) == 5
        browser.close()

    print(
        "sidebar reordering browser flow passed; "
        f"source order persisted; tag moves={len(tag_moves)} (1 rejected); "
        f"renames={len(tag_renames) + len(group_renames)}; archived={len(archived_tag_ids)}"
    )


if __name__ == "__main__":
    main()
