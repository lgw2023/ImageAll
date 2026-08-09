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
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
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
        page.route(
            "**/v1/assets?**",
            lambda route: fulfill_json(route, {"items": [], "nextCursor": None}),
        )
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
            source = next(item for item in sources if item["id"] == payload["sourceID"])
            request = {
                "id": f"99999999-0000-4000-8000-{len(source_actions):012d}",
                "operationID": payload["operationID"],
                "action": payload["action"],
                "sourceID": payload["sourceID"],
                "sourceDisplayName": source["displayName"],
                "phase": "completed",
                "message": "Synthetic Mac authorization completed",
                "updatedAtMs": 1_700_000_000_000 + len(source_actions),
            }
            source_requests.insert(0, request)
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
        assert page.locator("#emptySourceRecoveryButton").inner_text() == "重新授权…"

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

        sources[0]["state"] = "active"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as active_refresh:
            page.locator("#refreshButton").click()
        assert active_refresh.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#emptySourceRecoveryButton')?.textContent === '立即同步'"
        )

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

        folder_button = page.locator(f'#sourceList [data-source-id="{FOLDER_SOURCE_ID}"]')
        folder_button.click()
        page.wait_for_function(
            "() => document.querySelector('#emptyStateTitle')?.textContent === '没有支持的照片'"
        )
        assert page.locator("#emptySourceRecoveryButton").inner_text() == "立即重扫"

        sources[1]["state"] = "authorizationRequired"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sources")
        ) as folder_authorization_refresh:
            page.locator("#refreshButton").click()
        assert folder_authorization_refresh.value.status == 200
        page.wait_for_function(
            "() => document.querySelector('#emptyStateTitle')?.textContent === '需要重新授权文件夹'"
        )
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
        page.keyboard.press("ArrowDown")
        assert page.evaluate("() => document.activeElement?.id") == "sourceManagerRefreshButton"
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
