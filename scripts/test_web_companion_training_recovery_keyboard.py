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
    workspace_requests = []
    page_errors = []
    console_errors = []
    failed_resources = []
    activity_updated_at_ms = [int(time.time() * 1000)]

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
        page.route("**/v1/jobs", lambda route: fulfill_json(route, [
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
        ]))
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
                {"mediaKind": "image", "isAvailable": False, "maximumSampleCount": 0, "activities": []},
            ),
        )
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
                        "phase": "completed",
                        "completedUnitCount": 3,
                        "totalUnitCount": 3,
                        "sampleCount": None,
                        "errorCode": "staleSnapshot",
                        "availableActions": [],
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
        page.keyboard.press("Escape")
        assert page.locator("#personalModelPopover").is_hidden()
        page.wait_for_function("() => document.activeElement?.id === 'personalModelButton'")

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
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)?.getAttribute('aria-selected') === 'true'",
            arg=FAILED_RUN_ID,
        )

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
            f'[data-review-training-job-id="{JOB_ID}"]'
        ).click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator("#closeTrainingButton").get_attribute("aria-label") == "返回建议审核"
        assert page.locator(
            f'[data-training-run-id="{FAILED_RUN_ID}"]'
        ).get_attribute("aria-selected") == "true"
        page.keyboard.press("Escape")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for(state="visible")
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
        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').focus()

        page.keyboard.press("j")
        page.locator("#jobsPopover:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=JOB_ID,
        )
        page.keyboard.press("ArrowDown")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=SECOND_JOB_ID,
        )
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
        assert not page_errors, page_errors
        assert not failed_resources, failed_resources
        assert not console_errors, console_errors
        context.close()
        browser.close()

    print("training-recovery-keyboard-browser: ok")


if __name__ == "__main__":
    main()
