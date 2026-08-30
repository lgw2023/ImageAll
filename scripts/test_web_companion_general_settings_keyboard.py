#!/usr/bin/env python3
import json

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8806"
SOURCE_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
FOLDER_SOURCE_ID = "aaaaaaaa-4444-5555-6666-aaaaaaaaaaaa"
CAT_TAG_ID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"
SCENERY_TAG_ID = "bbbbbbbb-4444-5555-6666-bbbbbbbbbbbb"


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def click_toolbar_action(page, target_id):
    original = page.locator(f"#{target_id}")
    if original.is_visible():
        original.click()
        return
    menu = page.locator("#compactToolbarMenu")
    if not menu.is_visible():
        page.locator("#compactToolbarMenuButton").click()
    page.locator(f'[data-compact-toolbar-target="{target_id}"]').click()


def main():
    updates = []
    sample_requests = []
    source_actions = []
    source_requests = []
    source_management_reads = [0]
    catalog_jobs = []
    catalog_job_fetches = [0]
    asset_requests = []
    review_pending_count = 7
    settings = {
        "localModel": {
            "isEnabled": False,
            "state": "disabled",
            "modelName": "DINOv2 Small",
            "runtimeName": "App 内 Core ML（本机）",
            "detail": "模型不会初始化或运行。",
        },
        "idleThumbnailPrewarmEnabled": True,
        "idleThresholdSeconds": 180,
        "toolbarDisplayMode": "iconOnly",
        "maxPendingSuggestionsPerTag": 500,
        "suggestionThresholds": {
            "defaults": [
                {"method": "featureKnn", "minScore": 0.1},
                {"method": "personalCentroid", "minScore": 0.2},
                {"method": "personalAdamW", "minScore": 0.3},
            ],
            "tags": [
                {
                    "tagID": CAT_TAG_ID,
                    "displayName": "猫",
                    "methods": [
                        {
                            "method": "featureKnn",
                            "effectiveMinScore": 0.42,
                            "overrideMinScore": 0.42,
                            "reference": {
                                "minScore": 0.55,
                                "acceptedSampleCount": 8,
                                "rejectedSampleCount": 7,
                            },
                        },
                        {"method": "personalCentroid", "effectiveMinScore": 0.2, "overrideMinScore": None, "reference": None},
                        {"method": "personalAdamW", "effectiveMinScore": 0.3, "overrideMinScore": None, "reference": None},
                    ],
                },
                {
                    "tagID": SCENERY_TAG_ID,
                    "displayName": "风景",
                    "methods": [
                        {"method": "featureKnn", "effectiveMinScore": 0.1, "overrideMinScore": None, "reference": None},
                        {"method": "personalCentroid", "effectiveMinScore": 0.2, "overrideMinScore": None, "reference": None},
                        {"method": "personalAdamW", "effectiveMinScore": 0.3, "overrideMinScore": None, "reference": None},
                    ],
                },
            ],
        },
    }
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
                    "protocolVersion": 2,
                    "hostID": "cccccccc-1111-2222-3333-cccccccccccc",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                    "capabilities": ["generalSettings", "sourceManagement"],
                },
            ),
        )
        sources = [
            {
                "id": SOURCE_ID,
                "kind": "photos",
                "displayName": "Apple Photos",
                "state": "active",
            },
            {
                "id": FOLDER_SOURCE_ID,
                "kind": "folder",
                "displayName": "Synthetic Archive",
                "state": "active",
            },
        ]
        page.route("**/v1/sources", lambda route: fulfill_json(route, sources))
        page.route("**/v1/tags", lambda route: fulfill_json(route, []))
        page.route("**/v1/tag-groups", lambda route: fulfill_json(route, []))
        def route_jobs(route):
            catalog_job_fetches[0] += 1
            if catalog_jobs and catalog_jobs[0]["state"] == "running":
                catalog_jobs[0]["progress"]["completedUnitCount"] = min(
                    9,
                    1 + catalog_job_fetches[0] * 2,
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
        def route_sample_suggestion_request(route):
            payload = route.request.post_data_json
            sample_requests.append(payload)
            fulfill_json(route, {
                "activity": {
                    "operationID": payload["operationID"],
                    "mediaKind": payload["mediaKind"],
                    "phase": "completed",
                    "completedUnitCount": 12,
                    "totalUnitCount": 12,
                    "suggestedCount": 4,
                    "skippedCount": 1,
                    "errorCode": None,
                    "availableActions": [],
                },
                "replayed": False,
            })

        page.route("**/v1/sample-suggestions/requests", route_sample_suggestion_request)
        page.route(
            "**/v1/tag-library-suggestions?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "maximumPendingCount": 500, "personalCentroidAvailable": False, "personalAdamWAvailable": False, "tags": [], "activities": []}),
        )
        def route_assets(route):
            asset_requests.append(route.request.url)
            fulfill_json(route, {"items": [], "nextCursor": None})

        page.route("**/v1/assets?**", route_assets)
        def route_review_overview(route):
            fulfill_json(route, {
                "totalPendingSuggestionCount": review_pending_count,
                "tags": [{
                    "id": CAT_TAG_ID,
                    "displayName": "猫",
                    "acceptedSampleCount": 8,
                    "rejectedSampleCount": 7,
                    "pendingSuggestionCount": review_pending_count,
                    "pendingSuggestionCounts": {
                        "featurePrint": review_pending_count,
                        "standardModel": 0,
                        "personalModel": 0,
                        "personalAdamW": 0,
                    },
                    "taskStatus": "completed",
                    "checkedCount": 40,
                    "totalCount": 40,
                    "skippedCount": 0,
                    "missingPositiveCount": 0,
                    "missingNegativeCount": 0,
                    "canGenerate": True,
                    "canUpdate": True,
                    "canGeneratePersonalModel": True,
                    "canReview": True,
                    "canPause": False,
                    "canResume": False,
                    "canCancel": False,
                    "activeJobID": None,
                }],
            })

        page.route("**/v1/review/overview?**", route_review_overview)

        def route_settings(route):
            nonlocal settings, review_pending_count
            if route.request.method == "GET":
                fulfill_json(route, settings)
                return
            payload = route.request.post_data_json
            updates.append(payload)
            if "toolbarDisplayMode" in payload:
                settings["toolbarDisplayMode"] = payload["toolbarDisplayMode"]
            if "idleThumbnailPrewarmEnabled" in payload:
                settings["idleThumbnailPrewarmEnabled"] = payload["idleThumbnailPrewarmEnabled"]
            if "modelEnabled" in payload:
                enabled = payload["modelEnabled"]
                settings["localModel"] = {
                    **settings["localModel"],
                    "isEnabled": enabled,
                    "state": "ready" if enabled else "disabled",
                    "detail": "模型已在 App 内完成校验并可供本地推理。" if enabled
                    else "模型不会初始化或运行。",
                }
            if "maxPendingSuggestionsPerTag" in payload:
                settings["maxPendingSuggestionsPerTag"] = payload[
                    "maxPendingSuggestionsPerTag"
                ]
            mutation = payload.get("suggestionThresholdMutation")
            if mutation:
                thresholds = settings["suggestionThresholds"]
                method_name = mutation["method"]
                if mutation["action"] == "setDefault":
                    for default in thresholds["defaults"]:
                        if default["method"] == method_name:
                            default["minScore"] = mutation["minScore"]
                    for tag in thresholds["tags"]:
                        for method in tag["methods"]:
                            if method["method"] == method_name and method["overrideMinScore"] is None:
                                method["effectiveMinScore"] = mutation["minScore"]
                else:
                    tag = next(item for item in thresholds["tags"] if item["tagID"] == mutation["tagID"])
                    method = next(item for item in tag["methods"] if item["method"] == method_name)
                    if mutation["action"] == "setOverride":
                        method["overrideMinScore"] = mutation["minScore"]
                        method["effectiveMinScore"] = mutation["minScore"]
                    elif mutation["action"] == "clearOverride":
                        method["overrideMinScore"] = None
                        method["effectiveMinScore"] = next(
                            item["minScore"] for item in thresholds["defaults"]
                            if item["method"] == method_name
                        )
                    elif mutation["action"] == "prune":
                        review_pending_count = 3
            fulfill_json(route, {"settings": settings, "replayed": False})

        page.route("**/v1/settings/general", route_settings)

        def route_source_request(route):
            payload = route.request.post_data_json
            source_actions.append(payload)
            source = next(
                (item for item in sources if item["id"] == payload.get("sourceID")),
                None,
            )
            request = {
                "id": f"99999999-0000-4000-8000-{len(source_actions):012d}",
                "operationID": payload["operationID"],
                "action": payload["action"],
                "sourceID": payload.get("sourceID"),
                "sourceDisplayName": source["displayName"] if source else "全部来源",
                "phase": "completed",
                "message": "Synthetic Mac authorization completed",
                "updatedAtMs": 1_700_000_000_000 + len(source_actions),
            }
            source_requests.insert(0, request)
            if payload["action"] == "refreshAll" and not catalog_jobs:
                catalog_jobs.append({
                    "id": "77777777-0000-4000-8000-777777777777",
                    "sourceID": SOURCE_ID,
                    "sourceDisplayName": "Apple Photos",
                    "kind": "photosReconcile",
                    "state": "running",
                    "progress": {"completedUnitCount": 1, "totalUnitCount": 12},
                    "availableActions": ["pause", "cancel"],
                    "controlRequest": "none",
                })
            fulfill_json(route, request)

        page.route("**/v1/source-management/requests", route_source_request)
        def route_source_management(route):
            source_management_reads[0] += 1
            fulfill_json(
                route,
                {"sources": sources, "canConnectPhotos": False, "requests": source_requests},
            )

        page.route("**/v1/source-management", route_source_management)
        page.route(
            "**/v1/storage-maintenance",
            lambda route: fulfill_json(
                route,
                {
                    "previewCache": {"entryCount": 2, "registeredBytes": 1024},
                    "photosOriginals": {"entryCount": 0, "registeredBytes": 0},
                    "appStorage": {"kind": "internalStorage", "requiresRestart": False},
                    "requests": [],
                },
            ),
        )

        page.goto(BASE_URL, wait_until="networkidle")
        assert page.locator("#appView").get_attribute("data-toolbar-display-mode") == "iconOnly"
        assert page.locator("#currentSourceRefreshLabel").inner_text() == "立即重扫"
        assert page.locator("#refreshButton").get_attribute("aria-label") == "重新读取网页数据"

        page.emulate_media(contrast="more")
        page.wait_for_timeout(200)
        assert page.evaluate("() => matchMedia('(prefers-contrast: more)').matches") is True
        contrast_presentation = page.evaluate(
            """() => {
              const root = getComputedStyle(document.documentElement);
              const command = document.querySelector('#commandButton');
              command.focus();
              const focused = getComputedStyle(command);
              return {
                separator: root.getPropertyValue('--separator').trim(),
                selection: root.getPropertyValue('--selection').trim(),
                outlineWidth: focused.outlineWidth,
                outlineStyle: focused.outlineStyle,
              };
            }"""
        )
        assert contrast_presentation == {
            "separator": "rgba(60, 60, 67, 0.52)",
            "selection": "rgba(0, 122, 255, 0.3)",
            "outlineWidth": "3px",
            "outlineStyle": "solid",
        }, contrast_presentation
        page.screenshot(path="/tmp/imageall-increased-contrast.png", full_page=True)

        page.emulate_media(color_scheme="dark", contrast="more")
        page.wait_for_timeout(200)
        dark_contrast_presentation = page.evaluate(
            """() => {
              const root = getComputedStyle(document.documentElement);
              const action = getComputedStyle(document.querySelector('#worldMapButton'));
              const icon = getComputedStyle(document.querySelector('#jobsButton .library-toolbar-icon'));
              return {
                separator: root.getPropertyValue('--separator').trim(),
                selection: root.getPropertyValue('--selection').trim(),
                secondary: root.getPropertyValue('--secondary').trim(),
                control: root.getPropertyValue('--control').trim(),
                actionBackground: action.backgroundColor,
                actionColor: action.color,
                iconColor: icon.color,
              };
            }"""
        )
        assert dark_contrast_presentation == {
            "separator": "rgba(235, 235, 245, 0.48)",
            "selection": "rgba(10, 132, 255, 0.38)",
            "secondary": "#d1d1d6",
            "control": "rgba(72, 72, 74, 0.96)",
            "actionBackground": "rgba(72, 72, 74, 0.96)",
            "actionColor": "rgb(245, 245, 247)",
            "iconColor": "rgb(209, 209, 214)",
        }, dark_contrast_presentation
        page.screenshot(path="/tmp/imageall-increased-contrast-dark.png", full_page=True)

        page.emulate_media(
            color_scheme="light",
            contrast="no-preference",
            forced_colors="active",
        )
        page.wait_for_timeout(200)
        assert page.evaluate("() => matchMedia('(forced-colors: active)').matches") is True
        forced_color_presentation = page.evaluate(
            """() => {
              const root = getComputedStyle(document.documentElement);
              const command = document.querySelector('#commandButton');
              command.focus();
              const focused = getComputedStyle(command);
              return {
                window: root.getPropertyValue('--window').trim(),
                text: root.getPropertyValue('--text').trim(),
                separator: root.getPropertyValue('--separator').trim(),
                outlineWidth: focused.outlineWidth,
                outlineStyle: focused.outlineStyle,
                boxShadow: focused.boxShadow,
              };
            }"""
        )
        assert forced_color_presentation == {
            "window": "Canvas",
            "text": "CanvasText",
            "separator": "ButtonBorder",
            "outlineWidth": "3px",
            "outlineStyle": "solid",
            "boxShadow": "none",
        }, forced_color_presentation
        page.screenshot(path="/tmp/imageall-forced-colors.png", full_page=True)
        page.emulate_media(
            color_scheme="light",
            contrast="no-preference",
            forced_colors="none",
        )

        page.locator("#commandButton").hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        assert page.locator("#persistentHelpTitle").inner_text() == "命令（⌘K）"
        assert "当前工作区" in page.locator("#persistentHelpDetail").inner_text()
        assert "persistentHelp" in (
            page.locator("#commandButton").get_attribute("aria-describedby") or ""
        )
        assert page.locator("#commandButton").get_attribute("title") is None
        help_geometry = page.evaluate(
            """() => {
              const anchor = document.querySelector('#commandButton').getBoundingClientRect();
              const help = document.querySelector('#persistentHelp').getBoundingClientRect();
              return {
                viewportWidth: innerWidth,
                viewportHeight: innerHeight,
                left: help.left,
                right: help.right,
                top: help.top,
                bottom: help.bottom,
                separated: help.top >= anchor.bottom || help.bottom <= anchor.top,
              };
            }"""
        )
        assert help_geometry["left"] >= 8, help_geometry
        assert help_geometry["right"] <= help_geometry["viewportWidth"] - 8, help_geometry
        assert help_geometry["top"] >= 8, help_geometry
        assert help_geometry["bottom"] <= help_geometry["viewportHeight"] - 8, help_geometry
        assert help_geometry["separated"], help_geometry
        page.screenshot(path="/tmp/imageall-persistent-help-synthetic.png", full_page=True)
        page.mouse.move(720, 420)
        page.locator("#persistentHelp").wait_for(state="hidden")
        assert page.locator("#commandButton").get_attribute("title") == "命令（⌘K）"
        assert "persistentHelp" not in (
            page.locator("#commandButton").get_attribute("aria-describedby") or ""
        )

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_function(
            "() => document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        page.locator("#commandButton").hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=2_000)
        narrow_help_geometry = page.evaluate(
            """() => {
              const help = document.querySelector('#persistentHelp').getBoundingClientRect();
              return {
                viewportWidth: innerWidth,
                viewportHeight: innerHeight,
                left: help.left,
                right: help.right,
                top: help.top,
                bottom: help.bottom,
              };
            }"""
        )
        assert narrow_help_geometry["left"] >= 8, narrow_help_geometry
        assert narrow_help_geometry["right"] <= narrow_help_geometry["viewportWidth"] - 8, (
            narrow_help_geometry
        )
        assert narrow_help_geometry["top"] >= 8, narrow_help_geometry
        assert narrow_help_geometry["bottom"] <= narrow_help_geometry["viewportHeight"] - 8, (
            narrow_help_geometry
        )
        page.screenshot(path="/tmp/imageall-persistent-help-390.png", full_page=True)
        page.mouse.move(195, 420)
        page.locator("#persistentHelp").wait_for(state="hidden")
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_function(
            "() => !document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )

        page.locator("#sidebarVisibilityButton").focus()
        page.keyboard.press("Tab")
        page.wait_for_function("() => document.activeElement?.id === 'commandButton'")
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=1_000)
        page.keyboard.press("Escape")
        page.locator("#persistentHelp").wait_for(state="hidden")
        assert page.locator("#commandButton").get_attribute("title") == "命令（⌘K）"

        source_actions_read_count = source_management_reads[0]
        source_actions_asset_count = len(asset_requests)
        source_actions_action_count = len(source_actions)
        source_heading_bounds = page.locator("#sourceSectionHeading").bounding_box()
        assert source_heading_bounds is not None
        source_heading_context_point = {
            "x": source_heading_bounds["x"] + 42,
            "y": source_heading_bounds["y"] + 12,
        }
        page.locator("#sourceSectionHeading").click(
            button="right", position={"x": 42, "y": 12}
        )
        page.locator("#sourceActionsPopover:not(.hidden)").wait_for()
        source_actions_context_bounds = page.locator("#sourceActionsPopover").bounding_box()
        assert source_actions_context_bounds is not None
        assert abs(
            source_actions_context_bounds["x"] - source_heading_context_point["x"]
        ) <= 1
        assert abs(
            source_actions_context_bounds["y"] - source_heading_context_point["y"]
        ) <= 1
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceActionsViewAllButton'"
        )
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.context?.actionMenuKind"
        ) == "sourceActions"
        page.keyboard.press("Escape")
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceAllActionsButton'"
        )
        page.locator("#sourceAllActionsButton").press("Shift+F10")
        page.locator("#sourceActionsPopover:not(.hidden)").wait_for()
        page.keyboard.press("Escape")
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        page.locator("#sourceAllActionsButton").press("ContextMenu")
        page.locator("#sourceActionsPopover:not(.hidden)").wait_for()
        page.keyboard.press("Escape")
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        assert source_management_reads[0] == source_actions_read_count
        assert len(asset_requests) == source_actions_asset_count
        assert len(source_actions) == source_actions_action_count

        source_actions_history_length = page.evaluate("history.length")
        source_actions_read_count = source_management_reads[0]
        page.locator("#sourceAllActionsButton").click()
        page.locator("#sourceActionsPopover:not(.hidden)").wait_for()
        assert page.evaluate("history.length") in {
            source_actions_history_length,
            source_actions_history_length + 1,
        }
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "actionMenu"
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.context?.actionMenuKind"
        ) == "sourceActions"
        assert source_management_reads[0] == source_actions_read_count
        assert "2 个已连接来源" in page.locator("#sourceActionsSummary").inner_text()
        assert page.locator("#sourceActionsViewAllButton").is_enabled()
        assert "（0）" in page.locator("#sourceActionsReauthorizeAllButton").inner_text()
        assert "（1）" in page.locator("#sourceActionsRefreshMutationButton").inner_text()
        assert page.locator("#sourceActionsPhotosWriteButton").is_visible()
        page.screenshot(path="/tmp/imageall-source-actions-menu.png", full_page=True)
        page.locator("#sourceActionsPopover").evaluate(
            "menu => { menu.style.maxHeight = '170px'; menu.scrollTop = menu.scrollHeight; }"
        )
        page.locator("#sourceActionsOpenManagerButton").focus()
        source_actions_scroll_top = page.locator("#sourceActionsPopover").evaluate(
            "menu => menu.scrollTop"
        )
        assert source_actions_scroll_top > 0
        source_actions_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "sourceActionsOpenManagerButton" not in source_actions_history_payload
        assert "Apple Photos" not in source_actions_history_payload
        page.evaluate("history.back()")
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        assert page.evaluate("document.activeElement?.id") == "sourceAllActionsButton"
        page.evaluate("history.forward()")
        page.locator("#sourceActionsPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceActionsOpenManagerButton'"
        )
        assert page.locator("#sourceActionsPopover").evaluate(
            "menu => menu.scrollTop"
        ) == source_actions_scroll_top
        assert source_management_reads[0] == source_actions_read_count
        page.keyboard.press("Home")
        assert page.evaluate(
            "document.activeElement?.id"
        ) == "sourceActionsViewAllButton"
        page.keyboard.press("End")
        assert page.evaluate(
            "document.activeElement?.id"
        ) == "sourceActionsOpenManagerButton"
        page.keyboard.press("Escape")
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceAllActionsButton'"
        )
        page.locator("#sourceActionsPopover").evaluate(
            "menu => { menu.style.maxHeight = ''; }"
        )

        page.evaluate(
            "() => { state.online = false; syncWriteActionControls(); renderSourceActionsMenu(); }"
        )
        assert page.locator("#sourceAllActionsButton").is_enabled()
        assert "仍可返回全部照片" in page.locator("#sourceAllActionsButton").get_attribute(
            "title"
        )
        page.locator("#sourceAllActionsButton").click()
        assert page.locator("#sourceActionsViewAllButton").is_enabled()
        assert page.locator("#sourceActionsRefreshAllButton").is_disabled()
        page.keyboard.press("Escape")
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        page.evaluate(
            "() => { state.online = true; syncWriteActionControls(); renderSourceActionsMenu(); }"
        )

        page.locator("#sourceAllActionsButton").click()
        page.locator("#sourceActionsOpenManagerButton").click()
        page.locator("#sourceManagerDialog[open]").wait_for()
        assert page.locator("#sourceActionsPopover").is_hidden()
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "sourceManager"
        assert source_management_reads[0] == source_actions_read_count
        page.evaluate("history.back()")
        page.locator("#sourceManagerDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceAllActionsButton'"
        )

        page.locator("#sourceAllActionsButton").click()
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as prewarm_all_originals:
            page.locator("#sourceActionsPrewarmAllOriginalButton").click()
        assert prewarm_all_originals.value.status == 200
        assert source_actions[-1]["action"] == "prewarmAllOriginalAspect"
        assert source_actions[-1]["sourceID"] is None
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "workspace"
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceAllActionsButton'"
        )

        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as refresh_all_sources:
            click_toolbar_action(page, "currentSourceRefreshButton")
        assert refresh_all_sources.value.status == 200
        assert source_actions[-1]["action"] == "refreshAll"
        assert source_actions[-1]["sourceID"] is None
        page.locator("#catalogProgressStatusButton:not(.hidden)").wait_for()
        first_progress_label = page.locator("#catalogProgressStatusLabel").inner_text()
        page.wait_for_function(
            "previous => document.querySelector('#catalogProgressStatusLabel')?.textContent !== previous",
            arg=first_progress_label,
        )
        assert "Apple Photos" in page.locator("#catalogProgressStatusLabel").inner_text()
        assert len(asset_requests) == 1, asset_requests
        page.screenshot(path="/tmp/imageall-catalog-progress-wide.png", full_page=True)
        page.set_viewport_size({"width": 820, "height": 844})
        page.wait_for_function(
            "() => document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        adaptive_metrics = page.evaluate(
            """() => ({
              required: Number(document.querySelector('#appView').dataset.toolbarRequiredWidth),
              available: Number(document.querySelector('#appView').dataset.toolbarAvailableWidth),
              scroll: document.documentElement.scrollWidth,
              viewport: innerWidth,
            })"""
        )
        assert adaptive_metrics["required"] > adaptive_metrics["available"] - 28, (
            adaptive_metrics
        )
        assert adaptive_metrics["scroll"] <= adaptive_metrics["viewport"], adaptive_metrics
        assert page.locator("#sidebarVisibilityButton").is_visible()
        assert page.locator(".titlebar-leading .mini-mark").is_visible()
        assert page.locator("#compactToolbarMenuButton").is_visible()
        assert not page.locator("#catalogProgressStatusButton").is_visible()
        page.screenshot(path="/tmp/imageall-adaptive-toolbar-820.png", full_page=True)
        page.locator("#compactToolbarMenuButton").click()
        page.wait_for_function(
            "() => document.activeElement?.dataset.compactToolbarTarget === 'catalogProgressStatusButton'"
        )
        page.set_viewport_size({"width": 1440, "height": 844})
        page.wait_for_function(
            "() => !document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        assert page.locator("#compactToolbarMenu").is_hidden()
        page.wait_for_function("() => document.activeElement?.id === 'commandButton'")
        page.set_viewport_size({"width": 820, "height": 844})
        page.wait_for_function(
            "() => document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_function(
            "() => document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        for selector in [
            "#commandButton",
            "#jobsButton",
            "#connectionStatus",
            "#compactToolbarMenuButton",
        ]:
            bounds = page.locator(selector).bounding_box()
            assert bounds is not None
            assert bounds["x"] >= 0
            assert bounds["x"] + bounds["width"] <= 390
        assert not page.locator("#catalogProgressStatusButton").is_visible()
        assert not page.locator("#settingsButton").is_visible()
        assert page.locator("#compactToolbarActivityDot").is_visible()
        assert "正在进行" in page.locator("#compactToolbarMenuButton").get_attribute(
            "aria-label"
        )
        compact_menu_history_length = page.evaluate("history.length")
        compact_menu_asset_request_count = len(asset_requests)
        page.locator("#compactToolbarMenuButton").click()
        page.locator("#compactToolbarMenu:not(.hidden)").wait_for()
        assert page.evaluate("history.length") == compact_menu_history_length + 1
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "toolbarMenu"
        assert page.locator("#compactToolbarMenuButton").get_attribute(
            "aria-expanded"
        ) == "true"
        menu_bounds = page.locator("#compactToolbarMenu").bounding_box()
        assert menu_bounds is not None
        assert menu_bounds["x"] >= 0
        assert menu_bounds["x"] + menu_bounds["width"] <= 390
        catalog_menu_item = page.locator(
            '[data-compact-toolbar-target="catalogProgressStatusButton"]'
        )
        assert catalog_menu_item.is_visible()
        assert "Apple Photos" in catalog_menu_item.inner_text()
        page.wait_for_function(
            "() => document.activeElement?.dataset.compactToolbarTarget "
            "=== 'catalogProgressStatusButton'"
        )
        compact_settings = page.locator(
            '[data-compact-toolbar-target="settingsButton"]'
        )
        compact_settings.hover()
        compact_settings.focus()
        compact_continuity = page.evaluate(
            """() => {
              const content = document.querySelector("#compactToolbarMenuContent");
              content.scrollTop = Math.min(
                Math.max(1, content.scrollHeight - content.clientHeight),
                140
              );
              const settings = content.querySelector(
                '[data-compact-toolbar-target="settingsButton"]'
              );
              const connect = content.querySelector(
                '[data-compact-toolbar-target="toolbarConnectFolderButton"]'
              );
              const refresh = content.querySelector(
                '[data-compact-toolbar-target="currentSourceRefreshButton"]'
              );
              const observerState = { childList: 0 };
              const observer = new MutationObserver((records) => {
                observerState.childList += records.filter(
                  (record) => record.type === "childList"
                ).length;
              });
              observer.observe(content, { childList: true, subtree: true });
              globalThis.__compactToolbarContinuity = {
                content,
                statusSection: content.querySelector(
                  '[data-compact-toolbar-section="status"]'
                ),
                settingsSection: content.querySelector(
                  '[data-compact-toolbar-section="settings"]'
                ),
                settings,
                settingsIcon: settings.querySelector(
                  '[data-compact-toolbar-part="icon"]'
                ),
                settingsLabel: settings.querySelector(
                  '[data-compact-toolbar-part="label"]'
                ),
                settingsDetail: settings.querySelector(
                  '[data-compact-toolbar-part="detail"]'
                ),
                connect,
                refresh,
                scrollTop: content.scrollTop,
                observer,
                observerState,
              };
              return {
                scrollTop: content.scrollTop,
                settingsHovered: settings.matches(":hover"),
              };
            }"""
        )
        assert compact_continuity["scrollTop"] > 0, compact_continuity
        assert compact_continuity["settingsHovered"]
        page.evaluate("() => setConnection(false, 'Mac 离线')")
        page.wait_for_function(
            "() => document.activeElement?.dataset.compactToolbarTarget === 'settingsButton'"
        )
        compact_offline = page.evaluate(
            """() => {
              const saved = globalThis.__compactToolbarContinuity;
              const content = document.querySelector("#compactToolbarMenuContent");
              const settings = content.querySelector(
                '[data-compact-toolbar-target="settingsButton"]'
              );
              const connect = content.querySelector(
                '[data-compact-toolbar-target="toolbarConnectFolderButton"]'
              );
              const refresh = content.querySelector(
                '[data-compact-toolbar-target="currentSourceRefreshButton"]'
              );
              return {
                content: saved.content === content,
                statusSection: saved.statusSection === content.querySelector(
                  '[data-compact-toolbar-section="status"]'
                ),
                settingsSection: saved.settingsSection === content.querySelector(
                  '[data-compact-toolbar-section="settings"]'
                ),
                settings: saved.settings === settings,
                settingsIcon: saved.settingsIcon === settings.querySelector(
                  '[data-compact-toolbar-part="icon"]'
                ),
                settingsLabel: saved.settingsLabel === settings.querySelector(
                  '[data-compact-toolbar-part="label"]'
                ),
                settingsDetail: saved.settingsDetail === settings.querySelector(
                  '[data-compact-toolbar-part="detail"]'
                ),
                connect: saved.connect === connect,
                refresh: saved.refresh === refresh,
                connectDisabled: connect.disabled,
                refreshDisabled: refresh.disabled,
                settingsHovered: settings.matches(":hover"),
                scrollTop: content.scrollTop,
                childList: saved.observerState.childList,
              };
            }"""
        )
        assert compact_offline == {
            "content": True,
            "statusSection": True,
            "settingsSection": True,
            "settings": True,
            "settingsIcon": True,
            "settingsLabel": True,
            "settingsDetail": True,
            "connect": True,
            "refresh": True,
            "connectDisabled": True,
            "refreshDisabled": True,
            "settingsHovered": True,
            "scrollTop": compact_continuity["scrollTop"],
            "childList": 0,
        }, compact_offline
        page.evaluate("() => setConnection(true, '已连接 Mac')")
        page.wait_for_function(
            "() => document.activeElement?.dataset.compactToolbarTarget === 'settingsButton'"
        )
        compact_online = page.evaluate(
            """() => {
              const saved = globalThis.__compactToolbarContinuity;
              const content = document.querySelector("#compactToolbarMenuContent");
              const settings = content.querySelector(
                '[data-compact-toolbar-target="settingsButton"]'
              );
              const connect = content.querySelector(
                '[data-compact-toolbar-target="toolbarConnectFolderButton"]'
              );
              const refresh = content.querySelector(
                '[data-compact-toolbar-target="currentSourceRefreshButton"]'
              );
              saved.observer.disconnect();
              return {
                settings: saved.settings === settings,
                connect: saved.connect === connect,
                refresh: saved.refresh === refresh,
                connectDisabled: connect.disabled,
                refreshDisabled: refresh.disabled,
                settingsHovered: settings.matches(":hover"),
                scrollTop: content.scrollTop,
                childList: saved.observerState.childList,
              };
            }"""
        )
        assert compact_online == {
            "settings": True,
            "connect": True,
            "refresh": True,
            "connectDisabled": False,
            "refreshDisabled": False,
            "settingsHovered": True,
            "scrollTop": compact_continuity["scrollTop"],
            "childList": 0,
        }, compact_online
        page.locator(
            '[data-compact-toolbar-target="catalogProgressStatusButton"]'
        ).focus()
        page.keyboard.press("Meta+f")
        assert page.locator("#compactToolbarMenu").is_visible()
        assert page.evaluate(
            "() => document.activeElement?.closest('#compactToolbarMenu') !== null"
        )
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.compactToolbarTarget"
        ) == "logoutButton"
        page.keyboard.press("Tab")
        assert page.evaluate(
            "() => document.activeElement?.closest('#compactToolbarMenu') !== null"
        )
        page.keyboard.press("Home")
        assert page.evaluate(
            "() => document.activeElement?.dataset.compactToolbarTarget"
        ) == "catalogProgressStatusButton"
        page.screenshot(path="/tmp/imageall-compact-toolbar-390.png", full_page=True)
        page.keyboard.press("Enter")
        page.locator("#jobsPopover:not(.hidden)").wait_for()
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "jobs"
        jobs_history = page.evaluate("() => JSON.stringify(history.state)")
        assert "77777777-0000-4000-8000-777777777777" not in jobs_history
        assert "photosReconcile" not in jobs_history
        assert "Apple Photos · 照片图库同步" in page.locator("#jobsList").inner_text()
        page.wait_for_function(
            "() => document.activeElement?.dataset.jobRowId "
            "=== '77777777-0000-4000-8000-777777777777'"
        )
        jobs_settings_history_length = page.evaluate("history.length")
        jobs_settings_fetches = catalog_job_fetches[0]
        with page.expect_response("**/v1/settings/general", timeout=3000):
            page.keyboard.press("Meta+,")
        page.locator("#generalSettingsDialog[open]").wait_for()
        assert page.locator("#jobsPopover:not(.hidden)").is_visible()
        assert page.evaluate("history.length") == jobs_settings_history_length + 1
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "generalSettings"
        page.screenshot(
            path="/tmp/imageall-settings-over-activity-390.png",
            full_page=True,
        )
        page.keyboard.press("Escape")
        page.locator("#generalSettingsDialog").wait_for(state="hidden")
        page.locator("#jobsPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.navigationLevel === 'jobs' "
            "&& document.activeElement?.dataset.jobRowId "
            "=== '77777777-0000-4000-8000-777777777777'"
        )
        assert catalog_job_fetches[0] == jobs_settings_fetches
        page.locator("#closeJobsButton").click()
        page.locator("#jobsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'compactToolbarMenuButton'"
        )
        catalog_jobs[0]["state"] = "completed"
        page.evaluate("() => refreshJobs({ announce: false, indicateBusy: false })")
        page.locator("#catalogProgressStatusButton").wait_for(state="hidden")
        assert not page.locator("#compactToolbarActivityDot").is_visible()
        page.locator("#compactToolbarMenuButton").click()
        assert page.locator(
            '[data-compact-toolbar-target="currentSourceRefreshButton"]'
        ).is_visible()
        page.evaluate("history.back()")
        page.locator("#compactToolbarMenu").wait_for(state="hidden")
        assert page.evaluate("document.activeElement?.id") == "compactToolbarMenuButton"
        page.evaluate("history.forward()")
        page.locator("#compactToolbarMenu:not(.hidden)").wait_for()
        page.keyboard.press("Escape")
        page.locator("#compactToolbarMenu").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'compactToolbarMenuButton'"
        )
        page.evaluate("history.forward()")
        page.locator("#compactToolbarMenu:not(.hidden)").wait_for()
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_function(
            "() => !document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        page.locator("#compactToolbarMenu").wait_for(state="hidden")
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "workspace"
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_function(
            "() => document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        assert len(asset_requests) == compact_menu_asset_request_count
        page.screenshot(path="/tmp/imageall-source-refresh-390.png", full_page=True)

        mobile_sidebar_preference = page.evaluate("() => state.layout.sidebarVisible")
        page.locator("#compactToolbarMenuButton").focus()
        page.keyboard.press("Meta+k")
        page.locator("#commandPalette[open]").wait_for()
        command_keyboard_frame = page.evaluate(
            """() => {
              const list = document.querySelector("#commandList");
              const items = [...list.querySelectorAll("[data-command-id]")];
              const untouched = items.find(
                item => item.dataset.commandId === "connectFolder"
              );
              const untouchedMutations = [];
              const untouchedObserver = new MutationObserver(
                records => untouchedMutations.push(...records)
              );
              untouchedObserver.observe(untouched, {
                attributes: true,
                characterData: true,
                childList: true,
                subtree: true,
              });
              window.__commandKeyboardFrame = {
                list,
                items: new Map(items.map((item) => [item.dataset.commandId, item])),
                activeID: list.querySelector(".command-item.active")?.dataset.commandId,
                input: document.querySelector("#commandSearchInput"),
                untouchedObserver,
                untouchedMutations,
              };
              return { itemCount: items.length };
            }"""
        )
        assert command_keyboard_frame["itemCount"] > 2
        page.keyboard.press("ArrowDown")
        command_keyboard_continuity = page.evaluate(
            """() => {
              const frame = window.__commandKeyboardFrame;
              const list = document.querySelector("#commandList");
              const items = [...list.querySelectorAll("[data-command-id]")];
              const activeID = list.querySelector(".command-item.active")?.dataset.commandId;
              frame.untouchedMutations.push(...frame.untouchedObserver.takeRecords());
              frame.untouchedObserver.disconnect();
              return {
                list: list === frame.list,
                items: items.length === frame.items.size
                  && items.every((item) => frame.items.get(item.dataset.commandId) === item),
                moved: Boolean(activeID) && activeID !== frame.activeID,
                selected: items.filter(
                  item => item.getAttribute("aria-selected") === "true"
                ).length === 1,
                untouched: frame.untouchedMutations.length === 0,
                focus: document.activeElement === frame.input,
              };
            }"""
        )
        assert all(command_keyboard_continuity.values()), command_keyboard_continuity
        command_keyboard_accessibility = page.evaluate(
            """() => {
              const input = document.querySelector("#commandSearchInput");
              const active = document.querySelector("#commandList .command-item.active");
              return {
                role: input.getAttribute("role") === "combobox",
                controls: input.getAttribute("aria-controls") === "commandList",
                autocomplete: input.getAttribute("aria-autocomplete") === "list",
                expanded: input.getAttribute("aria-expanded") === "true",
                activeID: Boolean(active?.id)
                  && input.getAttribute("aria-activedescendant") === active.id,
              };
            }"""
        )
        assert all(command_keyboard_accessibility.values()), (
            command_keyboard_accessibility
        )
        page.locator("#commandSearchInput").fill("连接文件夹")
        command_filter_frame = page.evaluate(
            """() => {
              const frame = window.__commandKeyboardFrame;
              const item = document.querySelector('[data-command-id="connectFolder"]');
              window.__commandFilterFrame = { item };
              return {
                item: item === frame.items.get("connectFolder"),
                onlyMatch: document.querySelectorAll("#commandList [data-command-id]").length
                  === 1,
                enabled: !item.disabled,
                focus: document.activeElement === frame.input,
              };
            }"""
        )
        assert all(command_filter_frame.values()), command_filter_frame
        page.evaluate("() => setConnection(false, 'Mac 离线')")
        command_offline_frame = page.evaluate(
            """() => {
              const frame = window.__commandFilterFrame;
              const item = document.querySelector('[data-command-id="connectFolder"]');
              return {
                item: item === frame.item,
                disabled: item.disabled && item.getAttribute("aria-disabled") === "true",
                visuallyMuted: Number.parseFloat(getComputedStyle(item).opacity) < 1,
                focus: document.activeElement?.id === "commandSearchInput",
              };
            }"""
        )
        assert all(command_offline_frame.values()), command_offline_frame
        page.screenshot(
            path="/tmp/imageall-command-palette-continuity.png",
            full_page=True,
        )
        page.evaluate("() => setConnection(true, '已连接')")
        assert page.evaluate(
            """() => {
              const item = document.querySelector('[data-command-id="connectFolder"]');
              return item === window.__commandFilterFrame.item && !item.disabled;
            }"""
        )
        page.locator("#commandSearchInput").fill("")
        sidebar_command = page.locator('[data-command-id="toggleSidebar"]')
        assert "显示侧栏" in sidebar_command.inner_text()
        sidebar_command.click()
        page.locator("#sourceSidebar.open").wait_for()
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.navigationLevel === 'sidebar'"
        )
        assert page.evaluate("() => state.layout.sidebarVisible") == mobile_sidebar_preference
        assert page.evaluate("() => document.activeElement?.closest('#sourceSidebar') !== null")

        page.keyboard.press("Meta+k")
        page.locator("#commandPalette[open]").wait_for()
        sidebar_command = page.locator('[data-command-id="toggleSidebar"]')
        assert "隐藏侧栏" in sidebar_command.inner_text()
        page.screenshot(
            path="/tmp/imageall-mobile-sidebar-command-390.png",
            full_page=True,
        )
        sidebar_command.click()
        page.wait_for_function(
            "() => !document.querySelector('#sourceSidebar').classList.contains('open') "
            "&& history.state?.imageAllWorkspace?.navigationLevel === 'workspace'"
        )
        page.wait_for_function(
            "() => document.activeElement?.id === 'compactToolbarMenuButton'"
        )
        assert page.evaluate("() => state.layout.sidebarVisible") == mobile_sidebar_preference
        assert len(asset_requests) == compact_menu_asset_request_count

        drawer_history_length = page.evaluate("history.length")
        drawer_asset_request_count = len(asset_requests)
        page.locator("#sidebarToggle").click()
        page.locator("#sourceSidebar.open").wait_for()
        page.locator("#mobileSidebarScrim:not(.hidden)").wait_for()
        assert page.locator("#sidebarToggle").get_attribute("aria-expanded") == "true"
        assert page.locator("#libraryPane").get_attribute("inert") == ""
        assert page.locator("#inspector").get_attribute("inert") == ""
        assert page.evaluate("document.activeElement?.closest('#sourceSidebar') !== null")
        assert page.evaluate("history.length") <= drawer_history_length + 1
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "sidebar"
        page.wait_for_timeout(220)
        page.screenshot(path="/tmp/imageall-mobile-sidebar-open-390.png", full_page=True)
        page.locator("#sourceAllActionsButton").click()
        page.locator("#sourceActionsPopover:not(.hidden)").wait_for()
        mobile_source_actions_bounds = page.locator(
            "#sourceActionsPopover"
        ).bounding_box()
        assert mobile_source_actions_bounds is not None
        assert mobile_source_actions_bounds["x"] >= 8
        assert mobile_source_actions_bounds["x"] + mobile_source_actions_bounds["width"] <= 382
        assert mobile_source_actions_bounds["y"] >= 8
        assert mobile_source_actions_bounds["y"] + mobile_source_actions_bounds["height"] <= 836
        page.screenshot(path="/tmp/imageall-source-actions-menu-390.png", full_page=True)
        page.keyboard.press("Escape")
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        assert page.locator("#sourceSidebar").get_attribute("class").find("open") >= 0
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceAllActionsButton'"
        )
        page.evaluate("history.forward()")
        page.locator("#sourceActionsPopover:not(.hidden)").wait_for()
        assert "open" in (page.locator("#sourceSidebar").get_attribute("class") or "")
        page.keyboard.press("Escape")
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        assert "open" in (page.locator("#sourceSidebar").get_attribute("class") or "")
        mobile_view_all_asset_count = len(asset_requests)
        mobile_view_all_action_count = len(source_actions)
        source_heading_bounds = page.locator("#sourceSectionHeading").bounding_box()
        assert source_heading_bounds is not None
        source_heading_long_press_point = {
            "x": source_heading_bounds["x"] + min(42, source_heading_bounds["width"] / 2),
            "y": source_heading_bounds["y"] + source_heading_bounds["height"] / 2,
        }
        page.evaluate(
            """({ point }) => {
              const heading = document.querySelector('#sourceSectionHeading');
              heading.dispatchEvent(new PointerEvent('pointerdown', {
                bubbles: true,
                pointerId: 93,
                pointerType: 'touch',
                button: 0,
                clientX: point.x,
                clientY: point.y,
                isPrimary: true,
              }));
            }""",
            {"point": source_heading_long_press_point},
        )
        page.wait_for_timeout(580)
        page.locator("#sourceActionsPopover:not(.hidden)").wait_for()
        assert not page.locator("#sourceSectionHeading").evaluate(
            "heading => heading.classList.contains('context-long-press-active')"
        )
        page.evaluate(
            """({ point }) => {
              document.querySelector('#sourceSectionHeading').dispatchEvent(
                new PointerEvent('pointerup', {
                  bubbles: true,
                  pointerId: 93,
                  pointerType: 'touch',
                  button: 0,
                  clientX: point.x,
                  clientY: point.y,
                  isPrimary: true,
                })
              );
            }""",
            {"point": source_heading_long_press_point},
        )
        page.locator("#sourceActionsViewAllButton").click()
        page.locator("#sourceActionsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "() => !document.querySelector('#sourceSidebar').classList.contains('open')"
        )
        page.wait_for_function(
            "() => document.activeElement?.id === 'sidebarToggle'"
            " && history.state?.imageAllWorkspace?.navigationLevel === 'workspace'"
        )
        assert len(asset_requests) == mobile_view_all_asset_count
        assert len(source_actions) == mobile_view_all_action_count
        page.locator("#sidebarToggle").click()
        page.locator("#sourceSidebar.open").wait_for()
        page.evaluate(
            """() => {
              const focusable = [...document.querySelectorAll(
                '#sourceSidebar button:not(:disabled), #sourceSidebar input:not(:disabled)'
              )].filter((node) => node.getClientRects().length > 0);
              focusable.at(-1)?.focus();
            }"""
        )
        page.keyboard.press("Tab")
        assert page.evaluate("document.activeElement?.closest('#sourceSidebar') !== null")
        page.locator("#mobileSidebarScrim").click(position={"x": 370, "y": 200})
        page.wait_for_function(
            "() => !document.querySelector('#sourceSidebar').classList.contains('open')"
        )
        assert page.locator("#mobileSidebarScrim").is_hidden()
        assert page.locator("#libraryPane").get_attribute("inert") is None
        assert page.evaluate("document.activeElement?.id") == "sidebarToggle"
        page.evaluate("history.forward()")
        page.locator("#sourceSidebar.open").wait_for()
        page.locator("#mobileSidebarScrim:not(.hidden)").wait_for()
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => !document.querySelector('#sourceSidebar').classList.contains('open')"
        )
        assert page.evaluate("document.activeElement?.id") == "sidebarToggle"
        page.screenshot(path="/tmp/imageall-mobile-sidebar-history-390.png", full_page=True)

        page.evaluate("history.forward()")
        page.locator("#sourceSidebar.open").wait_for()
        page.set_viewport_size({"width": 820, "height": 844})
        page.wait_for_function(
            "() => !document.querySelector('#sourceSidebar').classList.contains('open')"
        )
        assert page.locator("#mobileSidebarScrim").is_hidden()
        assert page.locator("#sourceSidebar").get_attribute("inert") is None
        assert page.locator("#libraryPane").get_attribute("inert") is None
        assert page.locator("#inspector").get_attribute("inert") is None
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "workspace"
        assert len(asset_requests) == drawer_asset_request_count

        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_function(
            "() => !document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        assert page.locator("#currentSourceRefreshButton").is_visible()
        assert not page.locator("#compactToolbarMenuButton").is_visible()
        page.evaluate(
            "() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))"
        )
        page.locator("#slimmingNavigationButton").focus()
        page.wait_for_function(
            "() => document.activeElement?.id === 'slimmingNavigationButton'"
        )
        page.keyboard.press("ArrowDown")
        assert page.evaluate("document.activeElement?.dataset.sourceId") == SOURCE_ID
        page.keyboard.press("ArrowUp")
        assert page.evaluate("document.activeElement?.id") == "slimmingNavigationButton"
        page.keyboard.press("End")
        page.wait_for_function(
            "() => document.activeElement?.id === 'sidebarConnectFolderButton'"
        )
        page.locator("#settingsButton").click()
        page.locator("#generalSettingsContent:not(.hidden)").wait_for()
        icon_only = page.locator(
            '#toolbarDisplayModeControl [data-toolbar-display-mode="iconOnly"]'
        )
        assert icon_only.get_attribute("aria-checked") == "true"
        icon_and_title = page.locator(
            '#toolbarDisplayModeControl [data-toolbar-display-mode="iconAndTitle"]'
        )
        assert icon_only.get_attribute("tabindex") == "0"
        assert icon_and_title.get_attribute("tabindex") == "-1"
        page.wait_for_function(
            "() => document.activeElement?.dataset.toolbarDisplayMode === 'iconOnly'"
        )

        display_mode_update_count = len(updates)
        page.keyboard.press("ArrowRight")
        page.wait_for_function(
            "() => document.querySelector('#appView').dataset.toolbarDisplayMode === 'iconAndTitle'"
        )
        assert page.evaluate(
            "() => document.activeElement?.dataset.toolbarDisplayMode"
        ) == "iconAndTitle"
        assert icon_only.get_attribute("tabindex") == "-1"
        assert icon_and_title.get_attribute("tabindex") == "0"
        assert len(updates) == display_mode_update_count + 1
        assert updates[-1]["toolbarDisplayMode"] == "iconAndTitle"
        assert "operationID" in updates[-1]

        page.keyboard.press("Tab")
        active = page.evaluate(
            "() => ({ id: document.activeElement?.id, text: document.activeElement?.textContent, mode: document.activeElement?.dataset?.toolbarDisplayMode })"
        )
        assert active["id"] == "generalSettingsModelToggle", active
        page.keyboard.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('#generalSettingsModelState').textContent === '模型已就绪'"
        )
        assert updates[-1]["modelEnabled"] is True

        page.keyboard.press("ArrowDown")
        assert page.evaluate("() => document.activeElement?.id") == "generalSettingsPrewarmToggle"
        page.keyboard.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('#generalSettingsPrewarmToggle').getAttribute('aria-checked') === 'false'"
        )
        assert updates[-1]["idleThumbnailPrewarmEnabled"] is False

        default_input = page.locator('[data-suggestion-default="featureKnn"]')
        page.evaluate(
            """
            () => {
              const input = document.querySelector('[data-suggestion-default="featureKnn"]');
              window.__suggestionDefaultFrame = {
                input,
                decrease: document.querySelector(
                  '[data-suggestion-default-step="-0.05"]'
                    + '[data-suggestion-default-method="featureKnn"]'
                ),
                increase: document.querySelector(
                  '[data-suggestion-default-step="0.05"]'
                    + '[data-suggestion-default-method="featureKnn"]'
                ),
              };
            }
            """
        )
        default_input.fill("0.15")
        default_input.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('[data-suggestion-default=\"featureKnn\"]').value === '0.15'"
        )
        assert updates[-1]["suggestionThresholdMutation"] == {
            "action": "setDefault",
            "method": "featureKnn",
            "minScore": 0.15,
        }
        assert page.evaluate("() => document.activeElement?.dataset.suggestionDefault") == "featureKnn"

        page.locator(
            '[data-suggestion-default-step="0.05"]'
            '[data-suggestion-default-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            "() => document.querySelector('[data-suggestion-default=\"featureKnn\"]').value === '0.20'"
        )
        assert updates[-1]["suggestionThresholdMutation"] == {
            "action": "setDefault",
            "method": "featureKnn",
            "minScore": 0.2,
        }
        assert page.evaluate(
            """
            () => {
              const frame = window.__suggestionDefaultFrame;
              return frame.input?.isConnected
                && frame.decrease?.isConnected
                && frame.increase?.isConnected
                && document.activeElement === frame.increase;
            }
            """
        ), "default increase rebuilt the stepper or lost its focus"

        page.locator(
            '[data-suggestion-default-step="-0.05"]'
            '[data-suggestion-default-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            "() => document.querySelector('[data-suggestion-default=\"featureKnn\"]').value === '0.15'"
        )
        assert updates[-1]["suggestionThresholdMutation"] == {
            "action": "setDefault",
            "method": "featureKnn",
            "minScore": 0.15,
        }
        assert page.evaluate(
            """
            () => document.activeElement === window.__suggestionDefaultFrame.decrease
            """
        ), "default decrease did not restore the same button focus"

        page.locator("#suggestionOverridesButton").click()
        page.wait_for_function("() => document.activeElement?.id === 'suggestionThresholdSearch'")
        page.evaluate(
            """
            () => {
              const cards = [...document.querySelectorAll(
                "#suggestionThresholdList .suggestion-threshold-card"
              )];
              const card = cards.find((candidate) =>
                candidate.querySelector(":scope > h3")?.textContent === "猫"
              );
              const input = card.querySelector(
                '[data-threshold-focus="input"][data-threshold-method="featureKnn"]'
              );
              const list = document.querySelector("#suggestionThresholdList");
              list.scrollTop = 36;
              window.__thresholdSearchFrame = {
                card,
                title: card.querySelector(":scope > h3"),
                method: input.closest(".suggestion-threshold-method"),
                input,
                scenery: cards.find((candidate) =>
                  candidate.querySelector(":scope > h3")?.textContent === "风景"
                ),
                scrollTop: list.scrollTop,
              };
            }
            """
        )
        page.locator("#suggestionThresholdList .suggestion-threshold-card").first.hover()
        page.locator("#suggestionThresholdSearch").focus()
        page.locator("#suggestionThresholdSearch").fill("猫")
        assert page.locator("#suggestionThresholdList .suggestion-threshold-card").count() == 1
        assert page.locator("#suggestionThresholdList .suggestion-threshold-card h3").inner_text() == "猫"
        assert page.evaluate(
            """
            () => {
              const frame = window.__thresholdSearchFrame;
              const card = document.querySelector(
                "#suggestionThresholdList .suggestion-threshold-card"
              );
              const input = card?.querySelector(
                '[data-threshold-focus="input"][data-threshold-method="featureKnn"]'
              );
              const search = document.querySelector("#suggestionThresholdSearch");
              return frame.card === card
                && frame.title === card?.querySelector(":scope > h3")
                && frame.method === input?.closest(".suggestion-threshold-method")
                && frame.input === input
                && !frame.scenery?.isConnected
                && card.matches(":hover")
                && document.activeElement === search
                && search.selectionStart === search.value.length
                && document.querySelector("#suggestionThresholdList").scrollTop
                  === frame.scrollTop;
            }
            """
        ), "threshold search replaced a matching tag card or its input scene"

        cat_feature_input = page.locator(
            f'[data-threshold-focus="input"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        )
        cat_feature_input.focus()
        page.evaluate(
            """
            () => {
              const input = document.activeElement;
              window.__thresholdConnectionFrame = {
                input,
                value: input.value,
                decrease: input.parentElement.querySelector('[data-threshold-step="-0.05"]'),
                increase: input.parentElement.querySelector('[data-threshold-step="0.05"]'),
              };
            }
            """
        )
        page.evaluate("() => setConnection(false, 'Mac 离线')")
        assert page.evaluate(
            """
            () => {
              const frame = window.__thresholdConnectionFrame;
              return frame.input?.isConnected
                && frame.input.disabled
                && frame.decrease?.isConnected
                && frame.decrease.disabled
                && frame.increase?.isConnected
                && frame.increase.disabled
                && frame.input.value === frame.value;
            }
            """
        ), "offline threshold gate replaced or reset the active input"
        page.evaluate("() => setConnection(true, '已连接')")
        page.wait_for_function(
            "() => document.activeElement === window.__thresholdConnectionFrame.input"
        )
        assert page.evaluate(
            """
            () => {
              const frame = window.__thresholdConnectionFrame;
              return frame.input?.isConnected
                && !frame.input.disabled
                && frame.decrease?.isConnected
                && !frame.decrease.disabled
                && frame.increase?.isConnected
                && !frame.increase.disabled
                && frame.input.value === frame.value
                && document.activeElement === frame.input;
            }
            """
        ), "reconnected threshold gate did not restore the active input scene"
        page.evaluate(
            f"""
            () => {{
              const input = document.querySelector(
                '[data-threshold-focus="input"][data-threshold-tag-id="{CAT_TAG_ID}"]'
                  + '[data-threshold-method="featureKnn"]'
              );
              const card = input.closest(".suggestion-threshold-card");
              const method = input.closest(".suggestion-threshold-method");
              const personal = card.querySelector(
                '[data-threshold-focus="input"][data-threshold-method="personalCentroid"]'
              );
              window.__thresholdMutationFrame = {{
                card,
                method,
                input,
                personalMethod: personal.closest(".suggestion-threshold-method"),
                personal,
                decrease: method.querySelector('[data-threshold-step="-0.05"]'),
                increase: method.querySelector('[data-threshold-step="0.05"]'),
                inherit: method.querySelector('[data-threshold-action="clearOverride"]'),
                adopt: method.querySelector('[data-threshold-action="setOverride"]'),
              }};
            }}
            """
        )
        cat_feature_input.fill("0.47")
        cat_feature_input.press("Enter")
        page.wait_for_function(
            "() => document.activeElement?.dataset.thresholdMethod === 'featureKnn'"
        )
        assert updates[-1]["suggestionThresholdMutation"]["minScore"] == 0.47
        assert page.evaluate(
            """
            () => {
              const frame = window.__thresholdMutationFrame;
              return frame.card?.isConnected
                && frame.method?.isConnected
                && frame.input?.isConnected
                && frame.decrease?.isConnected
                && frame.increase?.isConnected
                && frame.personalMethod?.isConnected
                && frame.personal?.isConnected
                && frame.inherit?.isConnected
                && frame.adopt?.isConnected
                && document.activeElement === frame.input
                && frame.input.value === "0.47";
            }
            """
        ), "threshold submit rebuilt the edited or untouched method controls"

        page.locator(
            f'[data-threshold-step="0.05"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            f"() => document.querySelector('[data-threshold-focus=\"input\"]'"
            f" + '[data-threshold-tag-id=\"{CAT_TAG_ID}\"]'"
            " + '[data-threshold-method=\"featureKnn\"]')?.value === '0.52'"
        )
        assert updates[-1]["suggestionThresholdMutation"] == {
            "action": "setOverride",
            "tagID": CAT_TAG_ID,
            "method": "featureKnn",
            "minScore": 0.52,
        }
        page.wait_for_function(
            "() => document.activeElement === window.__thresholdMutationFrame.increase"
        )
        assert page.evaluate(
            """
            () => {
              const frame = window.__thresholdMutationFrame;
              return frame.decrease?.isConnected
                && frame.increase?.isConnected
                && document.activeElement === frame.increase;
            }
            """
        ), "override increase rebuilt the stepper or lost its focus"

        page.locator(
            f'[data-threshold-step="-0.05"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            f"() => document.querySelector('[data-threshold-focus=\"input\"]'"
            f" + '[data-threshold-tag-id=\"{CAT_TAG_ID}\"]'"
            " + '[data-threshold-method=\"featureKnn\"]')?.value === '0.47'"
        )
        assert updates[-1]["suggestionThresholdMutation"] == {
            "action": "setOverride",
            "tagID": CAT_TAG_ID,
            "method": "featureKnn",
            "minScore": 0.47,
        }
        page.wait_for_function(
            "() => document.activeElement === window.__thresholdMutationFrame.decrease"
        )
        assert page.evaluate(
            "() => document.activeElement === window.__thresholdMutationFrame.decrease"
        ), "override decrease did not restore the same button focus"

        page.locator(
            f'[data-threshold-action="clearOverride"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            f"() => !document.querySelector('[data-threshold-action=\"clearOverride\"]'"
            f" + '[data-threshold-tag-id=\"{CAT_TAG_ID}\"]'"
            " + '[data-threshold-method=\"featureKnn\"]')"
        )
        assert updates[-1]["suggestionThresholdMutation"]["action"] == "clearOverride"
        assert page.evaluate(
            """
            () => {
              const frame = window.__thresholdMutationFrame;
              return frame.card?.isConnected
                && frame.method?.isConnected
                && frame.input?.isConnected
                && frame.personalMethod?.isConnected
                && frame.personal?.isConnected
                && !frame.inherit?.isConnected
                && frame.adopt?.isConnected;
            }
            """
        ), "clearing one override rebuilt unrelated threshold controls"

        page.locator(
            f'[data-threshold-action="setOverride"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            f"() => document.querySelector('[data-threshold-focus=\"input\"]'"
            f" + '[data-threshold-tag-id=\"{CAT_TAG_ID}\"]'"
            " + '[data-threshold-method=\"featureKnn\"]')?.value === '0.55'"
        )
        assert updates[-1]["suggestionThresholdMutation"]["minScore"] == 0.55
        assert page.evaluate(
            """
            () => {
              const frame = window.__thresholdMutationFrame;
              const inherit = frame.method.querySelector(
                '[data-threshold-action="clearOverride"]'
              );
              return frame.card?.isConnected
                && frame.method?.isConnected
                && frame.input?.isConnected
                && frame.personalMethod?.isConnected
                && frame.personal?.isConnected
                && frame.adopt?.isConnected
                && inherit?.isConnected
                && inherit !== frame.inherit
                && frame.input.value === "0.55";
            }
            """
        ), "adopting a reference rebuilt stable threshold controls"
        page.keyboard.press("Escape")
        assert page.locator("#suggestionThresholdDialog").is_hidden()
        page.wait_for_function("() => document.activeElement?.id === 'suggestionOverridesButton'")
        page.keyboard.press("Escape")
        assert page.locator("#generalSettingsDialog").is_hidden()
        page.wait_for_function(
            """() => {
              const compact = document.querySelector('#appView')
                .classList.contains('compact-toolbar-active');
              return document.activeElement?.id === (
                compact ? 'compactToolbarMenuButton' : 'settingsButton'
              );
            }"""
        )

        click_toolbar_action(page, "reviewButton")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for()
        page.locator("#reviewLocalModelPanel").wait_for()
        assert page.locator("#reviewLocalModelStateBadge").inner_text() == "模型已就绪"
        assert "DINOv2 Small" in page.locator("#reviewLocalModelStatus").inner_text()
        wide_model_layout = page.evaluate(
            """() => {
              const panel = document.querySelector('#reviewLocalModelPanel').getBoundingClientRect();
              const content = document.querySelector('.review-overview-content').getBoundingClientRect();
              return { panelRight: panel.right, contentLeft: content.left };
            }"""
        )
        assert wide_model_layout["panelRight"] <= wide_model_layout["contentLeft"] + 1
        page.locator("#refreshReviewModelStatusButton:not(:disabled)").click()
        page.wait_for_function(
            "() => document.activeElement?.id === 'refreshReviewModelStatusButton'"
        )

        page.locator("#reviewSourceFilterButton").click()
        page.locator(
            f'[data-review-source-id="{FOLDER_SOURCE_ID}"]'
        ).click()
        page.locator(
            f'[data-review-source-id="{SOURCE_ID}"]'
        ).click()
        page.wait_for_function(
            "() => document.querySelector('#generateLibrarySuggestionsButton').disabled"
        )
        assert "没有选择审核来源" in page.locator("#sampleSuggestionReviewStatus").inner_text()
        page.locator(
            f'[data-review-source-id="{SOURCE_ID}"]'
        ).click()
        page.wait_for_function(
            "() => !document.querySelector('#generateLibrarySuggestionsButton').disabled"
        )
        page.keyboard.press("Escape")
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sample-suggestions/requests")
            and response.request.method == "POST"
        ) as sample_response:
            page.locator("#generateLibrarySuggestionsButton").click()
        assert sample_response.value.status == 200
        assert sample_requests[-1]["assetIDs"] == []
        assert sample_requests[-1]["sourceIDs"] == [SOURCE_ID]
        completed_personal_increase = page.locator(
            f'[data-review-control-tag-id="{CAT_TAG_ID}"] '
            f'[data-threshold-method="personalCentroid"]'
            '[data-threshold-focus="increase"]'
        )
        page.wait_for_timeout(1_000)
        assert not completed_personal_increase.is_disabled()

        review_controls = page.locator(
            f'[data-review-control-tag-id="{CAT_TAG_ID}"]'
        )
        review_controls.locator("summary").click()
        assert review_controls.get_attribute("open") is not None
        assert review_controls.locator(".review-threshold-row").count() == 3

        personal_increase = review_controls.locator(
            f'[data-threshold-focus="increase"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="personalCentroid"]'
        )
        personal_increase.click()
        page.wait_for_function(
            f"() => document.querySelector('[data-review-control-tag-id=\"{CAT_TAG_ID}\"]'"
            " + ' [data-threshold-method=\"personalCentroid\"][data-threshold-focus=\"input\"]')?.value === '0.25'"
        )
        assert updates[-1]["suggestionThresholdMutation"]["minScore"] == 0.25
        page.wait_for_function(
            "() => document.activeElement?.dataset.thresholdFocus === 'increase'",
            timeout=1_000,
        )

        review_controls.locator(
            f'[data-threshold-focus="adopt"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            f"() => document.querySelector('[data-review-control-tag-id=\"{CAT_TAG_ID}\"]'"
            " + ' [data-threshold-method=\"featureKnn\"][data-threshold-focus=\"input\"]')?.value === '0.55'"
        )
        assert updates[-1]["suggestionThresholdMutation"]["action"] == "setOverride"

        review_controls.locator(
            f'[data-threshold-focus="inherit"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            f"() => document.querySelector('[data-review-control-tag-id=\"{CAT_TAG_ID}\"]'"
            " + ' [data-threshold-method=\"featureKnn\"][data-threshold-focus=\"input\"]')?.value === '0.15'"
        )
        assert updates[-1]["suggestionThresholdMutation"]["action"] == "clearOverride"
        assert page.evaluate(
            "() => document.activeElement?.dataset.thresholdFocus"
        ) == "input"

        review_controls.locator(
            f'[data-threshold-focus="prune"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        ).click()
        page.wait_for_function(
            f"() => document.querySelector('[data-review-overview-tag-id=\"{CAT_TAG_ID}\"]'"
            " + ' .review-pending-count')?.textContent === '3'"
        )
        assert updates[-1]["suggestionThresholdMutation"] == {
            "action": "prune",
            "method": "featureKnn",
            "tagID": CAT_TAG_ID,
        }
        assert page.evaluate(
            "() => document.activeElement?.dataset.thresholdFocus"
        ) == "prune"
        assert review_controls.get_attribute("open") is not None

        personal_method = next(
            method for method in settings["suggestionThresholds"]["tags"][0]["methods"]
            if method["method"] == "personalCentroid"
        )
        personal_method["effectiveMinScore"] = 0.35
        personal_method["overrideMinScore"] = 0.35
        page.locator("#refreshReviewButton").click()
        page.wait_for_function(
            f"() => document.querySelector('[data-review-control-tag-id=\"{CAT_TAG_ID}\"]'"
            " + ' [data-threshold-method=\"personalCentroid\"][data-threshold-focus=\"input\"]')?.value === '0.35'"
        )
        assert review_controls.get_attribute("open") is not None
        page.screenshot(path="/tmp/imageall-review-thresholds-wide.png", full_page=True)

        assert page.locator("#reviewSuggestionLimitValue").inner_text() == "500"
        page.locator("#increaseReviewSuggestionLimitButton").click()
        page.wait_for_function(
            "() => document.querySelector('#reviewSuggestionLimitValue')?.textContent === '550'"
        )
        assert updates[-1]["maxPendingSuggestionsPerTag"] == 550
        page.wait_for_function(
            "() => document.activeElement?.id === 'increaseReviewSuggestionLimitButton'"
        )
        page.set_viewport_size({"width": 390, "height": 844})
        review_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert review_dimensions["scroll"] <= review_dimensions["viewport"], review_dimensions
        assert page.locator("#reviewLocalModelPanel").is_visible()
        assert page.evaluate(
            "() => getComputedStyle(document.querySelector('#reviewLocalModelPanel')).gridTemplateColumns"
        ) != "none"
        assert review_controls.locator(".review-threshold-editor").first.is_visible()
        page.screenshot(path="/tmp/imageall-review-thresholds-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})
        review_view_all_asset_count = len(asset_requests)
        review_view_all_action_count = len(source_actions)
        review_view_all_session = page.evaluate(
            "() => ({ mediaKind: state.mediaKind, sort: state.sort, filters: state.filters })"
        )
        page.locator("#sourceAllActionsButton").click()
        page.locator("#sourceActionsViewAllButton").click()
        page.wait_for_function(
            "() => visibleWorkspaceRoute() === 'gallery'"
            " && state.selectedSourceID === '' && !state.loadingAssets"
        )
        assert page.evaluate(
            "() => ({ mediaKind: state.mediaKind, sort: state.sort, filters: state.filters })"
        ) == review_view_all_session
        assert len(asset_requests) == review_view_all_asset_count + 1
        assert len(source_actions) == review_view_all_action_count
        page.wait_for_function(
            "() => document.activeElement?.dataset.sourceId === ''"
        )

        page.keyboard.press("Meta+,")
        assert page.locator("#generalSettingsDialog").is_visible()
        page.keyboard.press("Escape")

        source_button = page.locator(f'#sourceList [data-source-id="{SOURCE_ID}"]')
        source_button.click(button="right")
        page.locator("#sourceContextMenu:not(.hidden)").wait_for()
        menu_labels = page.locator("#sourceContextMenuActions button").all_inner_texts()
        assert menu_labels == [
            "在图库中查看",
            "上移来源",
            "下移来源",
            "立即同步",
            "预热缩略图缓存",
            "专门用于原比例的缓存",
            "完整修复…",
            "请求照片写入权限…",
            "删除来源…",
            "打开来源管理…",
        ], menu_labels
        page.wait_for_function(
            "() => document.activeElement?.dataset.sourceContextAction === 'view'"
        )
        page.keyboard.press("ArrowDown")
        assert page.evaluate(
            "() => document.activeElement?.dataset.sourceContextAction"
        ) == "moveLater"
        page.keyboard.press("Escape")
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        source_bounds = source_button.bounding_box()
        assert source_bounds is not None
        long_press_point = {
            "x": source_bounds["x"] + min(42, source_bounds["width"] / 2),
            "y": source_bounds["y"] + source_bounds["height"] / 2,
        }
        page.evaluate(
            """({ sourceID, point }) => {
              const source = document.querySelector(`[data-source-id="${sourceID}"]`);
              source.dispatchEvent(new PointerEvent('pointerdown', {
                bubbles: true,
                pointerId: 91,
                pointerType: 'touch',
                button: 0,
                clientX: point.x,
                clientY: point.y,
                isPrimary: true,
              }));
            }""",
            {"sourceID": SOURCE_ID, "point": long_press_point},
        )
        page.wait_for_timeout(580)
        page.locator("#sourceContextMenu:not(.hidden)").wait_for()
        assert not source_button.evaluate(
            "button => button.classList.contains('context-long-press-active')"
        )
        page.evaluate(
            """point => document.elementFromPoint(point.x, point.y)?.dispatchEvent(
              new PointerEvent('pointerup', {
                bubbles: true,
                pointerId: 91,
                pointerType: 'touch',
                button: 0,
                clientX: point.x,
                clientY: point.y,
                isPrimary: true,
              })
            )""",
            long_press_point,
        )
        page.screenshot(path="/tmp/imageall-source-long-press-menu.png", full_page=True)
        page.keyboard.press("Escape")
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        page.evaluate(
            """({ sourceID, point }) => {
              const source = document.querySelector(`[data-source-id="${sourceID}"]`);
              source.dispatchEvent(new PointerEvent('pointerdown', {
                bubbles: true,
                pointerId: 92,
                pointerType: 'touch',
                button: 0,
                clientX: point.x,
                clientY: point.y,
                isPrimary: true,
              }));
              source.dispatchEvent(new PointerEvent('pointermove', {
                bubbles: true,
                pointerId: 92,
                pointerType: 'touch',
                button: 0,
                clientX: point.x + 20,
                clientY: point.y + 20,
                isPrimary: true,
              }));
            }""",
            {"sourceID": SOURCE_ID, "point": long_press_point},
        )
        page.wait_for_timeout(580)
        assert page.locator("#sourceContextMenu").is_hidden()
        source_button.press("Shift+F10")
        page.locator("#sourceContextMenu:not(.hidden)").wait_for()
        page.locator('[data-source-context-action="view"]').click()
        page.wait_for_function(
            f"() => document.querySelector('#sourceList [data-source-id=\"{SOURCE_ID}\"]')?.classList.contains('selected')"
        )
        assert page.locator("#currentSourceRefreshLabel").inner_text() == "立即同步"
        source_view_all_asset_count = len(asset_requests)
        source_view_all_action_count = len(source_actions)
        source_view_all_session = page.evaluate(
            "() => ({ mediaKind: state.mediaKind, sort: state.sort, filters: state.filters })"
        )
        page.locator("#sourceAllActionsButton").click()
        page.locator("#sourceActionsViewAllButton").click()
        page.wait_for_function(
            "() => state.selectedSourceID === '' && !state.loadingAssets"
        )
        assert page.locator("#sourceActionsPopover").is_hidden()
        assert page.evaluate(
            "history.state?.imageAllWorkspace?.navigationLevel"
        ) == "workspace"
        page.wait_for_function(
            "() => document.activeElement?.dataset.sourceId === ''"
        )
        assert page.evaluate(
            "() => ({ mediaKind: state.mediaKind, sort: state.sort, filters: state.filters })"
        ) == source_view_all_session
        assert len(asset_requests) == source_view_all_asset_count + 1
        assert len(source_actions) == source_view_all_action_count
        source_button.click()
        page.wait_for_function(
            f"() => state.selectedSourceID === '{SOURCE_ID}' && !state.loadingAssets"
        )
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as current_photos_sync:
            click_toolbar_action(page, "currentSourceRefreshButton")
        assert current_photos_sync.value.status == 200
        assert source_actions[-1]["action"] == "syncPhotos"
        assert source_actions[-1]["sourceID"] == SOURCE_ID

        page.wait_for_function(
            "() => document.querySelector('#emptyStateTitle')?.textContent === '系统照片图库中没有可访问的照片'"
        )
        assert page.locator("#emptySourceRecoveryButton").inner_text() == "立即同步"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as empty_sync:
            page.locator("#emptySourceRecoveryButton").click()
        assert empty_sync.value.status == 200
        assert source_actions[-1]["action"] == "syncPhotos"
        page.locator("#sourceManagerCloseButton").click()

        sources[0]["state"] = "authorizationRequired"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as authorization_refresh:
            click_toolbar_action(page, "refreshButton")
        assert authorization_refresh.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#emptyStateTitle')?.textContent === '需要照片访问权限'"
        )
        assert page.locator("#currentSourceRefreshButton").is_disabled()
        assert page.locator("#emptySourceRecoveryButton").inner_text() == "重新检查并同步"
        assert page.locator("#emptyOpenPhotosSettingsButton").is_visible()
        assert page.locator("#emptyOpenPhotosSettingsButton").inner_text() == "打开照片权限设置…"
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(80)
        assert page.evaluate(
            "() => document.documentElement.scrollWidth <= window.innerWidth"
        )
        for selector in [
            "#emptySourceRecoveryButton",
            "#emptyOpenPhotosSettingsButton",
            "#emptyOpenSourceManagerButton",
        ]:
            bounds = page.locator(selector).bounding_box()
            assert bounds is not None, selector
            assert bounds["x"] >= 0 and bounds["x"] + bounds["width"] <= 390, (
                selector,
                bounds,
            )
        page.screenshot(path="/tmp/imageall-photos-authorization-390.png", full_page=True)
        page.set_viewport_size({"width": 1440, "height": 960})
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as open_photos_settings:
            page.locator("#emptyOpenPhotosSettingsButton").click()
        assert open_photos_settings.value.status == 200
        assert source_actions[-1]["action"] == "openPhotosPrivacySettings"
        assert source_actions[-1]["sourceID"] == SOURCE_ID
        assert not page.locator("#sourceManagerDialog").is_visible()

        sources[0]["state"] = "disabled"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as disabled_refresh:
            click_toolbar_action(page, "refreshButton")
        assert disabled_refresh.value.status == 200
        assert page.locator("#emptySourceRecoveryButton").inner_text() == "重新检查并同步"
        source_button.click(button="right")
        assert "重新启用…" in page.locator(
            "#sourceContextMenuActions button"
        ).all_inner_texts()
        page.keyboard.press("Escape")
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )

        sources[0]["state"] = "unavailable"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as unavailable_refresh:
            click_toolbar_action(page, "refreshButton")
        assert unavailable_refresh.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#emptyStateTitle')?.textContent === '系统照片图库已更换'"
        )
        assert page.locator("#emptySourceRecoveryButton").inner_text() == "连接当前图库…"
        rebind_request_count = len(source_actions)
        page.locator("#emptySourceRecoveryButton").click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "连接当前系统照片图库" in page.locator("#confirmDialogTitle").inner_text()
        assert "保留旧图库的索引、人工标签和历史" in page.locator(
            "#confirmDialogMessage"
        ).inner_text()
        assert page.locator("#confirmActionButton").inner_text() == "保留历史并连接"
        page.locator("#cancelConfirmButton").click()
        assert len(source_actions) == rebind_request_count
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceAction === 'rebindPhotos'"
            f" && document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        rebind_button = page.locator(
            f'#sourceManagerList [data-source-action="rebindPhotos"]'
            f'[data-source-id="{SOURCE_ID}"]'
        )
        rebind_button.click()
        page.locator("#confirmDialog[open]").wait_for()
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as photos_rebind:
            page.locator("#confirmActionButton").click()
        assert photos_rebind.value.status == 200
        assert source_actions[-1]["action"] == "rebindPhotos"
        assert source_actions[-1]["sourceID"] == SOURCE_ID
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceAction === 'rebindPhotos'"
            f" && document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        page.locator("#sourceManagerCloseButton").click()

        sources[0]["state"] = "active"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as active_refresh:
            click_toolbar_action(page, "refreshButton")
        assert active_refresh.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#emptySourceRecoveryButton')?.textContent === '立即同步'"
        )
        assert page.locator("#currentSourceRefreshButton").is_enabled()

        full_repair_request_count = len(source_actions)
        source_button.click(button="right")
        page.locator('[data-source-context-action="fullRepair"]').click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "Apple Photos" in page.locator("#confirmDialogTitle").inner_text()
        assert "重新扫描整个 Apple Photos 图库" in page.locator(
            "#confirmDialogMessage"
        ).inner_text()
        assert page.locator("#confirmActionButton").inner_text() == "开始完整修复扫描"
        page.screenshot(
            path="/tmp/imageall-source-full-repair-confirmation.png",
            full_page=True,
        )
        page.keyboard.press("Escape")
        page.locator("#confirmDialog").wait_for(state="hidden")
        assert not page.locator("#sourceManagerDialog").is_visible()
        assert len(source_actions) == full_repair_request_count
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        source_button.click(button="right")
        page.locator('[data-source-context-action="fullRepair"]').click()
        page.locator("#confirmDialog[open]").wait_for()
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as photos_full_repair:
            page.locator("#confirmActionButton").click()
        assert photos_full_repair.value.status == 200
        assert source_actions[-1]["action"] == "fullRepair"
        assert source_actions[-1]["sourceID"] == SOURCE_ID
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        assert not page.locator("#sourceManagerDialog").is_visible()

        source_button.click(button="right")
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as photos_authorization:
            page.locator('[data-source-context-action="requestPhotosWriteAuthorization"]').click()
        assert photos_authorization.value.status == 200
        page.wait_for_function("() => document.querySelector('#toastMessage')?.textContent.includes('Synthetic Mac authorization completed')")
        assert source_actions[-1]["action"] == "requestPhotosWriteAuthorization"
        assert not page.locator("#sourceManagerDialog").is_visible()

        delete_request_count = len(source_actions)
        source_button.click(button="right")
        page.locator('[data-source-context-action="delete"]').click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "删除来源“Apple Photos”" in page.locator("#confirmDialogTitle").inner_text()
        assert "不会删除磁盘或 Apple Photos 中的原始媒体" in page.locator(
            "#confirmDialogMessage"
        ).inner_text()
        assert page.locator("#confirmActionButton").inner_text() == "交给 Mac 确认"
        page.locator("#cancelConfirmButton").click()
        assert len(source_actions) == delete_request_count
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        source_button.click(button="right")
        page.locator('[data-source-context-action="delete"]').click()
        page.locator("#confirmDialog[open]").wait_for()
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as photos_delete:
            page.locator("#confirmActionButton").click()
        assert photos_delete.value.status == 200
        assert source_actions[-1]["action"] == "delete"
        assert source_actions[-1]["sourceID"] == SOURCE_ID
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        assert not page.locator("#sourceManagerDialog").is_visible()

        folder_button = page.locator(f'#sourceList [data-source-id="{FOLDER_SOURCE_ID}"]')
        folder_button.click()
        page.wait_for_function(
            "() => document.querySelector('#emptyStateTitle')?.textContent === '没有支持的照片'"
        )
        assert page.locator("#emptySourceRecoveryButton").inner_text() == "立即重扫"
        assert page.locator("#currentSourceRefreshLabel").inner_text() == "立即重扫"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as current_folder_rescan:
            click_toolbar_action(page, "currentSourceRefreshButton")
        assert current_folder_rescan.value.status == 200
        assert source_actions[-1]["action"] == "rescan"
        assert source_actions[-1]["sourceID"] == FOLDER_SOURCE_ID

        sources[1]["state"] = "authorizationRequired"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as folder_authorization_refresh:
            click_toolbar_action(page, "refreshButton")
        assert folder_authorization_refresh.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#emptyStateTitle')?.textContent === '需要重新授权文件夹'"
        )
        assert page.locator("#currentSourceRefreshButton").is_disabled()
        assert page.locator("#emptySourceRecoveryButton").inner_text() == "重新授权…"
        page.screenshot(path="/tmp/imageall-source-empty-recovery-synthetic.png", full_page=True)

        sources[1]["state"] = "active"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as folder_active_refresh:
            click_toolbar_action(page, "refreshButton")
        assert folder_active_refresh.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#emptySourceRecoveryButton')?.textContent === '立即重扫'"
        )

        folder_button.click(button="right")
        folder_menu_labels = page.locator("#sourceContextMenuActions button").all_inner_texts()
        assert folder_menu_labels == [
            "在图库中查看",
            "上移来源",
            "下移来源",
            "立即重扫",
            "预热缩略图缓存",
            "专门用于原比例的缓存",
            "更新回收权限…",
            "删除来源…",
            "打开来源管理…",
        ], folder_menu_labels
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as folder_authorization:
            page.locator('[data-source-context-action="refreshFolderMutationAuthorization"]').click()
        assert folder_authorization.value.status == 200
        page.wait_for_function("() => document.querySelector('#toastMessage')?.textContent.includes('Synthetic Mac authorization completed')")
        assert source_actions[-1]["action"] == "refreshFolderMutationAuthorization"
        page.screenshot(path="/tmp/imageall-source-authorization-synthetic.png", full_page=True)
        assert not page.locator("#sourceManagerDialog").is_visible()

        page.locator("#sourceManagerButton").click()
        page.keyboard.press("Escape")
        page.wait_for_function("() => document.activeElement?.id === 'sourceManagerButton'")
        page.locator("#sourceManagerButton").click()
        page.locator("#sourceManagerList .source-manager-row").first.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'sourceConnectFolderButton'"
        )
        page.locator("#sourceAllActionsSummary").focus()
        page.keyboard.press("ArrowDown")
        assert page.locator("#sourceAllActionsPanel").get_attribute("open") is not None
        assert page.evaluate("() => document.activeElement?.id") == "sourceRefreshAllButton"
        page.keyboard.press("Escape")
        assert page.locator("#sourceAllActionsPanel").get_attribute("open") is None
        assert page.evaluate("() => document.activeElement?.id") == "sourceAllActionsSummary"

        source_manager_rows = page.locator(
            "#sourceManagerList [data-source-manager-select]"
        )
        assert source_manager_rows.count() == 2
        source_manager_rows.first.click()
        assert source_manager_rows.first.get_attribute("aria-selected") == "true"
        assert page.locator("#sourceManagerList [data-source-manager-detail]").get_attribute(
            "data-source-manager-detail"
        ) == SOURCE_ID
        assert page.locator(
            f'#sourceManagerList [data-source-manager-view="{SOURCE_ID}"]'
        ).is_visible()
        source_manager_geometry = page.evaluate(
            """() => {
              const workspace = document.querySelector('#sourceManagerList').getBoundingClientRect();
              const list = document.querySelector('.source-manager-source-list').getBoundingClientRect();
              const detail = document.querySelector('.source-manager-detail').getBoundingClientRect();
              return {
                listBeforeDetail: list.right <= detail.left + 1,
                contained: list.left >= workspace.left && detail.right <= workspace.right + 1,
              };
            }"""
        )
        assert source_manager_geometry == {
            "listBeforeDetail": True,
            "contained": True,
        }, source_manager_geometry
        page.screenshot(
            path="/tmp/imageall-source-manager-mac-layout.png",
            full_page=True,
        )

        source_manager_rows.first.focus()
        page.keyboard.press("ArrowDown")
        page.wait_for_function(
            f"() => document.querySelector('[data-source-manager-select=\"{FOLDER_SOURCE_ID}\"]')"
            ".getAttribute('aria-selected') === 'true'"
        )
        assert page.locator("#sourceManagerList [data-source-manager-detail]").get_attribute(
            "data-source-manager-detail"
        ) == FOLDER_SOURCE_ID
        page.keyboard.press("ArrowRight")
        assert page.evaluate(
            "() => document.activeElement?.dataset.sourceManagerView"
        ) == FOLDER_SOURCE_ID
        page.keyboard.press("ArrowLeft")
        assert page.evaluate(
            "() => document.activeElement?.dataset.sourceManagerSelect"
        ) == FOLDER_SOURCE_ID

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(80)
        assert page.evaluate(
            "() => document.documentElement.scrollWidth <= window.innerWidth"
        )
        assert page.locator(".source-manager-source-list").is_visible()
        assert page.locator(".source-manager-detail").is_visible()
        page.screenshot(
            path="/tmp/imageall-source-manager-mac-layout-390.png",
            full_page=True,
        )
        page.set_viewport_size({"width": 1440, "height": 960})
        page.locator(
            f'#sourceManagerList [data-source-manager-view="{FOLDER_SOURCE_ID}"]'
        ).click()
        page.locator("#sourceManagerDialog").wait_for(state="hidden")
        page.wait_for_function(
            f"() => document.querySelector('#sourceList [data-source-id=\"{FOLDER_SOURCE_ID}\"]')"
            ".getAttribute('aria-current') === 'page'"
        )

        source_manager_history_length = page.evaluate("() => history.length")
        source_manager_asset_request_count = len(asset_requests)
        page.locator("#sourceManagerButton").click()
        page.locator("#sourceManagerList .source-manager-row").first.wait_for()
        assert page.evaluate("() => history.length") in {
            source_manager_history_length,
            source_manager_history_length + 1,
        }
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "sourceManager"
        source_reads_after_open = source_management_reads[0]
        page.evaluate("() => history.back()")
        page.locator("#sourceManagerDialog").wait_for(state="hidden")
        assert page.evaluate("() => document.activeElement?.id") == "sourceManagerButton"
        page.evaluate("() => history.forward()")
        page.locator("#sourceManagerDialog[open]").wait_for()
        assert source_management_reads[0] == source_reads_after_open
        delete_button = page.locator(
            '#sourceManagerList [data-source-action="delete"][data-source-id]'
        ).first
        delete_button.click()
        page.locator("#confirmDialog[open]").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "confirmation"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.context?.confirmationBaseLevel"
        ) == "sourceManager"
        source_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "Apple Photos" not in source_history_payload
        assert "删除来源" not in source_history_payload
        page.evaluate("() => history.back()")
        page.locator("#confirmDialog").wait_for(state="hidden")
        assert page.locator("#sourceManagerDialog").is_visible()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "sourceManager"
        page.evaluate("() => history.forward()")
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#cancelConfirmButton").click()
        page.locator("#confirmDialog").wait_for(state="hidden")
        page.keyboard.press("Escape")
        page.locator("#sourceManagerDialog").wait_for(state="hidden")
        assert page.evaluate("() => document.activeElement?.id") == "sourceManagerButton"
        assert len(asset_requests) == source_manager_asset_request_count, asset_requests[
            source_manager_asset_request_count:
        ]

        click_toolbar_action(page, "storageButton")
        page.locator("#storageContent:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'storageRefreshButton'"
        )
        page.keyboard.press("ArrowDown")
        assert page.evaluate("() => document.activeElement?.id") != "storageRefreshButton"
        page.keyboard.press("Escape")
        page.wait_for_function(
            """() => {
              const compact = document.querySelector('#appView')
                .classList.contains('compact-toolbar-active');
              return document.activeElement?.id === (
                compact ? 'compactToolbarMenuButton' : 'storageButton'
              );
            }"""
        )

        page.set_viewport_size({"width": 390, "height": 844})
        settings_history_length = page.evaluate("() => history.length")
        settings_asset_request_count = len(asset_requests)
        page.keyboard.press("Meta+,")
        page.locator("#generalSettingsDialog").wait_for()
        assert page.evaluate("() => history.length") in {
            settings_history_length,
            settings_history_length + 1,
        }
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "generalSettings"
        settings_layer_history_length = page.evaluate("() => history.length")
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        assert page.locator("#generalSettingsModelToggle").is_visible()
        assert page.locator("#generalSettingsPrewarmToggle").is_visible()
        assert page.locator("#generalSuggestionSection").is_visible()
        page.screenshot(path="/tmp/imageall-general-settings-synthetic.png", full_page=True)
        page.locator("#suggestionOverridesButton:not(:disabled)").wait_for()
        page.locator("#suggestionOverridesButton").click()
        page.locator("#suggestionThresholdList .suggestion-threshold-card").first.wait_for()
        assert page.evaluate("() => history.length") in {
            settings_layer_history_length,
            settings_layer_history_length + 1,
        }
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "suggestionThreshold"
        threshold_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert threshold_dimensions["scroll"] <= threshold_dimensions["viewport"], threshold_dimensions
        assert page.locator("#suggestionThresholdSearch").is_visible()
        page.screenshot(path="/tmp/imageall-suggestion-thresholds-synthetic.png", full_page=True)
        private_threshold_search = "私密标签 /Users/example/Photos"
        page.locator("#suggestionThresholdSearch").fill(private_threshold_search)
        assert private_threshold_search not in page.evaluate("() => JSON.stringify(history.state)")
        page.evaluate("() => history.back()")
        page.locator("#suggestionThresholdDialog").wait_for(state="hidden")
        assert page.locator("#generalSettingsDialog").is_visible()
        assert page.evaluate("() => document.activeElement?.id") == "suggestionOverridesButton"
        page.evaluate("() => history.forward()")
        page.locator("#suggestionThresholdDialog[open]").wait_for()
        assert page.locator("#suggestionThresholdSearch").input_value() == ""
        page.keyboard.press("Escape")
        page.locator("#suggestionThresholdDialog").wait_for(state="hidden")
        assert page.locator("#generalSettingsDialog").is_visible()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "generalSettings"
        page.keyboard.press("Escape")
        page.locator("#generalSettingsDialog").wait_for(state="hidden")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "workspace"
        assert len(asset_requests) == settings_asset_request_count

        assert not page_errors, page_errors
        assert not console_errors, {"console": console_errors, "resources": failed_resources}
        assert not failed_resources, failed_resources
        browser.close()

    assert len(updates) == 16, updates
    print(f"general-settings-keyboard-browser: ok; updates={len(updates)}")


if __name__ == "__main__":
    main()
