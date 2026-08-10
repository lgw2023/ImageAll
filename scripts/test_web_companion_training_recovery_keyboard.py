#!/usr/bin/env python3
import json
import re
import time

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8805"
TAG_ID = "11111111-aaaa-bbbb-cccc-111111111111"
SECOND_TAG_ID = "11111111-aaaa-bbbb-cccc-222222222222"
THIRD_TAG_ID = "11111111-aaaa-bbbb-cccc-333333333333"
ACTIVE_SOURCE_ID = "22222222-aaaa-bbbb-cccc-222222222222"
REMOVED_SOURCE_ID = "33333333-aaaa-bbbb-cccc-333333333333"
FAILED_RUN_ID = "44444444-aaaa-bbbb-cccc-444444444444"
PERSONAL_RUN_ID = "55555555-aaaa-bbbb-cccc-555555555555"
LEGACY_RUN_ID = "66666666-aaaa-bbbb-cccc-666666666666"
BATCH_ID = "99999999-aaaa-bbbb-cccc-999999999999"
JOB_ID = "88888888-aaaa-bbbb-cccc-111111111111"
SECOND_JOB_ID = "88888888-aaaa-bbbb-cccc-222222222222"


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def main():
    launches = []
    sample_requests = []
    workspace_requests = []
    jobs_requests = []
    training_activity_actions = []
    jobs_fail_next = [False]
    page_errors = []
    console_errors = []
    failed_resources = []
    unexpected_dialogs = []
    activity_updated_at_ms = [int(time.time() * 1000)]
    activity_phase = ["completed"]

    runs = [
        {
            "id": FAILED_RUN_ID,
            "mediaKind": "image",
            "method": "featureKnn",
            "state": "failed",
            "createdAtMs": 1_700_000_003_000,
            "startedAtMs": 1_700_000_003_500,
            "finishedAtMs": 1_700_000_004_000,
            "catalogScopeID": "scope-v1",
            "jobID": JOB_ID,
            "tagID": TAG_ID,
            "tagDisplayName": "猫",
            "batchID": None,
            "batchTagIndex": None,
            "batchTagCount": None,
            "sampleCount": 12,
            "positiveSampleCount": 7,
            "negativeSampleCount": 5,
            "sampleSummaryJSON": "{}",
            "configJSON": "{}",
            "metricsJSON": "{}",
            "resultSummaryJSON": "{}",
            "errorCode": "staleSnapshot",
            "recoveryContext": {
                "tagIDs": [TAG_ID],
                "sourceIDs": [ACTIVE_SOURCE_ID, REMOVED_SOURCE_ID],
                "scope": "selectedSources",
                "isExact": True,
                "note": "已恢复原来选定的来源。",
            },
            "failureGuidance": {
                "title": "训练数据已经变化",
                "message": "标签决定在训练期间发生了变化，旧快照不能继续使用。",
                "suggestedAction": "使用最新标签和范围重新配置。",
            },
        },
        {
            "id": PERSONAL_RUN_ID,
            "mediaKind": "image",
            "method": "personalCentroid",
            "state": "succeeded",
            "createdAtMs": 1_700_000_002_000,
            "startedAtMs": 1_700_000_002_100,
            "finishedAtMs": 1_700_000_002_900,
            "catalogScopeID": "scope-v1",
            "tagID": TAG_ID,
            "tagDisplayName": "猫",
            "batchID": BATCH_ID,
            "batchTagIndex": 0,
            "batchTagCount": 3,
            "sampleCount": 8,
            "positiveSampleCount": 8,
            "negativeSampleCount": 0,
            "sampleSummaryJSON": json.dumps({"batchID": BATCH_ID}),
            "configJSON": "{}",
            "metricsJSON": "{}",
            "resultSummaryJSON": "{}",
            "errorCode": None,
        },
        {
            "id": LEGACY_RUN_ID,
            "mediaKind": "image",
            "method": "featureKnn",
            "state": "cancelled",
            "createdAtMs": 1_700_000_001_000,
            "catalogScopeID": "scope-v1",
            "tagID": None,
            "tagDisplayName": None,
            "batchID": None,
            "sampleSummaryJSON": "{}",
            "configJSON": "{}",
            "metricsJSON": "{}",
            "resultSummaryJSON": "{}",
            "errorCode": None,
            "recoveryContext": {
                "tagIDs": [],
                "sourceIDs": [],
                "scope": "unresolved",
                "isExact": False,
                "note": "这条旧记录没有保存来源明细，请重新选择来源后再启动。",
            },
        },
    ]

    jobs_payload = [
        {
            "id": JOB_ID,
            "kind": "personalizationSuggestions",
            "state": "retryableFailed",
            "progress": {"completedUnitCount": 3, "totalUnitCount": 12},
            "availableActions": ["resume"],
            "controlRequest": "none",
            "attempts": 1,
            "maxAttempts": 3,
            "lastErrorCode": "staleSnapshot",
        },
        {
            "id": SECOND_JOB_ID,
            "kind": "background",
            "state": "completed",
            "progress": {"completedUnitCount": 1, "totalUnitCount": 1},
            "availableActions": [],
            "controlRequest": "none",
        },
    ]
    jobs_payload.extend({
        "id": f"88888888-aaaa-bbbb-cccc-{index:012d}",
        "kind": "background",
        "state": "completed",
        "progress": {"completedUnitCount": index, "totalUnitCount": index},
        "availableActions": [],
        "controlRequest": "none",
    } for index in range(3, 20))

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True,
            executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        context = browser.new_context(
            viewport={"width": 1280, "height": 900},
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
            "dialog",
            lambda dialog: (unexpected_dialogs.append(dialog.message), dialog.dismiss()),
        )
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
                {"authenticated": True, "authMode": "account", "username": "fixture"},
            ),
        )
        page.route(
            "**/v1/capabilities",
            lambda route: fulfill_json(
                route,
                {
                    "protocolVersion": 1,
                    "hostID": "77777777-aaaa-bbbb-cccc-777777777777",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                },
            ),
        )
        page.route(
            "**/v1/sources",
            lambda route: fulfill_json(
                route,
                [{
                    "id": ACTIVE_SOURCE_ID,
                    "kind": "photos",
                    "displayName": "Apple Photos",
                    "state": "active",
                }],
            ),
        )
        page.route("**/v1/tags", lambda route: fulfill_json(route, [
            {"id": TAG_ID, "displayName": "猫", "state": "active", "groupID": None},
            {"id": SECOND_TAG_ID, "displayName": "旅行", "state": "active", "groupID": None},
            {"id": THIRD_TAG_ID, "displayName": "家人", "state": "active", "groupID": None},
        ]))
        page.route("**/v1/tag-groups", lambda route: fulfill_json(route, []))
        def route_jobs(route):
            jobs_requests.append(route.request.url)
            if jobs_fail_next[0]:
                jobs_fail_next[0] = False
                fulfill_json(route, {"error": {"message": "活动暂时不可用"}}, status=503)
                return
            fulfill_json(route, jobs_payload)

        page.route("**/v1/jobs", route_jobs)
        page.route("**/v1/assets?**", lambda route: fulfill_json(route, {"items": [], "nextCursor": None}))
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
                {"mediaKind": "image", "isAvailable": True, "maximumSampleCount": 500, "activities": []},
            ),
        )

        def route_sample_suggestion_request(route):
            payload = route.request.post_data_json
            sample_requests.append(payload)
            fulfill_json(route, {
                "activity": {
                    "operationID": payload["operationID"],
                    "phase": "completed",
                    "completedUnitCount": 0,
                    "totalUnitCount": 0,
                    "suggestedCount": 0,
                    "skippedCount": 0,
                    "errorCode": None,
                    "availableActions": [],
                },
                "replayed": False,
            }, status=202)

        page.route("**/v1/sample-suggestions/requests", route_sample_suggestion_request)
        page.route(
            "**/v1/tag-library-suggestions?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "maximumPendingCount": 25,
                    "personalCentroidAvailable": False,
                    "personalAdamWAvailable": False,
                    "tags": [],
                    "activities": [],
                },
            ),
        )
        def route_training_workspace(route):
            workspace_requests.append(route.request.url)
            fulfill_json(route, {
                    "mediaKind": "image",
                    "methodFilter": None,
                    "runs": runs,
                    "slots": [
                        {
                            "method": "featureKnn",
                            "isPublished": False,
                            "publishedRunID": None,
                            "artifactRef": None,
                        },
                        {
                            "method": "personalCentroid",
                            "isPublished": True,
                            "publishedRunID": PERSONAL_RUN_ID,
                            "artifactRef": "personal-model://current/image",
                        },
                        {
                            "method": "personalAdamW",
                            "isPublished": False,
                            "publishedRunID": None,
                            "artifactRef": None,
                        },
                    ],
                    "activities": [{
                        "operationID": BATCH_ID,
                        "mediaKind": "image",
                        "method": "personalCentroid",
                        "phase": activity_phase[0],
                        "completedUnitCount": 3,
                        "totalUnitCount": 3,
                        "sampleCount": None,
                        "errorCode": "staleSnapshot",
                        "availableActions": ["cancel"] if activity_phase[0] not in {
                            "completed", "failed", "cancelled"
                        } else [],
                        "acceptedAtMs": activity_updated_at_ms[0] - 2_000,
                        "updatedAtMs": activity_updated_at_ms[0],
                        "tagActivities": [
                            {"tagID": TAG_ID, "displayName": "猫", "phase": "succeeded", "sampleCount": 12},
                            {"tagID": SECOND_TAG_ID, "displayName": "旅行", "phase": "failed", "sampleCount": 8, "errorCode": "staleSnapshot"},
                            {"tagID": THIRD_TAG_ID, "displayName": "家人", "phase": "skipped", "errorCode": "insufficientSamples"},
                        ],
                    }],
                })

        page.route("**/v1/training/workspace?**", route_training_workspace)
        page.route(
            "**/v1/training/setup?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "tags": [
                        {
                            "id": TAG_ID,
                            "displayName": "猫",
                            "acceptedSampleCount": 12,
                            "rejectedSampleCount": 9,
                            "featureMode": "update",
                            "personalEligible": True,
                        },
                        {
                            "id": SECOND_TAG_ID,
                            "displayName": "旅行",
                            "acceptedSampleCount": 8,
                            "rejectedSampleCount": 4,
                            "featureMode": None,
                            "personalEligible": True,
                        },
                        {
                            "id": THIRD_TAG_ID,
                            "displayName": "家人",
                            "acceptedSampleCount": 3,
                            "rejectedSampleCount": 1,
                            "featureMode": None,
                            "personalEligible": True,
                        },
                    ],
                    "sources": [{"id": ACTIVE_SOURCE_ID, "displayName": "Apple Photos"}],
                    "methods": [
                        {"method": "featureKnn", "isAvailable": True},
                        {"method": "personalCentroid", "isAvailable": True},
                        {"method": "personalAdamW", "isAvailable": False},
                    ],
                },
            ),
        )

        def route_training_launch(route):
            launches.append(route.request.post_data_json)
            fulfill_json(
                route,
                {
                    "operationID": launches[-1]["operationID"],
                    "method": launches[-1]["method"],
                    "acceptedAtMs": 1_700_000_005_000,
                    "scheduledTagCount": 1,
                    "jobID": "88888888-aaaa-bbbb-cccc-888888888888",
                    "replayed": False,
                },
                status=202,
            )

        page.route("**/v1/training/launch", route_training_launch)

        def route_training_activity_action(route):
            payload = route.request.post_data_json
            training_activity_actions.append(payload)
            activity_phase[0] = "cancelled"
            activity_updated_at_ms[0] = int(time.time() * 1000)
            fulfill_json(route, {
                "activity": {
                    "operationID": BATCH_ID,
                    "mediaKind": "image",
                    "method": "personalCentroid",
                    "phase": "cancelled",
                    "completedUnitCount": 3,
                    "totalUnitCount": 3,
                    "sampleCount": None,
                    "errorCode": None,
                    "availableActions": [],
                    "acceptedAtMs": activity_updated_at_ms[0] - 2_000,
                    "updatedAtMs": activity_updated_at_ms[0],
                    "tagActivities": [
                        {"tagID": TAG_ID, "displayName": "猫", "phase": "succeeded", "sampleCount": 12},
                        {"tagID": SECOND_TAG_ID, "displayName": "旅行", "phase": "failed", "sampleCount": 8, "errorCode": "staleSnapshot"},
                        {"tagID": THIRD_TAG_ID, "displayName": "家人", "phase": "skipped", "errorCode": "insufficientSamples"},
                    ],
                }
            })

        page.route("**/v1/training/activities/*/actions", route_training_activity_action)
        page.route(
            "**/v1/review/overview?**",
            lambda route: fulfill_json(route, {
                "mediaKind": "image",
                "totalPendingSuggestionCount": 0,
                "tags": [{
                    "id": TAG_ID,
                    "displayName": "猫",
                    "acceptedSampleCount": 12,
                    "rejectedSampleCount": 9,
                    "pendingSuggestionCount": 0,
                    "pendingSuggestionCounts": {},
                    "taskStatus": "ready",
                    "checkedCount": 0,
                    "totalCount": None,
                    "skippedCount": 0,
                    "canGenerate": True,
                    "canUpdate": False,
                    "canGeneratePersonalModel": True,
                    "canReview": False,
                    "canPause": False,
                    "canResume": False,
                    "canCancel": False,
                    "activeJobID": JOB_ID,
                }],
            }),
        )

        page.goto(BASE_URL, wait_until="networkidle")
        page.locator(f'[data-quick-tag-id="{TAG_ID}"]').click()
        page.wait_for_function(
            "tagID => document.querySelector(`[data-quick-tag-id='${tagID}']`)?.getAttribute('aria-pressed') === 'true'",
            arg=TAG_ID,
        )
        page.locator("#personalModelButton").click()
        page.locator("#personalModelPopover:not(.hidden)").wait_for(state="visible")
        assert "猫" in page.locator("#personalModelScopeSummary").inner_text()
        assert "全库照片" in page.locator("#personalModelScopeSummary").inner_text()
        page.wait_for_function(
            "() => document.activeElement?.id === 'rebuildPersonalModelButton'"
        )
        page.keyboard.press("ArrowDown")
        page.wait_for_function(
            "() => document.activeElement?.id === 'rebuildPersonalAdamWButton'"
        )
        page.keyboard.press("ArrowDown")
        page.wait_for_function(
            "() => document.activeElement?.id === 'generatePersonalSuggestionsButton'"
        )
        assert page.locator("#generatePersonalSuggestionsTitle").inner_text() == "抽 500 张生成建议"
        assert page.locator("#searchInput").get_attribute("placeholder") == "搜索文件名、路径、标签或来源"
        with page.expect_response(
            lambda response: response.url.endswith("/v1/sample-suggestions/requests")
            and response.request.method == "POST"
        ) as sample_response:
            page.keyboard.press("Enter")
        assert sample_response.value.status == 202
        assert sample_requests[-1]["assetIDs"] == []
        assert sample_requests[-1]["sourceIDs"] is None
        page.locator("#reviewWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator("#closeReviewButton").get_attribute("aria-label") == "返回图库"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "review"
        page.locator("#closeReviewButton").click()
        page.locator("#reviewWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )

        page.locator("#personalModelButton").click()
        page.locator("#rebuildPersonalModelButton").click()
        page.locator("#trainingSetupDialog").wait_for(state="visible")
        page.wait_for_function("() => !state.training.setup.loading")
        assert page.locator(
            '[data-training-setup-method="personalCentroid"]'
        ).get_attribute("aria-checked") == "true"
        assert page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        assert "已从图库筛选带入 1 个已确认标签" in page.locator(
            "#trainingSetupNotice"
        ).inner_text()
        assert page.locator('[data-training-scope="allSources"]').is_checked()
        page.keyboard.press("Escape")
        page.wait_for_function("() => document.activeElement?.id === 'personalModelButton'")

        page.evaluate(
            "state.selectedAssetIDs = new Set(['synthetic-selection']); renderSelectionBar()"
        )
        page.locator("#personalModelButton").click()
        assert "当前选择 1 项" in page.locator("#personalModelScopeSummary").inner_text()
        page.locator("#rebuildPersonalModelButton").click()
        page.locator("#trainingSetupDialog").wait_for(state="visible")
        page.wait_for_function("() => !state.training.setup.loading")
        assert page.locator('[data-training-scope="currentSelection"]').is_checked()
        page.keyboard.press("Escape")
        page.evaluate("state.selectedAssetIDs.clear(); renderSelectionBar()")

        page.locator("#personalModelButton").click()
        page.locator("#rebuildPersonalAdamWButton").click()
        page.locator("#trainingSetupDialog").wait_for(state="visible")
        page.wait_for_function("() => !state.training.setup.loading")
        adamw_method = page.locator('[data-training-setup-method="personalAdamW"]')
        assert adamw_method.get_attribute("aria-checked") == "true", page.locator(
            "[data-training-setup-method]"
        ).evaluate_all(
            "items => items.map(item => ({ method: item.dataset.trainingSetupMethod, checked: item.getAttribute('aria-checked') }))"
        )
        assert "尚未提供此训练能力" in page.locator(
            "#trainingSetupNotice"
        ).inner_text()
        assert page.locator("#launchTrainingButton").is_disabled()
        page.keyboard.press("Escape")

        page.locator("#commandButton").click()
        page.locator("#commandSearchInput").fill("超级个人模型")
        assert page.locator('[data-command-id="rebuildPersonalAdamW"]').count() == 1
        page.keyboard.press("Escape")

        page.locator("#trainingButton").click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator("#closeTrainingButton").get_attribute("aria-label") == "返回图库"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "training"
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)?.getAttribute('aria-selected') === 'true'",
            arg=FAILED_RUN_ID,
        )
        assert page.locator("#newTrainingButton").get_attribute(
            "data-help-kind"
        ) == "training"
        assert "目标标签、训练方法" in page.locator(
            "#newTrainingButton"
        ).get_attribute("data-help-detail")
        assert page.locator("#trainingMethodFilter").get_attribute(
            "data-help-title"
        ) == "筛选训练方法"
        assert page.locator("#trainingRecordScopeFilter").get_attribute(
            "data-help-title"
        ) == "筛选记录类型"
        failed_run_row = page.locator(
            f'[data-training-run-id="{FAILED_RUN_ID}"]'
        )
        assert failed_run_row.get_attribute(
            "aria-keyshortcuts"
        ) == "ArrowUp ArrowDown Home End Meta+K"
        assert "点击查看数据、配置、过程、产物和失败恢复" in failed_run_row.get_attribute(
            "data-help-detail"
        )
        failed_run_row.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=1_500)
        assert "相似照片 · 猫" in page.locator("#persistentHelpTitle").inner_text()
        assert "上/下或 Home/End" in page.locator("#persistentHelpDetail").inner_text()
        page.screenshot(
            path="/tmp/imageall-training-persistent-help.png",
            full_page=True,
        )
        page.mouse.move(8, 8)
        page.locator("#persistentHelp").wait_for(state="hidden")
        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').focus()
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        assert page.locator("#commandContextLabel").inner_text() == "当前：训练工程"
        assert page.locator('[data-command-id="selectAll"]').count() == 0
        assert page.locator('[data-command-id="media:video"]').count() == 1
        page.keyboard.press("Escape")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=FAILED_RUN_ID,
        )
        page.keyboard.press("Meta+K")
        page.locator('[data-command-id="media:video"]').click()
        page.wait_for_function(
            "() => state.training.mediaKind === 'video' && !state.training.loading"
        )
        assert "mediaKind=video" in workspace_requests[-1]
        assert page.locator("#trainingWorkspace").is_visible()
        page.keyboard.press("Meta+K")
        assert page.locator("#commandContextLabel").inner_text() == "当前：训练工程"
        page.locator('[data-command-id="media:image"]').click()
        page.wait_for_function(
            "() => state.training.mediaKind === 'image' && !state.training.loading"
        )
        assert "mediaKind=image" in workspace_requests[-1]
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)?.getAttribute('aria-selected') === 'true'",
            arg=FAILED_RUN_ID,
        )
        training_refresh_count = len(workspace_requests)
        training_refresh_generation = page.evaluate(
            "() => state.training.requestGeneration"
        )
        page.keyboard.press("Meta+K")
        assert "刷新训练工程" in page.locator(
            '[data-command-id="refresh"]'
        ).inner_text()
        page.locator('[data-command-id="refresh"]').click()
        page.wait_for_function(
            "generation => state.training.requestGeneration > generation && !state.training.loading",
            arg=training_refresh_generation,
        )
        assert len(workspace_requests) == training_refresh_count + 1
        assert page.locator("#trainingWorkspace").is_visible()
        page.keyboard.press("Meta+K")
        page.locator('[data-command-id="openReview"]').click()
        page.locator("#reviewWorkspace:not(.hidden)").wait_for()
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "review"
        page.evaluate("() => history.back()")
        page.locator("#trainingWorkspace:not(.hidden)").wait_for()
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)?.getAttribute('aria-selected') === 'true'",
            arg=FAILED_RUN_ID,
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "training"

        assert page.locator("#trainingErrorTitle").inner_text() == "训练数据已经变化"
        assert "旧快照不能继续使用" in page.locator("#trainingErrorMessage").inner_text()
        assert page.locator("#trainingErrorCode").inner_text() == "staleSnapshot"
        assert "猫" in page.locator("#trainingDetailContext").inner_text()
        assert "单项记录" in page.locator("#trainingDetailContext").inner_text()
        assert "12 个样本" in page.locator("#trainingDetailContext").inner_text()
        assert "2 个选定来源" in page.locator("#trainingFactLedger").inner_text()
        assert "猫" in page.locator(
            f'[data-training-run-id="{FAILED_RUN_ID}"] .training-run-row-context'
        ).inner_text()
        assert "单项" in page.locator(
            f'[data-training-run-id="{FAILED_RUN_ID}"] .training-run-row-context'
        ).inner_text()

        assert page.locator("[data-training-slot-method]").count() == 3
        personal_slot = page.locator(
            '[data-training-slot-method="personalCentroid"]'
        )
        assert "模型已就绪" in personal_slot.inner_text()
        assert "8 个样本" in personal_slot.inner_text()
        assert PERSONAL_RUN_ID[:8] in personal_slot.inner_text()
        personal_slot.click()
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=PERSONAL_RUN_ID,
        )
        assert page.locator(
            f'[data-training-run-id="{PERSONAL_RUN_ID}"]'
        ).get_attribute("aria-selected") == "true"
        page.keyboard.press("m")
        page.wait_for_function(
            "() => document.activeElement?.dataset.trainingSlotMethod === 'personalCentroid'"
        )
        page.keyboard.press("ArrowLeft")
        page.wait_for_function(
            "() => document.activeElement?.dataset.trainingSlotMethod === 'featureKnn'"
        )

        page.keyboard.press("b")
        assert page.locator("#trainingRecordScopeFilter").input_value() == "batch"
        assert page.locator("[data-training-run-id]").count() == 1
        assert page.locator(f'[data-training-run-id="{PERSONAL_RUN_ID}"]').is_visible()
        page.keyboard.press("b")
        assert page.locator("#trainingRecordScopeFilter").input_value() == "single"
        assert page.locator("[data-training-run-id]").count() == 2
        assert page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').is_visible()
        page.keyboard.press("b")
        assert page.locator("#trainingRecordScopeFilter").input_value() == "all"
        assert page.locator("[data-training-run-id]").count() == 3
        assert page.locator(".training-tag-activity").count() == 3
        assert "完成 1" in page.locator(".training-activity-summary").inner_text()
        assert "失败 1" in page.locator(".training-activity-summary").inner_text()
        assert "跳过 1" in page.locator(".training-activity-summary").inner_text()
        assert page.locator("#trainingBatchHistory").is_visible()
        assert page.locator(".training-batch-card.partial").count() == 1
        assert "部分完成" in page.locator(".training-batch-card").inner_text()
        assert "完成 1" in page.locator(".training-batch-card").inner_text()

        activity_phase[0] = "preparingEmbeddings"
        activity_updated_at_ms[0] = int(time.time() * 1000)
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        assert page.locator("#newTrainingButton").is_disabled()
        assert "正在运行" in page.locator("#newTrainingButton").get_attribute("title")
        page.keyboard.press("n")
        assert not page.locator("#trainingSetupDialog").evaluate("element => element.open")
        assert "当前已有个人模型训练正在运行" in page.locator("#toastMessage").inner_text()

        cancel_training = page.locator(
            f'[data-training-activity-id="{BATCH_ID}"][data-action="cancel"]'
        )
        cancel_training.click()
        page.locator("#confirmDialog[open]").wait_for()
        assert page.locator("#confirmDialog").get_attribute("data-tone") == "warning"
        assert "已经训练并发布成功的标签会继续保留" in page.locator(
            "#confirmDialogMessage"
        ).inner_text()
        page.locator("#cancelConfirmButton").click()
        assert not training_activity_actions
        page.wait_for_function(
            "operationID => document.activeElement?.dataset.trainingActivityId === operationID",
            arg=BATCH_ID,
        )
        cancel_training.click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#confirmActionButton").click()
        page.wait_for_function("() => !document.querySelector('#confirmDialog').open")
        assert training_activity_actions == [{"action": "cancel"}]
        page.wait_for_function("() => document.activeElement?.id === 'refreshTrainingButton'")

        activity_phase[0] = "completed"
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        assert not page.locator("#newTrainingButton").is_disabled()

        page.locator(".training-activity-summary").get_by_role(
            "button", name="重新处理未完成标签"
        ).click()
        dialog = page.locator("#trainingSetupDialog")
        dialog.wait_for(state="visible")
        page.locator(f'[data-training-tag-id="{SECOND_TAG_ID}"]').wait_for(state="attached")
        assert not page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        assert page.locator(f'[data-training-tag-id="{SECOND_TAG_ID}"]').is_checked()
        assert page.locator(f'[data-training-tag-id="{THIRD_TAG_ID}"]').is_checked()
        assert "只重新选择 2 个未完成标签" in page.locator("#trainingSetupNotice").inner_text()
        page.locator("#launchTrainingButton").click()
        page.wait_for_function("() => !document.querySelector('#trainingSetupDialog').open")
        assert launches[0]["method"] == "personalCentroid"
        assert set(launches[0]["tagIDs"]) == {SECOND_TAG_ID, THIRD_TAG_ID}

        activity_updated_at_ms[0] = int(time.time() * 1000) - 60_000
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        assert page.locator("#trainingActivityStrip").is_hidden()
        assert page.locator("#trainingBatchHistory").is_visible()
        page.locator(f'[data-training-batch-view-id="{BATCH_ID}"]').click()
        assert page.locator(
            f'[data-training-run-id="{PERSONAL_RUN_ID}"]'
        ).get_attribute("aria-selected") == "true"
        assert "批次 1 / 3" in page.locator("#trainingDetailContext").inner_text()
        assert "8 个样本" in page.locator("#trainingDetailContext").inner_text()
        page.locator(".training-technical-details > summary").click()
        assert BATCH_ID in page.locator("#trainingTechnicalBlocks").inner_text()

        original_runs = list(runs)
        scroll_run_ids = []
        for index in range(36):
            run_id = f"77777777-aaaa-bbbb-cccc-{index:012d}"
            scroll_run_ids.append(run_id)
            runs.append({
                "id": run_id,
                "mediaKind": "image",
                "method": "featureKnn",
                "state": "succeeded",
                "createdAtMs": 1_699_999_999_000 - index,
                "startedAtMs": 1_699_999_999_100 - index,
                "finishedAtMs": 1_699_999_999_900 - index,
                "catalogScopeID": "scope-v1",
                "tagID": TAG_ID,
                "tagDisplayName": f"猫 · 历史 {index + 1}",
                "batchID": None,
                "sampleCount": 20 + index,
                "positiveSampleCount": 12,
                "negativeSampleCount": 8,
                "sampleSummaryJSON": json.dumps({
                    "samples": [f"asset-{index}-{sample}" for sample in range(80)]
                }),
                "configJSON": "{}",
                "metricsJSON": "{}",
                "resultSummaryJSON": "{}",
                "errorCode": None,
            })
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "() => document.querySelectorAll('[data-training-run-id]').length === 39"
        )

        long_detail_run = page.locator(
            f'[data-training-run-id="{scroll_run_ids[18]}"]'
        )
        long_detail_run.scroll_into_view_if_needed()
        long_detail_run.click()
        if not page.locator(".training-technical-details").evaluate("element => element.open"):
            page.locator(".training-technical-details > summary").click()
        page.locator("#trainingDetailPane").evaluate(
            "element => { element.scrollTop = element.scrollHeight; }"
        )
        assert page.locator("#trainingDetailPane").evaluate(
            "element => element.scrollTop > 100"
        )

        target_run = page.locator(
            f'[data-training-run-id="{scroll_run_ids[32]}"]'
        )
        target_run.scroll_into_view_if_needed()
        run_scroll_before_selection = page.locator("#trainingRunPane").evaluate(
            "element => element.scrollTop"
        )
        assert run_scroll_before_selection > 100
        target_run.click()
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=scroll_run_ids[32],
        )
        assert abs(page.locator("#trainingRunPane").evaluate(
            "element => element.scrollTop"
        ) - run_scroll_before_selection) <= 1
        assert page.locator("#trainingDetailPane").evaluate(
            "element => element.scrollTop === 0"
        )

        page.locator("#trainingDetailPane").evaluate(
            "element => { element.scrollTop = 160; }"
        )
        detail_scroll_before_refresh = page.locator("#trainingDetailPane").evaluate(
            "element => element.scrollTop"
        )
        assert detail_scroll_before_refresh > 80
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=scroll_run_ids[32],
        )
        assert abs(page.locator("#trainingRunPane").evaluate(
            "element => element.scrollTop"
        ) - run_scroll_before_selection) <= 1
        detail_scroll_after_refresh = page.locator("#trainingDetailPane").evaluate(
            "element => element.scrollTop"
        )
        assert detail_scroll_after_refresh == detail_scroll_before_refresh, (
            detail_scroll_before_refresh,
            detail_scroll_after_refresh,
        )

        page.evaluate("setTrainingRunScope('batch')")
        assert page.locator("#trainingRunPane").evaluate(
            "element => element.scrollTop === 0"
        )
        page.evaluate(
            "runID => { state.training.selectedRunID = runID; setTrainingRunScope('all'); }",
            scroll_run_ids[32],
        )
        assert abs(page.locator("#trainingRunPane").evaluate(
            "element => element.scrollTop"
        ) - run_scroll_before_selection) <= 1

        page.evaluate("() => history.back()")
        page.locator("#trainingWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)?.getAttribute('aria-selected') === 'true'",
            arg=scroll_run_ids[32],
        )
        assert abs(page.locator("#trainingRunPane").evaluate(
            "element => element.scrollTop"
        ) - run_scroll_before_selection) <= 1
        page.locator("#closeTrainingButton").click()
        page.locator("#trainingWorkspace").wait_for(state="hidden")
        page.locator("#trainingButton").click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")

        runs[:] = original_runs
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)?.getAttribute('aria-selected') === 'true'",
            arg=FAILED_RUN_ID,
        )
        assert page.locator("[data-training-run-id]").count() == 3

        page.keyboard.press("l")
        assert page.locator("#trainingWorkspace").evaluate(
            "element => element.classList.contains('navigator-hidden')"
        )
        assert page.locator(".training-run-pane").is_hidden()
        page.keyboard.press("l")
        assert page.locator(".training-run-pane").is_visible()

        first_row = page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]')
        first_row.click()
        first_row.focus()
        page.keyboard.press("ArrowDown")
        assert page.locator(f'[data-training-run-id="{PERSONAL_RUN_ID}"]').get_attribute("aria-selected") == "true"
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=PERSONAL_RUN_ID,
        )

        page.keyboard.press("End")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=LEGACY_RUN_ID,
        )
        page.keyboard.press("Home")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=FAILED_RUN_ID,
        )

        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=FAILED_RUN_ID,
        )
        assert page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').get_attribute("aria-selected") == "true"

        page.keyboard.press("v")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for(state="visible")
        page.locator("#reviewOverviewGrid").get_by_text("猫", exact=True).wait_for(
            state="visible"
        )
        assert "猫" in page.locator("#reviewOverviewGrid").inner_text()
        assert page.locator("#closeReviewButton").get_attribute("aria-label") == "返回训练记录"
        page.locator(
            f'[data-review-control-tag-id="{TAG_ID}"] > summary'
        ).click()
        page.locator(
            f'[data-review-training-job-id="{JOB_ID}"]'
        ).click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator("#closeTrainingButton").get_attribute("aria-label") == "返回建议审核"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "training"
        assert page.locator(
            f'[data-training-run-id="{FAILED_RUN_ID}"]'
        ).get_attribute("aria-selected") == "true"
        page.evaluate("() => history.back()")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "review"
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.reviewTrainingJobId === jobID",
            arg=JOB_ID,
        )
        page.keyboard.press("Escape")
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        page.wait_for_timeout(200)
        assert page.evaluate(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            FAILED_RUN_ID,
        )
        page.evaluate("() => history.forward()")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator("#closeReviewButton").get_attribute("aria-label") == "返回训练记录"
        page.locator("#closeReviewButton").click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=FAILED_RUN_ID,
        )
        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').focus()

        before_open_jobs = len(jobs_requests)
        page.keyboard.press("j")
        page.locator("#jobsPopover:not(.hidden)").wait_for(state="visible")
        page.wait_for_timeout(100)
        assert len(jobs_requests) == before_open_jobs + 1
        assert page.locator("#jobsPopover h2").inner_text() == "活动"
        assert page.locator("#jobsPopover").get_attribute("aria-label") == "活动"
        assert page.locator("#refreshJobsButton").is_visible()
        assert page.locator("#refreshJobsButton").get_attribute("aria-keyshortcuts") == "R"
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=JOB_ID,
        )
        page.keyboard.press("ArrowDown")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=SECOND_JOB_ID,
        )
        page.locator("#jobsList").evaluate("element => { element.scrollTop = 120; }")
        preserved_scroll_top = page.locator("#jobsList").evaluate("element => element.scrollTop")
        assert preserved_scroll_top > 0
        before_jobs_refresh = len(jobs_requests)
        page.keyboard.press("r")
        page.wait_for_timeout(100)
        assert len(jobs_requests) == before_jobs_refresh + 1
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=SECOND_JOB_ID,
        )
        assert abs(
            page.locator("#jobsList").evaluate("element => element.scrollTop")
            - preserved_scroll_top
        ) <= 1

        page.locator("#jobsList").evaluate("element => { element.scrollTop = 160; }")
        preserved_scroll_top = page.locator("#jobsList").evaluate("element => element.scrollTop")
        before_jobs_refresh = len(jobs_requests)
        page.locator("#refreshJobsButton").click()
        page.wait_for_timeout(100)
        assert len(jobs_requests) == before_jobs_refresh + 1
        assert page.evaluate("() => document.activeElement?.id") == "refreshJobsButton"
        assert abs(
            page.locator("#jobsList").evaluate("element => element.scrollTop")
            - preserved_scroll_top
        ) <= 1

        failed_resource_count = len(failed_resources)
        jobs_fail_next[0] = True
        before_jobs_refresh = len(jobs_requests)
        page.locator("#refreshJobsButton").click()
        page.wait_for_timeout(100)
        assert len(jobs_requests) == before_jobs_refresh + 1
        assert page.locator("[data-job-row-id]").count() == len(jobs_payload)
        assert page.locator("#refreshJobsButton").is_enabled()
        assert page.locator("#refreshJobsButton").get_attribute("aria-label") == "重试刷新活动"
        assert page.evaluate("() => document.activeElement?.id") == "refreshJobsButton"
        assert len(failed_resources) == failed_resource_count + 1
        assert failed_resources[-1][0] == 503
        failed_resources.pop()
        assert console_errors and "503" in console_errors[-1]
        console_errors.pop()

        original_jobs = list(jobs_payload)
        jobs_payload.clear()
        page.locator("#refreshJobsButton").click()
        page.wait_for_timeout(100)
        assert page.locator("[data-job-row-id]").count() == 0
        assert page.locator("#refreshJobsButton").get_attribute("aria-label") == "刷新活动"
        assert page.locator("#jobsEmpty").is_visible()
        assert "暂无活动" in page.locator("#jobsEmpty").inner_text()
        assert page.evaluate("() => document.activeElement?.id") == "refreshJobsButton"
        jobs_payload.extend(original_jobs)
        page.locator("#refreshJobsButton").click()
        page.wait_for_timeout(100)
        assert page.locator("[data-job-row-id]").count() == len(original_jobs)

        page.locator(f'[data-job-row-id="{SECOND_JOB_ID}"]').focus()
        page.keyboard.press("Home")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=JOB_ID,
        )
        page.keyboard.press("Enter")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobId === jobID",
            arg=JOB_ID,
        )
        page.keyboard.press("Escape")
        assert page.locator("#jobsPopover").is_hidden()
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=FAILED_RUN_ID,
        )

        before_refresh = len(workspace_requests)
        page.keyboard.press("r")
        page.wait_for_timeout(150)
        assert len(workspace_requests) > before_refresh

        page.keyboard.press("n")
        page.locator("#trainingSetupDialog").wait_for(state="visible")
        page.keyboard.press("Escape")

        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').focus()
        page.keyboard.press("e")
        dialog = page.locator("#trainingSetupDialog")
        dialog.wait_for(state="visible")
        page.wait_for_function(
            "() => document.querySelector('#trainingSetupNotice')?.textContent.includes('1 个历史来源当前不可用')"
        )
        assert page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        assert page.locator("[data-training-source-id]:checked").count() == 1
        assert "1 个历史来源当前不可用" in page.locator("#trainingSetupNotice").inner_text()
        page.locator("#launchTrainingButton").click()
        page.wait_for_function("() => !document.querySelector('#trainingSetupDialog').open")
        assert len(launches) == 2
        assert launches[1]["tagIDs"] == [TAG_ID]
        assert launches[1]["sourceIDs"] == [ACTIVE_SOURCE_ID]

        page.set_viewport_size({"width": 390, "height": 844})
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').focus()
        page.keyboard.press("ArrowDown")
        page.wait_for_timeout(220)
        page.locator("#persistentHelp:not(.hidden)").wait_for()
        help_bounds = page.locator("#persistentHelp").bounding_box()
        assert help_bounds is not None
        assert help_bounds["x"] >= 8
        assert help_bounds["x"] + help_bounds["width"] <= 382
        page.screenshot(
            path="/tmp/imageall-training-persistent-help-390.png",
            full_page=True,
        )
        page.keyboard.press("Escape")
        page.keyboard.press("j")
        page.locator("#jobsPopover:not(.hidden)").wait_for(state="visible")
        popover_bounds = page.locator("#jobsPopover").bounding_box()
        assert popover_bounds is not None
        assert popover_bounds["x"] >= 0
        assert popover_bounds["x"] + popover_bounds["width"] <= 390
        for selector in ["#refreshJobsButton", "#closeJobsButton"]:
            bounds = page.locator(selector).bounding_box()
            assert bounds is not None
            assert bounds["x"] >= popover_bounds["x"]
            assert bounds["x"] + bounds["width"] <= popover_bounds["x"] + popover_bounds["width"]
        page.screenshot(path="/tmp/imageall-jobs-activity-390.png", full_page=True)
        page.locator("#closeJobsButton").click()
        assert not page_errors, page_errors
        assert not failed_resources, failed_resources
        assert not console_errors, console_errors
        assert not unexpected_dialogs, unexpected_dialogs
        context.close()
        browser.close()

    print("training-recovery-keyboard-browser: ok")


if __name__ == "__main__":
    main()
