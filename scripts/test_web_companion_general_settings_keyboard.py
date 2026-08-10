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


def main():
    updates = []
    sample_requests = []
    source_actions = []
    source_requests = []
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
        page.route(
            "**/v1/source-management",
            lambda route: fulfill_json(
                route,
                {"sources": sources, "canConnectPhotos": False, "requests": source_requests},
            ),
        )
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

        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as refresh_all_sources:
            page.locator("#currentSourceRefreshButton").click()
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
        page.locator("#compactToolbarMenuButton").click()
        page.locator("#compactToolbarMenu:not(.hidden)").wait_for()
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
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.compactToolbarTarget"
        ) == "logoutButton"
        page.keyboard.press("Home")
        assert page.evaluate(
            "() => document.activeElement?.dataset.compactToolbarTarget"
        ) == "catalogProgressStatusButton"
        page.screenshot(path="/tmp/imageall-compact-toolbar-390.png", full_page=True)
        page.keyboard.press("Enter")
        page.locator("#jobsPopover:not(.hidden)").wait_for()
        assert "Apple Photos · 照片图库同步" in page.locator("#jobsList").inner_text()
        page.locator("#closeJobsButton").click()
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
        page.keyboard.press("Escape")
        assert page.evaluate("() => document.activeElement?.id") == "compactToolbarMenuButton"
        page.screenshot(path="/tmp/imageall-source-refresh-390.png", full_page=True)
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
        page.wait_for_function(
            "() => document.activeElement?.dataset.toolbarDisplayMode === 'iconOnly'"
        )

        page.keyboard.press("ArrowRight")
        assert page.evaluate("() => document.activeElement?.dataset.toolbarDisplayMode") == "iconAndTitle"
        page.keyboard.press("Enter")
        page.wait_for_function(
            "() => document.querySelector('#appView').dataset.toolbarDisplayMode === 'iconAndTitle'"
        )
        assert updates[-1]["toolbarDisplayMode"] == "iconAndTitle"
        assert "operationID" in updates[-1]

        page.keyboard.press("ArrowDown")
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

        page.locator("#suggestionOverridesButton").click()
        page.wait_for_function("() => document.activeElement?.id === 'suggestionThresholdSearch'")
        page.locator("#suggestionThresholdSearch").fill("猫")
        assert page.locator("#suggestionThresholdList .suggestion-threshold-card").count() == 1
        assert page.locator("#suggestionThresholdList .suggestion-threshold-card h3").inner_text() == "猫"

        cat_feature_input = page.locator(
            f'[data-threshold-focus="input"][data-threshold-tag-id="{CAT_TAG_ID}"]'
            '[data-threshold-method="featureKnn"]'
        )
        cat_feature_input.fill("0.47")
        cat_feature_input.press("Enter")
        page.wait_for_function(
            "() => document.activeElement?.dataset.thresholdMethod === 'featureKnn'"
        )
        assert updates[-1]["suggestionThresholdMutation"]["minScore"] == 0.47

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
        page.keyboard.press("Escape")
        assert page.locator("#suggestionThresholdDialog").is_hidden()
        page.wait_for_function("() => document.activeElement?.id === 'suggestionOverridesButton'")
        page.keyboard.press("Escape")
        assert page.locator("#generalSettingsDialog").is_hidden()
        assert page.evaluate("() => document.activeElement?.id") == "settingsButton"

        page.locator("#reviewButton").click()
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
        assert page.evaluate(
            "() => document.activeElement?.dataset.thresholdFocus"
        ) == "increase"

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
        page.locator("#closeReviewButton").click()
        page.locator("#reviewWorkspace").wait_for(state="hidden")

        page.keyboard.press("Meta+,")
        assert page.locator("#generalSettingsDialog").is_visible()
        page.keyboard.press("Escape")

        source_button = page.locator(f'#sourceList [data-source-id="{SOURCE_ID}"]')
        source_button.click(button="right")
        page.locator("#sourceContextMenu:not(.hidden)").wait_for()
        menu_labels = page.locator("#sourceContextMenuActions button").all_inner_texts()
        assert menu_labels == [
            "在图库中查看",
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
        ) == "syncPhotos"
        page.keyboard.press("Escape")
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        source_button.press("Shift+F10")
        page.locator("#sourceContextMenu:not(.hidden)").wait_for()
        page.locator('[data-source-context-action="view"]').click()
        page.wait_for_function(
            f"() => document.querySelector('#sourceList [data-source-id=\"{SOURCE_ID}\"]')?.classList.contains('selected')"
        )
        assert page.locator("#currentSourceRefreshLabel").inner_text() == "立即同步"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as current_photos_sync:
            page.locator("#currentSourceRefreshButton").click()
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
            page.locator("#refreshButton").click()
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
            page.locator("#refreshButton").click()
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
            page.locator("#refreshButton").click()
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
            page.locator("#refreshButton").click()
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
        assert page.locator("#sourceManagerDialog").is_visible()
        assert len(source_actions) == full_repair_request_count
        page.wait_for_function(
            f"() => document.activeElement?.dataset.sourceAction === 'fullRepair'"
            f" && document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        page.locator(
            f'[data-source-action="fullRepair"][data-source-id="{SOURCE_ID}"]'
        ).click()
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
            f"() => document.activeElement?.dataset.sourceAction === 'fullRepair'"
            f" && document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        page.locator("#sourceManagerCloseButton").click()

        source_button.click(button="right")
        with page.expect_response(
            lambda response: response.url.endswith("/v1/source-management/requests")
            and response.request.method == "POST"
        ) as photos_authorization:
            page.locator('[data-source-context-action="requestPhotosWriteAuthorization"]').click()
        assert photos_authorization.value.status == 200
        page.wait_for_function("() => document.querySelector('#sourceManagerDialog')?.open")
        page.wait_for_function("() => document.querySelector('#toastMessage')?.textContent.includes('Synthetic Mac authorization completed')")
        assert source_actions[-1]["action"] == "requestPhotosWriteAuthorization"
        page.locator("#sourceManagerCloseButton").click()

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
            f"() => document.activeElement?.dataset.sourceAction === 'delete'"
            f" && document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        page.locator(
            f'#sourceManagerList [data-source-action="delete"]'
            f'[data-source-id="{SOURCE_ID}"]'
        ).click()
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
            f"() => document.activeElement?.dataset.sourceAction === 'delete'"
            f" && document.activeElement?.dataset.sourceId === '{SOURCE_ID}'"
        )
        page.locator("#sourceManagerCloseButton").click()

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
            page.locator("#currentSourceRefreshButton").click()
        assert current_folder_rescan.value.status == 200
        assert source_actions[-1]["action"] == "rescan"
        assert source_actions[-1]["sourceID"] == FOLDER_SOURCE_ID

        sources[1]["state"] = "authorizationRequired"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as folder_authorization_refresh:
            page.locator("#refreshButton").click()
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
            page.locator("#refreshButton").click()
        assert folder_active_refresh.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#emptySourceRecoveryButton')?.textContent === '立即重扫'"
        )

        folder_button.click(button="right")
        folder_menu_labels = page.locator("#sourceContextMenuActions button").all_inner_texts()
        assert folder_menu_labels == [
            "在图库中查看",
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
        page.wait_for_function("() => document.querySelector('#sourceManagerDialog')?.open")
        page.wait_for_function("() => document.querySelector('#toastMessage')?.textContent.includes('Synthetic Mac authorization completed')")
        assert source_actions[-1]["action"] == "refreshFolderMutationAuthorization"
        page.screenshot(path="/tmp/imageall-source-authorization-synthetic.png", full_page=True)
        page.locator("#sourceManagerCloseButton").click()

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

        page.locator("#sourceManagerButton").click()
        page.locator("#sourceManagerList .source-manager-row").first.wait_for()
        page.keyboard.press("Escape")
        assert page.evaluate("() => document.activeElement?.id") == "sourceManagerButton"

        page.locator("#storageButton").click()
        page.locator("#storageContent:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.activeElement?.id === 'storageRefreshButton'"
        )
        page.keyboard.press("ArrowDown")
        assert page.evaluate("() => document.activeElement?.id") != "storageRefreshButton"
        page.keyboard.press("Escape")
        assert page.evaluate("() => document.activeElement?.id") == "storageButton"

        page.set_viewport_size({"width": 390, "height": 844})
        page.keyboard.press("Meta+,")
        page.locator("#generalSettingsDialog").wait_for()
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
        threshold_dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert threshold_dimensions["scroll"] <= threshold_dimensions["viewport"], threshold_dimensions
        assert page.locator("#suggestionThresholdSearch").is_visible()
        page.screenshot(path="/tmp/imageall-suggestion-thresholds-synthetic.png", full_page=True)
        page.keyboard.press("Escape")
        page.keyboard.press("Escape")

        assert not page_errors, page_errors
        assert not console_errors, {"console": console_errors, "resources": failed_resources}
        assert not failed_resources, failed_resources
        browser.close()

    assert len(updates) == 12, updates
    print(f"general-settings-keyboard-browser: ok; updates={len(updates)}")


if __name__ == "__main__":
    main()
