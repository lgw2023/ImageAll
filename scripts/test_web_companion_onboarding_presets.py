#!/usr/bin/env python3
import json
import uuid
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8807"
GROUP_IDS = {
    "主体": "a0000000-0000-4000-8000-000000000001",
    "场景": "a0000000-0000-4000-8000-000000000002",
    "活动": "a0000000-0000-4000-8000-000000000003",
    "媒介": "a0000000-0000-4000-8000-000000000006",
}
PRESET_NAMES = ["人像", "风景", "美食", "动物", "植物", "建筑", "旅行", "截图", "文档"]


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def main():
    tags = []
    preset_requests = []
    source_requests = []
    notice_dismissals = []
    workspace_notice = [{
        "id": "notice-1",
        "severity": "warning",
        "message": "后台扫描未完成，已索引的照片仍可继续浏览。",
    }]
    console_errors = []
    page_errors = []

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
                    "capabilities": ["workspaceNotices"],
                },
            ),
        )

        page.route(
            "**/v1/workspace-notice",
            lambda route: fulfill_json(route, {"notice": workspace_notice[0]}),
        )

        def route_workspace_notice_dismiss(route):
            payload = route.request.post_data_json
            notice_dismissals.append(payload)
            if len(notice_dismissals) == 1:
                workspace_notice[0] = {
                    "id": "notice-2",
                    "severity": "success",
                    "message": "已开始增量同步 Apple Photos。",
                }
                fulfill_json(route, {
                    "dismissed": False,
                    "notice": workspace_notice[0],
                })
                return
            dismissed = workspace_notice[0] is not None and (
                workspace_notice[0]["id"] == payload["noticeID"]
            )
            if dismissed:
                workspace_notice[0] = None
            fulfill_json(route, {
                "dismissed": dismissed,
                "notice": workspace_notice[0],
            })

        page.route(
            "**/v1/workspace-notice/dismiss",
            route_workspace_notice_dismiss,
        )
        page.route("**/v1/sources", lambda route: fulfill_json(route, []))
        page.route("**/v1/tags", lambda route: fulfill_json(route, list(tags)))
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(route, [
                {
                    "id": group_id,
                    "displayName": name,
                    "sortOrder": index,
                    "isSystem": True,
                }
                for index, (name, group_id) in enumerate(GROUP_IDS.items())
            ]),
        )
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
        page.route(
            "**/v1/assets?**",
            lambda route: fulfill_json(route, {"items": [], "nextCursor": None}),
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

        def route_source_management(route):
            if route.request.method == "GET":
                fulfill_json(
                    route,
                    {"sources": [], "canConnectPhotos": True, "requests": []},
                )
                return
            payload = route.request.post_data_json
            source_requests.append(payload)
            fulfill_json(
                route,
                {
                    "id": "99999999-9999-9999-9999-999999999999",
                    "operationID": payload["operationID"],
                    "action": payload["action"],
                    "sourceID": None,
                    "sourceDisplayName": None,
                    "phase": "awaitingMac",
                    "message": "请回到 Mac 完成原生确认或系统选择器",
                    "updatedAtMs": 1_700_000_000_000,
                },
                status=202,
            )

        page.route("**/v1/source-management", route_source_management)
        page.route("**/v1/source-management/requests", route_source_management)

        def route_presets(route):
            payload = route.request.post_data_json
            uuid.UUID(payload["operationID"])
            preset_requests.append(payload)
            created = []
            if not tags:
                for index, name in enumerate(PRESET_NAMES):
                    group_name = (
                        "主体" if name in {"人像", "动物", "植物", "建筑"}
                        else "场景" if name in {"风景", "美食"}
                        else "活动" if name == "旅行"
                        else "媒介"
                    )
                    created.append({
                        "id": f"70000000-0000-4000-8000-{index + 1:012d}",
                        "displayName": name,
                        "state": "active",
                        "groupID": GROUP_IDS[group_name],
                    })
                tags.extend(created)
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "createdTags": created,
                    "replayed": False,
                },
            )

        page.route("**/v1/tags/install-presets", route_presets)

        page.goto(BASE_URL, wait_until="networkidle")
        page.locator("#emptyState:not(.hidden)").wait_for()
        page.locator("#workspaceNoticeBanner:not(.hidden)").wait_for(state="visible")
        assert page.locator("#workspaceNoticeBanner").get_attribute("data-severity") == "warning"
        assert page.locator("#workspaceNoticeMessage").inner_text() == (
            "后台扫描未完成，已索引的照片仍可继续浏览。"
        )
        page.locator("#dismissWorkspaceNoticeButton").click()
        page.wait_for_function(
            "() => document.querySelector('#workspaceNoticeMessage').textContent.includes('增量同步')"
        )
        assert notice_dismissals[-1]["noticeID"] == "notice-1"
        assert page.locator("#workspaceNoticeBanner").get_attribute("data-severity") == "success"
        page.locator("#dismissWorkspaceNoticeButton").click()
        page.locator("#workspaceNoticeBanner.hidden").wait_for(state="attached")
        assert notice_dismissals[-1]["noticeID"] == "notice-2"
        assert page.locator("#emptyStateTitle").inner_text() == "开始建立你的照片资料库"
        assert page.locator("#emptyStateActions:not(.hidden) button:not(.hidden)").count() == 3
        assert page.locator("#sidebarInstallPresetTagsButton").is_visible()
        assert page.locator("#sidebarConnectFolderButton").is_visible()
        assert page.locator("#sidebarConnectPhotosButton").is_visible()
        assert page.locator("#sidebarPhotosConnectedStatus").is_hidden()
        assert page.locator("#libraryNavigation .sidebar-row").evaluate_all(
            "rows => rows.slice(0, 5).map(row => row.children[1].textContent.trim())"
        ) == ["图库总览", "照片世界", "全部照片", "红心收藏", "无标签"]
        page.locator("#galleryOverviewNavigationButton").focus()
        page.keyboard.press("ArrowDown")
        assert page.evaluate("document.activeElement?.id") == "worldMapNavigationButton"
        page.keyboard.press("End")
        assert page.evaluate("document.activeElement?.id") == "sidebarConnectPhotosButton"
        page.keyboard.press("ArrowUp")
        assert page.evaluate("document.activeElement?.id") == "sidebarConnectFolderButton"
        page.keyboard.press("Home")
        assert page.evaluate("document.activeElement?.id") == "galleryOverviewNavigationButton"
        assert not preset_requests
        page.screenshot(
            path="/tmp/imageall-onboarding-presets-wide.png",
            full_page=True,
        )

        page.locator("#sidebarConnectFolderButton").click()
        page.locator("#sourceManagerPending").wait_for()
        assert source_requests[-1]["action"] == "connectFolder"
        page.locator("#sourceManagerCloseButton").click()
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceManagerButton'"
        )
        page.evaluate(
            "state.sourceManagement.snapshot.requests = []; renderSourceManagement()"
        )

        page.locator("#sidebarConnectPhotosButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "连接 Apple Photos" in page.locator("#confirmDialogTitle").inner_text()
        assert "平时只读访问" in page.locator("#confirmDialogMessage").inner_text()
        assert page.locator("#confirmActionButton").inner_text() == "继续并请求照片权限"
        photos_request_count = len(source_requests)
        page.locator("#cancelConfirmButton").click()
        assert len(source_requests) == photos_request_count
        page.locator("#sourceConnectPhotosButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#confirmActionButton").click()
        page.locator("#sourceManagerPending").wait_for()
        assert source_requests[-1]["action"] == "connectPhotos"
        page.locator("#sourceManagerCloseButton").click()
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceManagerButton'"
        )
        page.evaluate(
            "state.sourceManagement.snapshot.requests = []; renderSourceManagement()"
        )

        page.locator("#emptyConnectFolderButton").click()
        page.locator("#sourceManagerPending").wait_for()
        assert source_requests[-1]["action"] == "connectFolder"
        page.locator("#sourceManagerCloseButton").click()
        page.evaluate(
            "state.sourceManagement.snapshot.requests = []; renderSourceManagement()"
        )

        page.locator("#emptyInstallPresetTagsButton").click()
        page.wait_for_function(
            "() => document.querySelectorAll('[data-quick-tag-id]').length === 9"
        )
        assert len(preset_requests) == 1
        assert page.locator("#emptyStateTitle").inner_text() == "ImageAll 在原位置读取照片"
        assert page.locator("#emptyInstallPresetTagsButton").is_hidden()
        assert page.locator("#sidebarInstallPresetTagsButton").is_hidden()
        assert page.locator("#toastMessage").inner_text() == "已添加 9 个常用标签"
        assert page.evaluate("() => document.activeElement?.dataset.quickTagId")

        page.locator("#tagManagerButton").click()
        page.locator("#installPresetTagsButton").click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('已全部存在')"
        )
        assert len(preset_requests) == 2
        assert page.locator("#installPresetTagsButton").evaluate(
            "element => element === document.activeElement"
        )
        page.locator("#closeTagManagerButton").click()

        page.locator("#commandButton").click()
        page.locator("#commandSearchInput").fill("添加常用标签")
        assert page.locator('[data-command-id="installPresetTags"]').count() == 1
        page.keyboard.press("Escape")

        page.evaluate(
            """
            () => {
              const photos = {
                id: '11111111-2222-3333-4444-555555555555',
                kind: 'photos',
                displayName: 'Apple Photos',
                state: 'active',
              };
              state.sources = [photos];
              state.sourceManagement.snapshot = {
                sources: [photos],
                canConnectPhotos: false,
                requests: [],
              };
              renderSources();
            }
            """
        )
        assert page.locator("#sidebarConnectFolderButton").is_visible()
        assert page.locator("#sidebarConnectPhotosButton").is_hidden()
        assert page.locator("#sidebarPhotosConnectedStatus").is_visible()
        assert "已连接 Apple Photos" in page.locator(
            "#sidebarPhotosConnectedStatus"
        ).inner_text()
        page.evaluate(
            """
            () => {
              state.sources = [];
              state.sourceManagement.snapshot = {
                sources: [],
                canConnectPhotos: true,
                requests: [],
              };
              renderSources();
            }
            """
        )

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        page.locator("#sidebarToggle").click()
        page.wait_for_timeout(250)
        assert page.evaluate("document.activeElement?.dataset.sourceId") == ""
        sidebar_source_bounds = page.locator("#sidebarSourceActions").bounding_box()
        assert sidebar_source_bounds is not None
        assert sidebar_source_bounds["x"] >= 0
        assert sidebar_source_bounds["x"] + sidebar_source_bounds["width"] <= 390
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        page.screenshot(path="/tmp/imageall-onboarding-presets-synthetic.png", full_page=True)

        assert not page_errors, page_errors
        assert not console_errors, console_errors
        browser.close()

    print(
        "onboarding-presets browser flow passed; "
        f"preset requests={len(preset_requests)}; source requests={len(source_requests)}"
    )


if __name__ == "__main__":
    main()
