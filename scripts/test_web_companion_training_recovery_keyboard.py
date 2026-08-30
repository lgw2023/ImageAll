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
    training_activity_requests = []
    training_setup_requests = []
    jobs_fail_next = [False]
    page_errors = []
    console_errors = []
    failed_resources = []
    unexpected_dialogs = []
    activity_updated_at_ms = [int(time.time() * 1000)]
    activity_phase = ["completed"]
    activity_completed_unit_count = [3]
    activity_second_tag_phase = ["failed"]
    toolbar_activity_phase = ["completed"]
    training_sources = [
        {"id": ACTIVE_SOURCE_ID, "displayName": "Apple Photos"},
        *[
            {
                "id": f"22222223-aaaa-bbbb-cccc-{index:012d}",
                "displayName": f"合成训练来源 {index}",
            }
            for index in range(1, 13)
        ],
    ]

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
            "metricsJSON": json.dumps({
                "schemaVersion": 1,
                "evaluationSplit": "validation",
                "trainSampleCount": 6,
                "validationSampleCount": 2,
                "epochs": [
                    {"epoch": 1, "evaluationLoss": 0.48},
                    {"epoch": 2, "evaluationLoss": 0.31},
                    {"epoch": 3, "evaluationLoss": 0.24},
                    {"epoch": 4, "evaluationLoss": 0.27},
                ],
            }),
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
                    "capabilities": ["trainingActivities"],
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
                        "completedUnitCount": activity_completed_unit_count[0],
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
                            {
                                "tagID": SECOND_TAG_ID,
                                "displayName": "旅行",
                                "phase": activity_second_tag_phase[0],
                                "sampleCount": 8,
                                "errorCode": (
                                    "staleSnapshot"
                                    if activity_second_tag_phase[0] == "failed"
                                    else None
                                ),
                            },
                            {"tagID": THIRD_TAG_ID, "displayName": "家人", "phase": "skipped", "errorCode": "insufficientSamples"},
                        ],
                    }],
                })

        page.route("**/v1/training/workspace?**", route_training_workspace)
        def route_training_setup(route):
            training_setup_requests.append(route.request.url)
            fulfill_json(
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
                    "sources": training_sources,
                    "methods": [
                        {"method": "featureKnn", "isAvailable": True},
                        {"method": "personalCentroid", "isAvailable": True},
                        {"method": "personalAdamW", "isAvailable": False},
                    ],
                },
            )

        page.route("**/v1/training/setup?**", route_training_setup)

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

        def route_training_activities(route):
            training_activity_requests.append(route.request.url)
            phase = toolbar_activity_phase[0]
            fulfill_json(route, [{
                "operationID": "77777777-aaaa-bbbb-cccc-111111111111",
                "mediaKind": "image",
                "method": "personalCentroid",
                "phase": phase,
                "completedUnitCount": 1,
                "totalUnitCount": 3,
                "sampleCount": 12,
                "errorCode": None,
                "availableActions": ["cancel"] if phase not in {
                    "completed", "failed", "cancelled"
                } else [],
                "acceptedAtMs": 1_700_000_000_000,
                "updatedAtMs": int(time.time() * 1000),
                "tagActivities": [],
            }])

        page.route("**/v1/training/activities?**", route_training_activities)

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
        assert training_activity_requests
        page.locator(f'[data-quick-tag-id="{TAG_ID}"]').click()
        page.wait_for_function(
            "tagID => document.querySelector(`[data-quick-tag-id='${tagID}']`)?.getAttribute('aria-pressed') === 'true'",
            arg=TAG_ID,
        )

        page.set_viewport_size({"width": 2200, "height": 1000})
        page.evaluate("applyToolbarDisplayMode('iconAndTitle')")
        page.wait_for_function(
            "() => getComputedStyle(document.querySelector('#personalModelToolbarActions')).display !== 'none'"
        )
        assert page.locator("#personalModelButton").is_hidden()
        direct_personal_actions = [
            ("#toolbarRebuildPersonalModelButton", "重建个人模型"),
            ("#toolbarRebuildPersonalAdamWButton", "训练超级个人模型"),
            ("#toolbarGeneratePersonalSuggestionsButton", "抽 500 张生成建议"),
        ]
        for selector, label in direct_personal_actions:
            button = page.locator(selector)
            assert button.is_visible(), selector
            assert button.locator(".library-toolbar-label").inner_text() == label
            assert button.get_attribute("data-help-detail"), selector

        toolbar_activity_phase[0] = "preparingEmbeddings"
        setup_request_count = len(training_setup_requests)
        page.evaluate("loadTrainingActivities({ quiet: true })")
        page.wait_for_function(
            "() => document.querySelector('#toolbarRebuildPersonalModelButton').classList.contains('is-running')"
        )
        assert page.locator("#toolbarRebuildPersonalModelButton").is_disabled()
        assert page.locator("#toolbarRebuildPersonalAdamWButton").is_disabled()
        assert page.locator("#toolbarGeneratePersonalSuggestionsButton").is_disabled()
        assert page.locator(
            "#toolbarRebuildPersonalModelButton .library-toolbar-label"
        ).inner_text() == "正在重建…"
        assert page.locator("#toolbarRebuildPersonalModelButton").get_attribute(
            "aria-busy"
        ) == "true"
        assert page.locator("#personalModelButton").is_enabled()
        assert "正在重建" in page.locator("#personalModelButton").get_attribute("aria-label")
        command_states = page.evaluate(
            """() => Object.fromEntries(availableCommands()
              .filter(item => ['rebuildPersonalModel', 'rebuildPersonalAdamW', 'generateLibrarySuggestions'].includes(item.id))
              .map(item => [item.id, { disabled: item.disabled, hint: item.hint }]))"""
        )
        assert all(item["disabled"] for item in command_states.values()), command_states
        assert "正在重建" in command_states["rebuildPersonalModel"]["hint"]
        page.screenshot(
            path="/tmp/imageall-personal-model-running-wide.png",
            full_page=False,
        )
        page.evaluate(
            "openLibraryPersonalTraining('personalCentroid', document.querySelector('#toolbarRebuildPersonalModelButton'))"
        )
        assert not page.locator("#trainingSetupDialog").evaluate("element => element.open")
        assert len(training_setup_requests) == setup_request_count

        page.set_viewport_size({"width": 1280, "height": 900})
        page.locator("#personalModelButton").click()
        page.locator("#personalModelPopover:not(.hidden)").wait_for(state="visible")
        assert page.locator("#rebuildPersonalModelButton").is_disabled()
        assert page.locator("#rebuildPersonalAdamWButton").is_disabled()
        assert page.locator("#generatePersonalSuggestionsButton").is_disabled()
        assert page.locator("#rebuildPersonalModelTitle").inner_text() == "正在重建个人模型…"
        page.keyboard.press("Escape")

        toolbar_activity_phase[0] = "completed"
        page.evaluate("loadTrainingActivities({ quiet: true })")
        page.wait_for_function(
            "() => !document.querySelector('#toolbarRebuildPersonalModelButton').classList.contains('is-running')"
        )
        page.set_viewport_size({"width": 2200, "height": 1000})
        assert page.locator("#toolbarRebuildPersonalModelButton").is_enabled()
        assert page.locator(
            "#toolbarRebuildPersonalModelButton .library-toolbar-label"
        ).inner_text() == "重建个人模型"
        page.screenshot(
            path="/tmp/imageall-personal-model-toolbar-wide.png",
            full_page=False,
        )
        page.locator("#toolbarRebuildPersonalModelButton").click()
        page.locator("#trainingSetupDialog").wait_for(state="visible")
        page.wait_for_function("() => !state.training.setup.loading")
        assert page.locator(
            '[data-training-setup-method="personalCentroid"]'
        ).get_attribute("aria-checked") == "true"
        page.evaluate(
            """() => {
              const summary = document.querySelector("#trainingLaunchSummary");
              const task = summary.querySelector(
                'dd[data-training-summary-key="task"]'
              );
              const range = document.createRange();
              range.selectNodeContents(task);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              window.__stableTrainingLaunchSummary = {
                children: [...summary.children],
                task,
                selectedText: selection.toString(),
                mutations: 0,
              };
              window.__stableTrainingLaunchSummary.observer = new MutationObserver(
                (records) => {
                  window.__stableTrainingLaunchSummary.mutations += records.filter(
                    (record) => record.type === "childList"
                  ).length;
                }
              );
              window.__stableTrainingLaunchSummary.observer.observe(
                summary,
                { childList: true }
              );
            }"""
        )
        page.locator(f'[data-training-tag-id="{TAG_ID}"]').click()
        assert not page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        stable_training_launch_summary = page.evaluate(
            """() => {
              const frame = window.__stableTrainingLaunchSummary;
              const summary = document.querySelector("#trainingLaunchSummary");
              const children = [...summary.children];
              frame.observer.disconnect();
              return {
                children: children.length === frame.children.length
                  && children.every(
                    (child, index) => child === frame.children[index]
                  ),
                task: summary.querySelector(
                  'dd[data-training-summary-key="task"]'
                ) === frame.task,
                selection: getSelection().toString() === frame.selectedText
                  && getSelection().toString().includes("快速个人模型"),
                tags: summary.querySelector(
                  'dd[data-training-summary-key="tags"]'
                ).textContent === "尚未选择",
                mutations: frame.mutations,
              };
            }"""
        )
        assert stable_training_launch_summary == {
            "children": True,
            "task": True,
            "selection": True,
            "tags": True,
            "mutations": 0,
        }, stable_training_launch_summary
        page.locator(f'[data-training-tag-id="{TAG_ID}"]').click()
        assert page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        page.keyboard.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.id === 'toolbarRebuildPersonalModelButton'"
        )

        page.set_viewport_size({"width": 1280, "height": 900})
        page.wait_for_function(
            "() => getComputedStyle(document.querySelector('#personalModelToolbarActions')).display === 'none'"
        )
        assert page.locator("#personalModelButton").is_visible()
        page.set_viewport_size({"width": 390, "height": 844})
        if "open" in (page.locator("#sourceSidebar").get_attribute("class") or "").split():
            page.locator("#sidebarToggle").click()
            page.wait_for_function(
                "() => !document.querySelector('#sourceSidebar').classList.contains('open')"
            )
        page.wait_for_timeout(250)
        assert page.locator("#personalModelButton").is_visible()
        assert page.locator("#personalModelToolbarActions").is_hidden()
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        page.screenshot(
            path="/tmp/imageall-personal-model-toolbar-390.png",
            full_page=False,
        )
        page.set_viewport_size({"width": 1280, "height": 900})
        page.locator("#personalModelButton").click()
        page.locator("#personalModelPopover:not(.hidden)").wait_for(state="visible")
        page.set_viewport_size({"width": 2200, "height": 1000})
        page.locator("#personalModelPopover").wait_for(state="hidden")
        assert page.locator("#personalModelToolbarActions").is_visible()
        page.set_viewport_size({"width": 1280, "height": 900})
        page.wait_for_function(
            "() => getComputedStyle(document.querySelector('#personalModelToolbarActions')).display === 'none'"
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

        if page.locator("#trainingButton").is_visible():
            page.locator("#trainingButton").click()
        else:
            page.locator("#compactToolbarMenuButton").click()
            page.locator(
                '[data-compact-toolbar-target="trainingButton"]'
            ).click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator("#closeTrainingButton").get_attribute("aria-label") == "返回图库"
        assert not page.locator("#appView").evaluate("element => element.inert")
        assert page.locator("#sourceSidebar").is_visible()
        assert page.locator("#inspector").is_visible()
        assert page.locator("#trainingWorkspace").get_attribute("role") == "region"
        assert page.locator("#trainingWorkspace").get_attribute("aria-modal") is None
        assert page.locator("#trainingNavigationButton").get_attribute("aria-current") == "page"
        assert page.locator("#libraryTitle").inner_text() == "训练工程"
        assert page.locator("#inspectorTrainingWorkspace").is_visible()
        assert page.locator("#inspectorTrainingWorkspaceTitle").inner_text() == "训练工程"
        assert page.locator("#inspectorTrainingWorkspaceTask").inner_text() == "相似照片"
        assert page.locator("#inspectorTrainingWorkspaceMethod").inner_text() == "Feature Print k-NN"
        assert page.locator("#inspectorTrainingWorkspaceState").inner_text() == "失败"
        training_bounds = page.locator("#trainingWorkspace").bounding_box()
        library_bounds = page.locator("#libraryPane").bounding_box()
        assert training_bounds is not None and library_bounds is not None
        assert training_bounds["x"] >= library_bounds["x"] - 1
        assert training_bounds["y"] >= library_bounds["y"] - 1
        assert training_bounds["x"] + training_bounds["width"] <= (
            library_bounds["x"] + library_bounds["width"] + 1
        )
        assert training_bounds["y"] + training_bounds["height"] <= (
            library_bounds["y"] + library_bounds["height"] + 1
        )
        assert page.locator("#searchForm").evaluate(
            "element => Boolean(element.closest('[inert]'))"
        )
        page.screenshot(
            path="/tmp/imageall-training-integrated.png",
            full_page=True,
        )
        training_shortcut_requests = len(workspace_requests)
        page.locator("#closeTrainingButton").focus()
        page.evaluate("openKeyboardShortcuts({ historyMode: 'none' })")
        page.locator("#shortcutDialog[open]").wait_for()
        assert page.locator("#shortcutContextLabel").inner_text() == "当前：训练工程"
        assert page.locator('[data-shortcut-id="trainingPrimary"]').count() == 1
        assert page.locator('[data-shortcut-id="trainingNavigate"]').count() == 1
        assert page.locator('[data-shortcut-id="reviewDecision"]').count() == 0
        assert page.locator('[data-shortcut-id="galleryNavigate"]').count() == 0
        page.screenshot(
            path="/tmp/imageall-training-context-shortcuts.png",
            full_page=True,
        )
        page.keyboard.press("Escape")
        page.locator("#shortcutDialog").wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'closeTrainingButton'"
        )
        assert len(workspace_requests) == training_shortcut_requests
        training_search_history_length = page.evaluate("history.length")
        training_search_request_count = len(workspace_requests)
        selected_training_run = page.evaluate("state.training.selectedRunID")
        page.locator("#closeTrainingButton").focus()
        page.keyboard.press("Meta+f")
        page.locator("#trainingWorkspace").wait_for(state="hidden")
        page.wait_for_function("() => document.activeElement?.id === 'searchInput'")
        assert page.evaluate("history.length") == training_search_history_length + 1
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "gallery"
        assert not page.locator("#searchForm").evaluate(
            "element => Boolean(element.closest('[inert]'))"
        )
        assert len(workspace_requests) == training_search_request_count
        page.evaluate("history.back()")
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "runID => state.training.selectedRunID === runID && "
            "document.querySelector(`[data-training-run-id='${runID}']`)?.getAttribute('aria-selected') === 'true' && "
            "document.activeElement?.dataset.trainingRunId === runID",
            arg=selected_training_run,
        )
        assert len(workspace_requests) == training_search_request_count + 1
        page.locator(f'[data-training-run-id="{PERSONAL_RUN_ID}"]').click()
        page.wait_for_function(
            "() => document.querySelector('#inspectorTrainingWorkspaceTask')?.textContent === '快速个人模型'"
        )
        assert page.locator("#inspectorTrainingWorkspaceTask").inner_text() == "快速个人模型"
        assert page.locator("#inspectorTrainingWorkspaceState").inner_text() == "已完成"
        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').click()
        page.wait_for_function(
            "() => document.querySelector('#inspectorTrainingWorkspaceTask')?.textContent === '相似照片'"
        )
        page.locator('#libraryNavigation [data-source-id=""]').click()
        page.locator("#trainingWorkspace").wait_for(state="hidden")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "gallery"
        assert page.locator("#inspectorTrainingWorkspace").is_hidden()
        page.locator("#trainingNavigationButton").click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)?.getAttribute('aria-selected') === 'true'",
            arg=FAILED_RUN_ID,
        )
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
        ) == "ArrowUp ArrowDown PageUp PageDown Home End Meta+K"
        assert "点击查看数据、配置、过程、产物和失败恢复" in failed_run_row.get_attribute(
            "data-help-detail"
        )
        failed_run_row.hover()
        page.locator("#persistentHelp:not(.hidden)").wait_for(timeout=1_500)
        assert "相似照片 · 猫" in page.locator("#persistentHelpTitle").inner_text()
        assert "Page Up/Down 按当前可见页幅移动" in page.locator(
            "#persistentHelpDetail"
        ).inner_text()
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
        assert page.locator('[data-command-id="newTrainingTask"]').count() == 1
        assert page.locator('[data-command-id="toggleTrainingNavigator"]').count() == 1
        page.locator('[data-command-id="toggleTrainingNavigator"]').click()
        page.wait_for_function(
            "() => document.querySelector('#trainingWorkspace').classList.contains('navigator-hidden')"
        )
        assert page.evaluate("() => document.activeElement?.id") == "toggleTrainingNavigatorButton"
        page.keyboard.press("Meta+K")
        assert "显示训练记录" in page.locator(
            '[data-command-id="toggleTrainingNavigator"]'
        ).inner_text()
        page.locator('[data-command-id="toggleTrainingNavigator"]').click()
        page.wait_for_function(
            "() => !document.querySelector('#trainingWorkspace').classList.contains('navigator-hidden')"
        )
        failed_run_row.focus()
        page.keyboard.press("Meta+K")
        command_jobs_workspace_requests = len(workspace_requests)
        command_jobs_requests = len(jobs_requests)
        with page.expect_response("**/v1/jobs"):
            page.locator('[data-command-id="openJobs"]').click()
        page.locator("#jobsPopover:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'training' "
            "&& history.state?.imageAllWorkspace?.navigationLevel === 'jobs'"
        )
        assert page.locator("#trainingWorkspace").is_visible()
        assert len(workspace_requests) == command_jobs_workspace_requests
        assert len(jobs_requests) == command_jobs_requests + 1
        page.screenshot(
            path="/tmp/imageall-training-command-activity.png",
            full_page=True,
        )
        page.locator("#closeJobsButton").click()
        page.locator("#jobsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=FAILED_RUN_ID,
        )
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "training"
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
        stable_training_detail = page.evaluate(
            """() => {
              const containers = {
                context: document.querySelector("#trainingDetailContext"),
                facts: document.querySelector("#trainingFactLedger"),
                artifacts: document.querySelector("#trainingArtifactLedger"),
                technical: document.querySelector("#trainingTechnicalBlocks"),
              };
              const scope = containers.facts.querySelector(
                '[data-training-fact-key="scope"] dd'
              );
              const selection = getSelection();
              const range = document.createRange();
              range.selectNodeContents(scope);
              selection.removeAllRanges();
              selection.addRange(range);
              const frame = {
                children: Object.fromEntries(
                  Object.entries(containers).map(([key, container]) => [
                    key,
                    [...container.children],
                  ])
                ),
                scope,
                selectedText: selection.toString(),
                mutations: Object.fromEntries(
                  Object.keys(containers).map((key) => [key, 0])
                ),
                observers: [],
              };
              for (const [key, container] of Object.entries(containers)) {
                const observer = new MutationObserver((records) => {
                  frame.mutations[key] += records.filter(
                    (record) => record.type === "childList"
                  ).length;
                });
                observer.observe(container, { childList: true, subtree: true });
                frame.observers.push(observer);
              }
              state.online = false;
              renderTrainingDetail();
              state.online = true;
              renderTrainingDetail();
              frame.observers.forEach((observer) => observer.disconnect());
              const stable = Object.fromEntries(
                Object.entries(containers).map(([key, container]) => {
                  const children = [...container.children];
                  return [
                    key,
                    children.length === frame.children[key].length
                      && children.every(
                        (child, index) => child === frame.children[key][index]
                      ),
                  ];
                })
              );
              return {
                ...stable,
                scope: containers.facts.querySelector(
                  '[data-training-fact-key="scope"] dd'
                ) === frame.scope,
                selection: selection.toString() === frame.selectedText
                  && selection.toString() === "2 个选定来源",
                mutations: frame.mutations,
              };
            }"""
        )
        assert stable_training_detail == {
            "context": True,
            "facts": True,
            "artifacts": True,
            "technical": True,
            "scope": True,
            "selection": True,
            "mutations": {
                "context": 0,
                "facts": 0,
                "artifacts": 0,
                "technical": 0,
            },
        }, stable_training_detail
        assert page.locator("#trainingMetricHighlights").is_hidden()
        assert page.locator("#trainingLossChart").is_hidden()
        assert page.locator("#trainingMetricEmpty").is_visible()
        assert "没有可绘制的训练曲线" in page.locator(
            "#trainingMetricEmpty"
        ).inner_text()
        assert page.locator("#trainingLossChart").get_attribute("aria-label") == (
            "训练损失曲线：没有可绘制的数据"
        )
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
        cancel_training.focus()
        page.evaluate(
            """operationID => {
              window.__imageAllTrainingActivityAction = document.querySelector(
                `[data-training-activity-id="${CSS.escape(operationID)}"][data-action="cancel"]`
              );
            }""",
            BATCH_ID,
        )
        page.evaluate(
            """secondTagID => {
              const list = document.querySelector('.training-tag-activity-list');
              const items = Object.fromEntries([...list.children].map(
                (item) => [item.dataset.trainingTagActivityId, item]
              ));
              const selectedStatus = items[secondTagID].querySelector(
                ':scope > span:not(.training-tag-activity-mark)'
              );
              const range = document.createRange();
              range.selectNodeContents(selectedStatus);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const frame = {
                list,
                items,
                selectedStatus,
                selectedText: selection.toString(),
                mutations: 0,
              };
              frame.observer = new MutationObserver((records) => {
                frame.mutations += records.filter(
                  (record) => record.type === 'childList'
                ).length;
              });
              frame.observer.observe(list, { childList: true, subtree: true });
              window.__imageAllTrainingTagActivityFrame = frame;
              window.__imageAllTrainingActivityAction.focus({ preventScroll: true });
            }""",
            SECOND_TAG_ID,
        )
        page.locator(
            f'[data-training-tag-activity-id="{SECOND_TAG_ID}"]'
        ).hover()
        page.evaluate(
            "() => window.__imageAllTrainingActivityAction.focus({ preventScroll: true })"
        )
        activity_completed_unit_count[0] = 2
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        assert "2 / 3 个标签" in page.locator(".training-activity-summary").inner_text()
        training_activity_refresh_after = page.evaluate(
            """({ operationID, secondTagID }) => {
              const action = document.querySelector(
                `[data-training-activity-id="${CSS.escape(operationID)}"][data-action="cancel"]`
              );
              const frame = window.__imageAllTrainingTagActivityFrame;
              frame.observer.disconnect();
              return {
                actionStable: action === window.__imageAllTrainingActivityAction,
                focusedOperationID: document.activeElement?.dataset.trainingActivityId || null,
                focusedAction: document.activeElement?.dataset.action || null,
                listStable: document.querySelector('.training-tag-activity-list') === frame.list,
                itemsStable: Object.entries(frame.items).every(
                  ([tagID, item]) => frame.list.querySelector(
                    `[data-training-tag-activity-id="${CSS.escape(tagID)}"]`
                  ) === item
                ),
                hovered: frame.items[secondTagID].matches(':hover'),
                selectionStable: getSelection().toString() === frame.selectedText
                  && getSelection().containsNode(frame.selectedStatus, true),
                childListMutations: frame.mutations,
              };
            }""",
            {"operationID": BATCH_ID, "secondTagID": SECOND_TAG_ID},
        )
        assert training_activity_refresh_after == {
            "actionStable": True,
            "focusedOperationID": BATCH_ID,
            "focusedAction": "cancel",
            "listStable": True,
            "itemsStable": True,
            "hovered": True,
            "selectionStable": True,
            "childListMutations": 0,
        }, training_activity_refresh_after
        activity_completed_unit_count[0] = 3
        activity_phase[0] = "completed"
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "operationID => document.activeElement?.dataset.trainingBatchReconfigureId === operationID "
            "&& document.querySelector('#trainingActivityStrip')?.contains(document.activeElement)",
            arg=BATCH_ID,
        )
        page.evaluate("elements.toast.classList.add('hidden')")
        page.screenshot(
            path="/tmp/imageall-training-activity-refresh-continuity.png",
            full_page=True,
        )
        activity_completed_unit_count[0] = 2
        activity_phase[0] = "preparingEmbeddings"
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        cancel_training.focus()
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
        batch_view = page.locator(f'[data-training-batch-view-id="{BATCH_ID}"]')
        batch_view.focus()
        page.evaluate(
            """({ operationID, secondTagID }) => {
              window.__imageAllTrainingBatchCard = document.querySelector(
                `[data-training-batch-id="${CSS.escape(operationID)}"]`
              );
              window.__imageAllTrainingBatchAction = document.querySelector(
                `[data-training-batch-view-id="${CSS.escape(operationID)}"]`
              );
              const tags = window.__imageAllTrainingBatchCard.querySelector(
                '.training-batch-tags'
              );
              const chips = Object.fromEntries([...tags.querySelectorAll(
                ':scope > [data-training-batch-tag-id]'
              )].map((chip) => [chip.dataset.trainingBatchTagId, chip]));
              const range = document.createRange();
              range.selectNodeContents(chips[secondTagID]);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const frame = {
                tags,
                chips,
                selectedText: selection.toString(),
                mutations: 0,
              };
              frame.observer = new MutationObserver((records) => {
                frame.mutations += records.filter(
                  (record) => record.type === 'childList'
                ).length;
              });
              frame.observer.observe(tags, { childList: true, subtree: true });
              window.__imageAllTrainingBatchTagFrame = frame;
              window.__imageAllTrainingBatchAction.focus({ preventScroll: true });
            }""",
            {"operationID": BATCH_ID, "secondTagID": SECOND_TAG_ID},
        )
        page.locator(
            f'[data-training-batch-tag-id="{SECOND_TAG_ID}"]'
        ).hover()
        page.evaluate(
            "() => window.__imageAllTrainingBatchAction.focus({ preventScroll: true })"
        )
        activity_second_tag_phase[0] = "succeeded"
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        assert "完成 2" in page.locator(".training-batch-card").inner_text()
        training_batch_refresh_after = page.evaluate(
            """({ operationID, secondTagID }) => {
              const card = document.querySelector(
                `[data-training-batch-id="${CSS.escape(operationID)}"]`
              );
              const action = document.querySelector(
                `[data-training-batch-view-id="${CSS.escape(operationID)}"]`
              );
              const frame = window.__imageAllTrainingBatchTagFrame;
              frame.observer.disconnect();
              return {
                cardStable: card === window.__imageAllTrainingBatchCard,
                actionStable: action === window.__imageAllTrainingBatchAction,
                focusedBatchViewID: document.activeElement?.dataset.trainingBatchViewId || null,
                tagsStable: card.querySelector('.training-batch-tags') === frame.tags,
                chipsStable: Object.entries(frame.chips).every(
                  ([tagID, chip]) => frame.tags.querySelector(
                    `[data-training-batch-tag-id="${CSS.escape(tagID)}"]`
                  ) === chip
                ),
                changedPhase: frame.chips[secondTagID].classList.contains('succeeded'),
                hovered: frame.chips[secondTagID].matches(':hover'),
                selectionStable: getSelection().toString() === frame.selectedText
                  && getSelection().containsNode(frame.chips[secondTagID], true),
                childListMutations: frame.mutations,
              };
            }""",
            {"operationID": BATCH_ID, "secondTagID": SECOND_TAG_ID},
        )
        assert training_batch_refresh_after == {
            "cardStable": True,
            "actionStable": True,
            "focusedBatchViewID": BATCH_ID,
            "tagsStable": True,
            "chipsStable": True,
            "changedPhase": True,
            "hovered": True,
            "selectionStable": True,
            "childListMutations": 0,
        }, training_batch_refresh_after
        activity_second_tag_phase[0] = "failed"
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        assert "完成 1" in page.locator(".training-batch-card").inner_text()
        batch_view.click()
        assert page.locator(
            f'[data-training-run-id="{PERSONAL_RUN_ID}"]'
        ).get_attribute("aria-selected") == "true"
        assert "批次 1 / 3" in page.locator("#trainingDetailContext").inner_text()
        assert "8 个样本" in page.locator("#trainingDetailContext").inner_text()
        assert page.locator("#trainingMetricHighlights").is_visible()
        metric_highlights = page.locator("#trainingMetricHighlights").inner_text()
        assert "训练轮次\n4" in metric_highlights
        assert "最佳损失\n0.240" in metric_highlights
        assert "最终损失\n0.270" in metric_highlights
        assert page.locator("#trainingMetricEmpty").is_hidden()
        assert page.locator("#trainingLossChart").is_visible()
        assert page.locator("#trainingLossChart").get_attribute("role") == "img"
        assert page.locator("#trainingLossChart").get_attribute("aria-label") == (
            "训练损失曲线：4 轮，最佳损失 0.240（第 3 轮），最终损失 0.270"
        )
        assert page.locator("#trainingLossChart svg").count() == 1
        assert page.locator("#trainingLossChart [data-metric-epoch]").count() == 4
        assert page.locator(
            '#trainingLossChart [data-metric-epoch="3"][data-best="true"]'
        ).count() == 1
        stable_training_metrics = page.evaluate(
            """() => {
              const highlights = document.querySelector("#trainingMetricHighlights");
              const chart = document.querySelector("#trainingLossChart");
              const bestValue = highlights.querySelectorAll(
                ".training-metric-highlight strong"
              )[1];
              const range = document.createRange();
              range.selectNodeContents(bestValue);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const frame = {
                highlightCards: [...highlights.children],
                svg: chart.querySelector("svg"),
                bestValue,
                selectedText: selection.toString(),
                highlightMutations: 0,
                chartMutations: 0,
              };
              const highlightObserver = new MutationObserver((records) => {
                frame.highlightMutations += records.filter(
                  (record) => record.type === "childList"
                ).length;
              });
              const chartObserver = new MutationObserver((records) => {
                frame.chartMutations += records.filter(
                  (record) => record.type === "childList"
                ).length;
              });
              highlightObserver.observe(highlights, { childList: true, subtree: true });
              chartObserver.observe(chart, { childList: true, subtree: true });
              state.online = false;
              renderTrainingDetail();
              state.online = true;
              renderTrainingDetail();
              highlightObserver.disconnect();
              chartObserver.disconnect();
              const cards = [...highlights.children];
              return {
                cards: cards.length === frame.highlightCards.length
                  && cards.every(
                    (card, index) => card === frame.highlightCards[index]
                  ),
                svg: chart.querySelector("svg") === frame.svg,
                bestValue: highlights.querySelectorAll(
                  ".training-metric-highlight strong"
                )[1] === frame.bestValue,
                selection: selection.toString() === frame.selectedText
                  && selection.toString() === "0.240",
                highlightMutations: frame.highlightMutations,
                chartMutations: frame.chartMutations,
              };
            }"""
        )
        assert stable_training_metrics == {
            "cards": True,
            "svg": True,
            "bestValue": True,
            "selection": True,
            "highlightMutations": 0,
            "chartMutations": 0,
        }, stable_training_metrics
        page.evaluate(
            """() => {
              const highlights = document.querySelector("#trainingMetricHighlights");
              const chart = document.querySelector("#trainingLossChart");
              const cards = [...highlights.children];
              const bestTitle = cards[1].querySelector(
                '[data-training-metric-copy-part="title"]'
              );
              const selection = getSelection();
              const range = document.createRange();
              range.selectNodeContents(bestTitle);
              selection.removeAllRanges();
              selection.addRange(range);
              const frame = {
                cards,
                cardTitles: cards.map((card) => card.querySelector(
                  '[data-training-metric-copy-part="title"]'
                )),
                cardValues: cards.map((card) => card.querySelector(
                  '[data-training-metric-copy-part="value"]'
                )),
                bestTitle,
                selectedText: selection.toString(),
                svg: chart.querySelector('[data-training-chart-part="svg"]'),
                points: new Map([...chart.querySelectorAll('[data-metric-epoch]')]
                  .map((point) => [point.dataset.metricEpoch, point])),
                lossLine: chart.querySelector('[data-training-chart-part="loss-line"]'),
                bestRule: chart.querySelector('[data-training-chart-part="best-rule"]'),
                xAxisTitle: chart.querySelector('[data-training-chart-part="x-axis-title"]'),
                yAxisTitle: chart.querySelector('[data-training-chart-part="y-axis-title"]'),
                activeElement: document.activeElement,
                highlightElementMutations: 0,
                chartRootElementMutations: 0,
                svgAddedElements: 0,
                svgRemovedElements: 0,
              };
              frame.highlightObserver = new MutationObserver((records) => {
                frame.highlightElementMutations += records
                  .flatMap((record) => [...record.addedNodes, ...record.removedNodes])
                  .filter((node) => node.nodeType === Node.ELEMENT_NODE).length;
              });
              frame.chartRootObserver = new MutationObserver((records) => {
                frame.chartRootElementMutations += records
                  .flatMap((record) => [...record.addedNodes, ...record.removedNodes])
                  .filter((node) => node.nodeType === Node.ELEMENT_NODE).length;
              });
              frame.svgObserver = new MutationObserver((records) => {
                frame.svgAddedElements += records.flatMap((record) => [...record.addedNodes])
                  .filter((node) => node.nodeType === Node.ELEMENT_NODE).length;
                frame.svgRemovedElements += records.flatMap((record) => [...record.removedNodes])
                  .filter((node) => node.nodeType === Node.ELEMENT_NODE).length;
              });
              frame.highlightObserver.observe(highlights, { childList: true, subtree: true });
              frame.chartRootObserver.observe(chart, { childList: true });
              frame.svgObserver.observe(frame.svg, { childList: true, subtree: true });
              window.__trainingDynamicMetricFrame = frame;
            }"""
        )
        page.locator(
            '#trainingMetricHighlights [data-training-metric-key="best"]'
        ).hover()
        page.evaluate(
            """runID => {
              const run = state.training.runs.find((item) => item.id === runID);
              window.__originalTrainingMetricsJSON = run.metricsJSON;
              const metrics = JSON.parse(run.metricsJSON);
              metrics.epochs.push({ epoch: 5, evaluationLoss: 0.22 });
              run.metricsJSON = JSON.stringify(metrics);
              renderTrainingDetail();
            }""",
            PERSONAL_RUN_ID,
        )
        changed_training_metrics = page.evaluate(
            """() => {
              const frame = window.__trainingDynamicMetricFrame;
              const highlights = document.querySelector("#trainingMetricHighlights");
              const chart = document.querySelector("#trainingLossChart");
              const cards = [...highlights.children];
              frame.highlightObserver.disconnect();
              frame.chartRootObserver.disconnect();
              frame.svgObserver.disconnect();
              return {
                cardsStable: cards.length === frame.cards.length
                  && cards.every((card, index) => card === frame.cards[index]),
                cardPartsStable: cards.every((card, index) => card.querySelector(
                  '[data-training-metric-copy-part="title"]'
                ) === frame.cardTitles[index] && card.querySelector(
                  '[data-training-metric-copy-part="value"]'
                ) === frame.cardValues[index]),
                metricValues: frame.cardValues.map((value) => value.textContent),
                svgStable: chart.querySelector(
                  '[data-training-chart-part="svg"]'
                ) === frame.svg,
                existingPointsStable: [...frame.points].every(([epoch, point]) => (
                  chart.querySelector(`[data-metric-epoch="${epoch}"]`) === point
                )),
                lineStable: chart.querySelector(
                  '[data-training-chart-part="loss-line"]'
                ) === frame.lossLine,
                ruleStable: chart.querySelector(
                  '[data-training-chart-part="best-rule"]'
                ) === frame.bestRule,
                axisTitlesStable: chart.querySelector(
                  '[data-training-chart-part="x-axis-title"]'
                ) === frame.xAxisTitle && chart.querySelector(
                  '[data-training-chart-part="y-axis-title"]'
                ) === frame.yAxisTitle,
                points: chart.querySelectorAll("[data-metric-epoch]").length,
                newPoint: Boolean(chart.querySelector(
                  '[data-metric-epoch="5"][data-best="true"]'
                )),
                label: chart.getAttribute("aria-label"),
                selectionStable: getSelection().toString() === frame.selectedText
                  && getSelection().containsNode(frame.bestTitle, true),
                hovered: frame.cards[1].matches(':hover'),
                focusStable: document.activeElement === frame.activeElement,
                highlightElementMutations: frame.highlightElementMutations,
                chartRootElementMutations: frame.chartRootElementMutations,
                svgAddedElements: frame.svgAddedElements,
                svgRemovedElements: frame.svgRemovedElements,
              };
            }"""
        )
        assert changed_training_metrics == {
            "cardsStable": True,
            "cardPartsStable": True,
            "metricValues": ["5", "0.220", "0.220"],
            "svgStable": True,
            "existingPointsStable": True,
            "lineStable": True,
            "ruleStable": True,
            "axisTitlesStable": True,
            "points": 5,
            "newPoint": True,
            "label": "训练损失曲线：5 轮，最佳损失 0.220（第 5 轮），最终损失 0.220",
            "selectionStable": True,
            "hovered": True,
            "focusStable": True,
            "highlightElementMutations": 0,
            "chartRootElementMutations": 0,
            "svgAddedElements": 3,
            "svgRemovedElements": 0,
        }, changed_training_metrics
        page.evaluate(
            """runID => {
              const run = state.training.runs.find((item) => item.id === runID);
              run.metricsJSON = window.__originalTrainingMetricsJSON;
              renderTrainingDetail();
            }""",
            PERSONAL_RUN_ID,
        )
        assert page.locator("#trainingLossChart [data-metric-epoch]").count() == 4
        page.screenshot(path="/tmp/imageall-training-loss-chart.png", full_page=True)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        assert page.locator("#trainingLossChart").is_visible()
        chart_bounds = page.locator("#trainingLossChart").bounding_box()
        assert chart_bounds is not None
        page.screenshot(
            path="/tmp/imageall-training-loss-chart-390.png",
            full_page=True,
        )
        assert chart_bounds["x"] >= 0, chart_bounds
        assert chart_bounds["x"] + chart_bounds["width"] <= 390, chart_bounds
        assert page.evaluate(
            "() => document.documentElement.scrollWidth <= window.innerWidth"
        )
        page.set_viewport_size({"width": 1280, "height": 900})
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

        training_page_navigation_requests = len(workspace_requests)
        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').focus()
        page.keyboard.press("Home")
        page.keyboard.press("PageDown")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId !== runID",
            arg=FAILED_RUN_ID,
        )
        training_page_down = page.evaluate(
            """() => {
              const pane = document.querySelector("#trainingRunPane");
              const heading = pane.querySelector(".training-run-heading");
              const rows = [...pane.querySelectorAll("[data-training-run-id]")];
              const active = document.activeElement;
              const paneRect = pane.getBoundingClientRect();
              const headingRect = heading.getBoundingClientRect();
              const activeRect = active?.getBoundingClientRect();
              return {
                advanced: rows.indexOf(active) > 0,
                selected: active?.getAttribute("aria-selected") === "true",
                visible: Boolean(activeRect)
                  && activeRect.top >= headingRect.bottom - 1
                  && activeRect.bottom <= paneRect.bottom + 1,
                scrolled: pane.scrollTop > 0,
                activeID: document.querySelector("#trainingRunList")
                  .getAttribute("aria-activedescendant") === active?.id,
                index: rows.indexOf(active),
              };
            }"""
        )
        training_page_down_index = training_page_down.pop("index")
        assert all(training_page_down.values()), training_page_down
        page.keyboard.press("PageUp")
        page.wait_for_function(
            """previousIndex => {
              const rows = [...document.querySelectorAll("[data-training-run-id]")];
              return rows.indexOf(document.activeElement) < previousIndex;
            }""",
            arg=training_page_down_index,
        )
        training_page_up = page.evaluate(
            """previousIndex => {
              const pane = document.querySelector("#trainingRunPane");
              const heading = pane.querySelector(".training-run-heading");
              const rows = [...pane.querySelectorAll("[data-training-run-id]")];
              const active = document.activeElement;
              const paneRect = pane.getBoundingClientRect();
              const headingRect = heading.getBoundingClientRect();
              const activeRect = active?.getBoundingClientRect();
              return {
                movedBack: rows.indexOf(active) < previousIndex,
                selected: active?.getAttribute("aria-selected") === "true",
                visible: Boolean(activeRect)
                  && activeRect.top >= headingRect.bottom - 1
                  && activeRect.bottom <= paneRect.bottom + 1,
              };
            }""",
            training_page_down_index,
        )
        assert all(training_page_up.values()), training_page_up
        page.keyboard.press("End")
        page.wait_for_function(
            """() => {
              const rows = [...document.querySelectorAll("[data-training-run-id]")];
              return document.activeElement === rows.at(-1);
            }"""
        )
        assert page.evaluate(
            """() => {
              const rows = [...document.querySelectorAll("[data-training-run-id]")];
              return document.activeElement === rows.at(-1);
            }"""
        )
        page.keyboard.press("Home")
        page.wait_for_function(
            """() => {
              const rows = [...document.querySelectorAll("[data-training-run-id]")];
              return document.activeElement === rows[0];
            }"""
        )
        assert page.evaluate(
            """() => {
              const rows = [...document.querySelectorAll("[data-training-run-id]")];
              return document.activeElement === rows[0];
            }"""
        )
        assert len(workspace_requests) == training_page_navigation_requests

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
        training_refresh_continuity_before = page.evaluate(
            """runID => {
              const run = document.querySelector(
                `[data-training-run-id="${CSS.escape(runID)}"]`
              );
              const originalFetch = window.fetch.bind(window);
              window.__imageAllTrainingRefreshRun = run;
              window.__imageAllTrainingRefreshSlot = document.querySelector(
                '[data-training-slot-method="personalCentroid"]'
              );
              window.__imageAllTrainingRefreshAction = document.querySelector(
                `[data-training-review-run-id="${CSS.escape(runID)}"]`
              );
              window.__imageAllTrainingRefreshRelease = null;
              window.fetch = (...args) => {
                const requestURL = String(args[0]?.url || args[0]);
                if (requestURL.includes('/v1/training/workspace?')) {
                  return new Promise((resolve, reject) => {
                    window.__imageAllTrainingRefreshRelease = () => {
                      window.fetch = originalFetch;
                      originalFetch(...args).then(resolve, reject);
                    };
                  });
                }
                return originalFetch(...args);
              };
              return {
                runID,
                runScrollTop: document.querySelector('#trainingRunPane').scrollTop,
                detailScrollTop: document.querySelector('#trainingDetailPane').scrollTop,
              };
            }""",
            scroll_run_ids[32],
        )
        page.evaluate("() => { void loadTrainingWorkspace({ quiet: true }); }")
        page.wait_for_function(
            "() => state.training.loading "
            "&& typeof window.__imageAllTrainingRefreshRelease === 'function'"
        )
        training_refresh_inflight = page.evaluate(
            """expected => {
              const run = document.querySelector(
                `[data-training-run-id="${CSS.escape(expected.runID)}"]`
              );
              return {
                runStable: run === window.__imageAllTrainingRefreshRun,
                slotStable: document.querySelector('[data-training-slot-method="personalCentroid"]')
                  === window.__imageAllTrainingRefreshSlot,
                actionStable: document.querySelector(
                  `[data-training-review-run-id="${CSS.escape(expected.runID)}"]`
                ) === window.__imageAllTrainingRefreshAction,
                runScrollTop: document.querySelector('#trainingRunPane').scrollTop,
                detailScrollTop: document.querySelector('#trainingDetailPane').scrollTop,
                focusedRunID: document.activeElement?.dataset.trainingRunId || null,
              };
            }""",
            training_refresh_continuity_before,
        )
        assert training_refresh_inflight == {
            "runStable": True,
            "slotStable": True,
            "actionStable": True,
            "runScrollTop": training_refresh_continuity_before["runScrollTop"],
            "detailScrollTop": training_refresh_continuity_before["detailScrollTop"],
            "focusedRunID": scroll_run_ids[32],
        }, training_refresh_inflight
        page.evaluate("() => window.__imageAllTrainingRefreshRelease()")
        page.wait_for_function("() => !state.training.loading")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=scroll_run_ids[32],
        )
        assert page.evaluate(
            """expected => {
              const run = document.querySelector(
                `[data-training-run-id="${CSS.escape(expected.runID)}"]`
              );
              return run === window.__imageAllTrainingRefreshRun
                && document.querySelector('[data-training-slot-method="personalCentroid"]')
                  === window.__imageAllTrainingRefreshSlot
                && document.querySelector(
                  `[data-training-review-run-id="${CSS.escape(expected.runID)}"]`
                ) === window.__imageAllTrainingRefreshAction;
            }""",
            training_refresh_continuity_before,
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

        selected_run_index = next(
            index for index, run in enumerate(runs)
            if run["id"] == scroll_run_ids[32]
        )
        original_selected_run = runs[selected_run_index]
        page.evaluate(
            """runID => {
              const row = document.querySelector(
                `[data-training-run-id="${CSS.escape(runID)}"]`
              );
              const context = row.querySelector('[data-training-run-part="context"]');
              const tag = context.querySelector('[data-training-run-context-part="tag"]');
              const range = document.createRange();
              range.selectNodeContents(tag);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const frame = {
                row,
                parts: {
                  heading: row.querySelector('[data-training-run-part="heading"]'),
                  title: row.querySelector('[data-training-run-heading-part="title"]'),
                  stateMark: row.querySelector('[data-training-run-heading-part="state-mark"]'),
                  state: row.querySelector('[data-training-run-heading-part="state"]'),
                  context,
                  tag,
                  kind: context.querySelector('[data-training-run-context-part="kind"]'),
                  samples: context.querySelector('[data-training-run-context-part="samples"]'),
                  subtitle: row.querySelector('[data-training-run-part="subtitle"]'),
                },
                selectedText: selection.toString(),
                elementMutations: 0,
              };
              frame.observer = new MutationObserver((records) => {
                frame.elementMutations += records.filter((record) => (
                  record.type === 'childList'
                  && [...record.addedNodes, ...record.removedNodes].some(
                    (node) => node.nodeType === Node.ELEMENT_NODE
                  )
                )).length;
              });
              frame.observer.observe(row, { childList: true, subtree: true });
              window.__imageAllTrainingRunInnerFrame = frame;
              row.focus({ preventScroll: true });
            }""",
            scroll_run_ids[32],
        )
        page.locator(
            f'[data-training-run-id="{scroll_run_ids[32]}"] '
            '[data-training-run-context-part="tag"]'
        ).hover()
        runs[selected_run_index] = {
            **original_selected_run,
            "state": "running",
            "finishedAtMs": None,
            "sampleCount": original_selected_run["sampleCount"] + 1,
        }
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)"
            "?.innerText.includes('训练中')",
            arg=scroll_run_ids[32],
        )
        training_run_inner_after = page.evaluate(
            """runID => {
              const frame = window.__imageAllTrainingRunInnerFrame;
              const row = document.querySelector(
                `[data-training-run-id="${CSS.escape(runID)}"]`
              );
              const context = row.querySelector('[data-training-run-part="context"]');
              frame.observer.disconnect();
              return {
                rowStable: row === frame.row,
                partsStable: frame.parts.heading === row.querySelector('[data-training-run-part="heading"]')
                  && frame.parts.title === row.querySelector('[data-training-run-heading-part="title"]')
                  && frame.parts.stateMark === row.querySelector('[data-training-run-heading-part="state-mark"]')
                  && frame.parts.state === row.querySelector('[data-training-run-heading-part="state"]')
                  && frame.parts.context === context
                  && frame.parts.tag === context.querySelector('[data-training-run-context-part="tag"]')
                  && frame.parts.kind === context.querySelector('[data-training-run-context-part="kind"]')
                  && frame.parts.samples === context.querySelector('[data-training-run-context-part="samples"]')
                  && frame.parts.subtitle === row.querySelector('[data-training-run-part="subtitle"]'),
                stateText: frame.parts.state.textContent,
                sampleText: frame.parts.samples.textContent,
                selectionStable: getSelection().toString() === frame.selectedText
                  && getSelection().containsNode(frame.parts.tag, true),
                hovered: frame.parts.tag.matches(':hover'),
                focusedRunID: document.activeElement?.dataset.trainingRunId || null,
                elementMutations: frame.elementMutations,
              };
            }""",
            scroll_run_ids[32],
        )
        assert training_run_inner_after == {
            "rowStable": True,
            "partsStable": True,
            "stateText": "训练中",
            "sampleText": f'{original_selected_run["sampleCount"] + 1} 个样本',
            "selectionStable": True,
            "hovered": True,
            "focusedRunID": scroll_run_ids[32],
            "elementMutations": 0,
        }, training_run_inner_after
        runs[selected_run_index] = original_selected_run
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)"
            "?.innerText.includes('已完成')",
            arg=scroll_run_ids[32],
        )

        original_personal_run = runs[1]
        page.evaluate(
            """focusedRunID => {
              const slot = document.querySelector(
                '[data-training-slot-method="personalCentroid"]'
              );
              const copy = slot.querySelector('[data-training-slot-part="copy"]');
              const title = copy.querySelector('[data-training-slot-copy-part="title"]');
              const range = document.createRange();
              range.selectNodeContents(title);
              const selection = getSelection();
              selection.removeAllRanges();
              selection.addRange(range);
              const frame = {
                slot,
                parts: {
                  mark: slot.querySelector('[data-training-slot-part="mark"]'),
                  copy,
                  title,
                  status: copy.querySelector('[data-training-slot-copy-part="status"]'),
                  meta: copy.querySelector('[data-training-slot-copy-part="meta"]'),
                  disclosure: slot.querySelector('[data-training-slot-part="disclosure"]'),
                },
                selectedText: selection.toString(),
                elementMutations: 0,
              };
              frame.observer = new MutationObserver((records) => {
                frame.elementMutations += records.filter((record) => (
                  record.type === 'childList'
                  && [...record.addedNodes, ...record.removedNodes].some(
                    (node) => node.nodeType === Node.ELEMENT_NODE
                  )
                )).length;
              });
              frame.observer.observe(slot, { childList: true, subtree: true });
              window.__imageAllTrainingSlotInnerFrame = frame;
              document.querySelector(
                `[data-training-run-id="${CSS.escape(focusedRunID)}"]`
              ).focus({ preventScroll: true });
            }""",
            scroll_run_ids[32],
        )
        page.locator(
            '[data-training-slot-method="personalCentroid"] '
            '[data-training-slot-copy-part="title"]'
        ).hover()
        runs[1] = {
            **original_personal_run,
            "sampleCount": original_personal_run["sampleCount"] + 1,
        }
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            """count => document.querySelector(
              '[data-training-slot-method="personalCentroid"] [data-training-slot-copy-part="status"]'
            ).textContent.includes(`${count} 个样本`)""",
            arg=original_personal_run["sampleCount"] + 1,
        )
        training_slot_inner_after = page.evaluate(
            """focusedRunID => {
              const frame = window.__imageAllTrainingSlotInnerFrame;
              const slot = document.querySelector(
                '[data-training-slot-method="personalCentroid"]'
              );
              const copy = slot.querySelector('[data-training-slot-part="copy"]');
              frame.observer.disconnect();
              return {
                slotStable: slot === frame.slot,
                partsStable: frame.parts.mark === slot.querySelector('[data-training-slot-part="mark"]')
                  && frame.parts.copy === copy
                  && frame.parts.title === copy.querySelector('[data-training-slot-copy-part="title"]')
                  && frame.parts.status === copy.querySelector('[data-training-slot-copy-part="status"]')
                  && frame.parts.meta === copy.querySelector('[data-training-slot-copy-part="meta"]')
                  && frame.parts.disclosure === slot.querySelector('[data-training-slot-part="disclosure"]'),
                statusText: frame.parts.status.textContent,
                selectionStable: getSelection().toString() === frame.selectedText
                  && getSelection().containsNode(frame.parts.title, true),
                hovered: frame.parts.title.matches(':hover'),
                focusedRunID: document.activeElement?.dataset.trainingRunId || null,
                elementMutations: frame.elementMutations,
              };
            }""",
            scroll_run_ids[32],
        )
        assert training_slot_inner_after == {
            "slotStable": True,
            "partsStable": True,
            "statusText": (
                f'模型已就绪 · {original_personal_run["sampleCount"] + 1} 个样本'
            ),
            "selectionStable": True,
            "hovered": True,
            "focusedRunID": scroll_run_ids[32],
            "elementMutations": 0,
        }, training_slot_inner_after
        runs[1] = original_personal_run
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            """count => document.querySelector(
              '[data-training-slot-method="personalCentroid"] [data-training-slot-copy-part="status"]'
            ).textContent.includes(`${count} 个样本`)""",
            arg=original_personal_run["sampleCount"],
        )

        original_failed_run = runs[0]
        runs[0] = {
            **original_failed_run,
            "state": "running",
            "finishedAtMs": None,
            "errorCode": None,
            "failureGuidance": None,
        }
        page.evaluate(
            """runID => {
              window.__imageAllTrainingChangedRun = document.querySelector(
                `[data-training-run-id="${CSS.escape(runID)}"]`
              );
            }""",
            FAILED_RUN_ID,
        )
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)"
            "?.innerText.includes('训练中')",
            arg=FAILED_RUN_ID,
        )
        training_changed_refresh_after = page.evaluate(
            """expected => {
              const selectedRun = document.querySelector(
                `[data-training-run-id="${CSS.escape(expected.selectedRunID)}"]`
              );
              return {
                changedRunStable: document.querySelector(
                  `[data-training-run-id="${CSS.escape(expected.changedRunID)}"]`
                ) === window.__imageAllTrainingChangedRun,
                selectedRunStable: selectedRun === window.__imageAllTrainingRefreshRun,
                slotStable: document.querySelector(
                  '[data-training-slot-method="personalCentroid"]'
                ) === window.__imageAllTrainingRefreshSlot,
                actionStable: document.querySelector(
                  `[data-training-review-run-id="${CSS.escape(expected.selectedRunID)}"]`
                ) === window.__imageAllTrainingRefreshAction,
                runScrollTop: document.querySelector('#trainingRunPane').scrollTop,
                detailScrollTop: document.querySelector('#trainingDetailPane').scrollTop,
                focusedRunID: document.activeElement?.dataset.trainingRunId || null,
              };
            }""",
            {
                "changedRunID": FAILED_RUN_ID,
                "selectedRunID": scroll_run_ids[32],
            },
        )
        assert training_changed_refresh_after == {
            "changedRunStable": True,
            "selectedRunStable": True,
            "slotStable": True,
            "actionStable": True,
            "runScrollTop": training_refresh_continuity_before["runScrollTop"],
            "detailScrollTop": training_refresh_continuity_before["detailScrollTop"],
            "focusedRunID": scroll_run_ids[32],
        }, training_changed_refresh_after
        runs[0] = original_failed_run
        page.evaluate("loadTrainingWorkspace({ quiet: true })")
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id='${runID}']`)"
            "?.innerText.includes('失败')",
            arg=FAILED_RUN_ID,
        )
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=scroll_run_ids[32],
        )
        training_failure_before = page.evaluate(
            """runID => {
              const originalFetch = window.fetch.bind(window);
              window.fetch = (...args) => {
                const requestURL = String(args[0]?.url || args[0]);
                if (requestURL.includes('/v1/training/workspace?')) {
                  window.fetch = originalFetch;
                  return Promise.reject(new Error('训练记录暂时不可用'));
                }
                return originalFetch(...args);
              };
              return {
                runScrollTop: document.querySelector('#trainingRunPane').scrollTop,
                detailScrollTop: document.querySelector('#trainingDetailPane').scrollTop,
                runID,
              };
            }""",
            scroll_run_ids[32],
        )
        page.evaluate("loadTrainingWorkspace()")
        assert "训练记录暂时不可用" in page.locator("#toastMessage").inner_text()
        training_failure_after = page.evaluate(
            """expected => ({
              runStable: document.querySelector(
                `[data-training-run-id="${CSS.escape(expected.runID)}"]`
              ) === window.__imageAllTrainingRefreshRun,
              slotStable: document.querySelector(
                '[data-training-slot-method="personalCentroid"]'
              ) === window.__imageAllTrainingRefreshSlot,
              actionStable: document.querySelector(
                `[data-training-review-run-id="${CSS.escape(expected.runID)}"]`
              ) === window.__imageAllTrainingRefreshAction,
              runScrollTop: document.querySelector('#trainingRunPane').scrollTop,
              detailScrollTop: document.querySelector('#trainingDetailPane').scrollTop,
              focusedRunID: document.activeElement?.dataset.trainingRunId || null,
            })""",
            training_failure_before,
        )
        assert training_failure_after == {
            "runStable": True,
            "slotStable": True,
            "actionStable": True,
            "runScrollTop": training_failure_before["runScrollTop"],
            "detailScrollTop": training_failure_before["detailScrollTop"],
            "focusedRunID": scroll_run_ids[32],
        }, training_failure_after
        page.screenshot(
            path="/tmp/imageall-training-refresh-continuity.png",
            full_page=True,
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
        if page.locator("#trainingButton").is_visible():
            page.locator("#trainingButton").click()
        else:
            page.locator("#compactToolbarMenuButton").click()
            page.locator(
                '[data-compact-toolbar-target="trainingButton"]'
            ).click()
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
        assert page.locator("#jobsList").get_attribute(
            "aria-keyshortcuts"
        ) == "ArrowUp ArrowDown PageUp PageDown Home End"
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=JOB_ID,
        )
        page.keyboard.press("ArrowDown")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=SECOND_JOB_ID,
        )
        jobs_page_navigation_requests = len(jobs_requests)
        page.keyboard.press("PageDown")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId !== jobID",
            arg=SECOND_JOB_ID,
        )
        jobs_page_down = page.evaluate(
            """() => {
              const list = document.querySelector("#jobsList");
              const rows = [...list.querySelectorAll("[data-job-row-id]")];
              const active = document.activeElement;
              const listRect = list.getBoundingClientRect();
              const activeRect = active?.getBoundingClientRect();
              return {
                advanced: rows.indexOf(active) > 1,
                selected: active?.getAttribute("aria-current") === "true",
                visible: Boolean(activeRect)
                  && activeRect.top >= listRect.top - 1
                  && activeRect.bottom <= listRect.bottom + 1,
                scrolled: list.scrollTop > 0,
                index: rows.indexOf(active),
              };
            }"""
        )
        jobs_page_down_index = jobs_page_down.pop("index")
        assert all(jobs_page_down.values()), jobs_page_down
        page.keyboard.press("PageUp")
        page.wait_for_function(
            """previousIndex => {
              const rows = [...document.querySelectorAll("[data-job-row-id]")];
              return rows.indexOf(document.activeElement) < previousIndex;
            }""",
            arg=jobs_page_down_index,
        )
        jobs_page_up = page.evaluate(
            """previousIndex => {
              const list = document.querySelector("#jobsList");
              const rows = [...list.querySelectorAll("[data-job-row-id]")];
              const active = document.activeElement;
              const listRect = list.getBoundingClientRect();
              const activeRect = active?.getBoundingClientRect();
              return {
                movedBack: rows.indexOf(active) < previousIndex,
                selected: active?.getAttribute("aria-current") === "true",
                visible: Boolean(activeRect)
                  && activeRect.top >= listRect.top - 1
                  && activeRect.bottom <= listRect.bottom + 1,
              };
            }""",
            jobs_page_down_index,
        )
        assert all(jobs_page_up.values()), jobs_page_up
        page.keyboard.press("End")
        page.wait_for_function(
            """() => {
              const rows = [...document.querySelectorAll("[data-job-row-id]")];
              return document.activeElement === rows.at(-1);
            }"""
        )
        assert page.evaluate(
            """() => {
              const rows = [...document.querySelectorAll("[data-job-row-id]")];
              return document.activeElement === rows.at(-1);
            }"""
        )
        page.keyboard.press("Home")
        page.wait_for_function(
            """() => {
              const rows = [...document.querySelectorAll("[data-job-row-id]")];
              return document.activeElement === rows[0];
            }"""
        )
        assert page.evaluate(
            """() => {
              const rows = [...document.querySelectorAll("[data-job-row-id]")];
              return document.activeElement === rows[0];
            }"""
        )
        page.keyboard.press("ArrowDown")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=SECOND_JOB_ID,
        )
        assert len(jobs_requests) == jobs_page_navigation_requests
        page.locator("#jobsList").evaluate("element => { element.scrollTop = 120; }")
        preserved_scroll_top = page.locator("#jobsList").evaluate("element => element.scrollTop")
        assert preserved_scroll_top > 0
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "jobs"
        jobs_history = page.evaluate("() => JSON.stringify(history.state)")
        assert JOB_ID not in jobs_history
        assert SECOND_JOB_ID not in jobs_history
        assert "staleSnapshot" not in jobs_history
        jobs_before_history_return = len(jobs_requests)
        page.go_back()
        page.locator("#jobsPopover").wait_for(state="hidden")
        page.wait_for_function(
            "runID => document.activeElement?.dataset.trainingRunId === runID",
            arg=FAILED_RUN_ID,
        )
        assert len(jobs_requests) == jobs_before_history_return
        page.go_forward()
        page.locator("#jobsPopover:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "jobID => document.activeElement?.dataset.jobRowId === jobID",
            arg=SECOND_JOB_ID,
        )
        assert len(jobs_requests) == jobs_before_history_return
        assert abs(
            page.locator("#jobsList").evaluate("element => element.scrollTop")
            - preserved_scroll_top
        ) <= 1
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

        stable_jobs_refresh_requests = len(jobs_requests)
        page.evaluate(
            f"""() => {{
              const list = document.querySelector("#jobsList");
              const rows = [...list.querySelectorAll("[data-job-row-id]")];
              const first = list.querySelector('[data-job-row-id="{JOB_ID}"]');
              const action = first.querySelector('[data-action="resume"]');
              action.focus({{ preventScroll: true }});
              window.__stableJobsRefreshFrame = {{
                list,
                rows,
                first,
                heading: first.querySelector(".job-heading"),
                progress: first.querySelector(".job-progress"),
                stateLine: first.querySelector(".job-state-line"),
                action,
                scrollTop: list.scrollTop,
              }};
              document.querySelector("#refreshJobsButton").click();
            }}"""
        )
        page.wait_for_function("() => !state.jobsRefreshing")
        assert len(jobs_requests) == stable_jobs_refresh_requests + 1
        stable_jobs_refresh = page.evaluate(
            f"""() => {{
              const frame = window.__stableJobsRefreshFrame;
              const list = document.querySelector("#jobsList");
              const rows = [...list.querySelectorAll("[data-job-row-id]")];
              const first = list.querySelector('[data-job-row-id="{JOB_ID}"]');
              return {{
                list: list === frame.list,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                first: first === frame.first,
                heading: first.querySelector(".job-heading") === frame.heading,
                progress: first.querySelector(".job-progress") === frame.progress,
                stateLine: first.querySelector(".job-state-line") === frame.stateLine,
                action: first.querySelector('[data-action="resume"]') === frame.action,
                focus: document.activeElement === frame.action,
                scroll: list.scrollTop === frame.scrollTop,
              }};
            }}"""
        )
        assert all(stable_jobs_refresh.values()), stable_jobs_refresh

        original_first_job = json.loads(json.dumps(jobs_payload[0]))
        page.evaluate(
            f"""() => {{
              const list = document.querySelector("#jobsList");
              const first = list.querySelector('[data-job-row-id="{JOB_ID}"]');
              const second = list.querySelector('[data-job-row-id="{SECOND_JOB_ID}"]');
              const action = first.querySelector('[data-action="resume"]');
              const mutations = [];
              const observer = new MutationObserver((records) => mutations.push(...records));
              action.focus({{ preventScroll: true }});
              observer.observe(second, {{
                attributes: true,
                childList: true,
                characterData: true,
                subtree: true,
              }});
              window.__changedJobsRefreshFrame = {{
                rows: [...list.querySelectorAll("[data-job-row-id]")],
                first,
                second,
                heading: first.querySelector(".job-heading"),
                progress: first.querySelector(".job-progress"),
                stateLine: first.querySelector(".job-state-line"),
                action,
                scrollTop: list.scrollTop,
                mutations,
                observer,
              }};
            }}"""
        )
        jobs_payload[0].update({
            "state": "running",
            "progress": {"completedUnitCount": 5, "totalUnitCount": 12},
            "availableActions": ["pause", "cancel"],
            "lastErrorCode": None,
        })
        changed_jobs_refresh_requests = len(jobs_requests)
        page.keyboard.press("r")
        page.wait_for_function("() => !state.jobsRefreshing")
        assert len(jobs_requests) == changed_jobs_refresh_requests + 1
        changed_jobs_refresh = page.evaluate(
            f"""() => {{
              const frame = window.__changedJobsRefreshFrame;
              frame.mutations.push(...frame.observer.takeRecords());
              frame.observer.disconnect();
              const list = document.querySelector("#jobsList");
              const rows = [...list.querySelectorAll("[data-job-row-id]")];
              const first = list.querySelector('[data-job-row-id="{JOB_ID}"]');
              const pause = first.querySelector('[data-action="pause"]');
              return {{
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                first: first === frame.first,
                second: list.querySelector('[data-job-row-id="{SECOND_JOB_ID}"]')
                  === frame.second,
                heading: first.querySelector(".job-heading") === frame.heading,
                progress: first.querySelector(".job-progress") === frame.progress,
                stateLine: first.querySelector(".job-state-line") === frame.stateLine,
                state: first.querySelector(".job-heading .secondary")?.textContent === "进行中",
                amount: first.querySelector('[data-job-state-part="amount"]')?.textContent
                  === "5 / 12",
                percent: first.querySelector('[data-job-state-part="percent"]')?.textContent
                  === "42%",
                resumeRemoved: !first.querySelector('[data-action="resume"]'),
                pauseAdded: Boolean(pause),
                cancelAdded: Boolean(first.querySelector('[data-action="cancel"]')),
                focusMigrated: document.activeElement === pause,
                unaffectedMutations: frame.mutations.length === 0,
                scroll: list.scrollTop === frame.scrollTop,
              }};
            }}"""
        )
        assert all(changed_jobs_refresh.values()), changed_jobs_refresh
        jobs_payload[0] = original_first_job
        page.locator("#refreshJobsButton").click()
        page.wait_for_function("() => !state.jobsRefreshing")
        assert page.locator(
            f'[data-job-row-id="{JOB_ID}"] [data-action="resume"]'
        ).is_visible()
        page.locator(f'[data-job-row-id="{SECOND_JOB_ID}"]').focus()

        jobs_before_command_palette = len(jobs_requests)
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette[open]").wait_for()
        page.locator("#jobsPopover").wait_for(state="hidden")
        assert page.locator("#commandContextLabel").inner_text() == "当前：训练工程"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "commandPalette"
        page.keyboard.press("Meta+K")
        page.locator("#commandPalette").wait_for(state="hidden")
        page.locator("#jobsPopover:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "jobID => history.state?.imageAllWorkspace?.navigationLevel === 'jobs' "
            "&& document.activeElement?.dataset.jobRowId === jobID",
            arg=SECOND_JOB_ID,
        )
        assert len(jobs_requests) == jobs_before_command_palette
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
        page.evaluate(
            f"""() => {{
              const list = document.querySelector("#jobsList");
              const first = list.querySelector('[data-job-row-id="{JOB_ID}"]');
              window.__failedJobsRefreshFrame = {{
                rows: [...list.querySelectorAll("[data-job-row-id]")],
                first,
                heading: first.querySelector(".job-heading"),
                progress: first.querySelector(".job-progress"),
                stateLine: first.querySelector(".job-state-line"),
                action: first.querySelector('[data-action="resume"]'),
                scrollTop: list.scrollTop,
              }};
            }}"""
        )
        jobs_fail_next[0] = True
        before_jobs_refresh = len(jobs_requests)
        page.locator("#refreshJobsButton").click()
        page.wait_for_timeout(100)
        assert len(jobs_requests) == before_jobs_refresh + 1
        assert page.locator("[data-job-row-id]").count() == len(jobs_payload)
        assert page.locator("#refreshJobsButton").is_enabled()
        assert page.locator("#refreshJobsButton").get_attribute("aria-label") == "重试刷新活动"
        assert page.evaluate("() => document.activeElement?.id") == "refreshJobsButton"
        failed_jobs_refresh = page.evaluate(
            f"""() => {{
              const frame = window.__failedJobsRefreshFrame;
              const list = document.querySelector("#jobsList");
              const rows = [...list.querySelectorAll("[data-job-row-id]")];
              const first = list.querySelector('[data-job-row-id="{JOB_ID}"]');
              return {{
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                first: first === frame.first,
                heading: first.querySelector(".job-heading") === frame.heading,
                progress: first.querySelector(".job-progress") === frame.progress,
                stateLine: first.querySelector(".job-state-line") === frame.stateLine,
                action: first.querySelector('[data-action="resume"]') === frame.action,
                scroll: list.scrollTop === frame.scrollTop,
              }};
            }}"""
        )
        assert all(failed_jobs_refresh.values()), failed_jobs_refresh
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
        page.wait_for_function("() => !state.training.setup.loading")
        tag_navigation_reads = {
            "setup": len(training_setup_requests),
            "workspace": len(workspace_requests),
            "jobs": len(jobs_requests),
            "launches": len(launches),
        }
        feature_tag_navigation_state = page.evaluate(
            """() => {
              const snapshot = state.training.setup.snapshot;
              const originalTags = snapshot.tags;
              snapshot.tags = [
                ...originalTags,
                ...Array.from({ length: 14 }, (_, index) => ({
                  id: `11111112-aaaa-bbbb-cccc-${String(index + 1).padStart(12, '0')}`,
                  displayName: `合成训练标签 ${index + 1}`,
                  acceptedSampleCount: index + 4,
                  rejectedSampleCount: index + 3,
                  featureMode: 'generate',
                  personalEligible: true,
                })),
              ];
              window.__trainingNavigationOriginalTags = originalTags;
              renderTrainingSetup();
              const options = document.querySelector('#trainingTagOptions');
              options.style.maxHeight = '124px';
              options.scrollTop = 0;
              const inputs = [...options.querySelectorAll('input[data-training-tag-id]')];
              inputs[0].focus({ preventScroll: true });
              return {
                count: inputs.length,
                inputType: inputs[0].type,
                selectedIndex: inputs.findIndex((input) => input.checked),
                shortcuts: inputs.every((input) => input.getAttribute('aria-keyshortcuts')
                  === choiceGridNavigationShortcuts),
                columns: renderedGridColumnCount(options, ':scope > .training-option-row'),
                dialogScrollTop: document.querySelector('#trainingSetupDialog').scrollTop,
                workspaceScrollTop: document.querySelector('#trainingWorkspace').scrollTop,
              };
            }"""
        )
        assert feature_tag_navigation_state == {
            "count": 15,
            "inputType": "radio",
            "selectedIndex": 0,
            "shortcuts": True,
            "columns": 1,
            "dialogScrollTop": 0,
            "workspaceScrollTop": 0,
        }, feature_tag_navigation_state
        page.keyboard.press("ArrowDown")
        feature_selected = page.evaluate(
            """() => {
              const inputs = [...document.querySelectorAll(
                '#trainingTagOptions [data-training-tag-id]'
              )];
              return {
                activeIndex: inputs.indexOf(document.activeElement),
                checkedIndex: inputs.findIndex((input) => input.checked),
                selectedIDs: [...state.training.setup.selectedTagIDs],
              };
            }"""
        )
        assert feature_selected["activeIndex"] == 1, feature_selected
        assert feature_selected["checkedIndex"] == 1, feature_selected
        assert feature_selected["selectedIDs"] == [
            "11111112-aaaa-bbbb-cccc-000000000001"
        ], feature_selected
        assert "合成训练标签 1" in page.locator("#trainingLaunchSummary").inner_text()
        page.keyboard.press("PageDown")
        feature_page_target = page.evaluate(
            "() => [...document.querySelectorAll('#trainingTagOptions [data-training-tag-id]')].indexOf(document.activeElement)"
        )
        assert feature_page_target > 1, feature_page_target
        page.keyboard.press("PageDown")
        page.keyboard.press("PageUp")
        page.keyboard.press("End")
        feature_end_result = page.evaluate(
            """() => {
              const options = document.querySelector('#trainingTagOptions');
              const inputs = [...options.querySelectorAll('[data-training-tag-id]')];
              const row = document.activeElement.closest('.training-option-row');
              const optionsRect = options.getBoundingClientRect();
              const rowRect = row.getBoundingClientRect();
              return {
                activeIndex: inputs.indexOf(document.activeElement),
                checkedIndex: inputs.findIndex((input) => input.checked),
                fullyVisible: rowRect.top >= optionsRect.top + options.clientTop - 0.5
                  && rowRect.bottom <= optionsRect.top + options.clientTop
                    + options.clientHeight + 0.5,
              };
            }"""
        )
        assert feature_end_result == {
            "activeIndex": 14,
            "checkedIndex": 14,
            "fullyVisible": True,
        }, feature_end_result
        page.keyboard.press("Home")
        assert page.evaluate(
            """() => {
              const inputs = [...document.querySelectorAll(
                '#trainingTagOptions [data-training-tag-id]'
              )];
              return inputs.indexOf(document.activeElement) === 0
                && inputs.findIndex((input) => input.checked) === 0;
            }"""
        )

        page.locator('[data-training-setup-method="personalCentroid"]').click()
        personal_tag_navigation_state = page.evaluate(
            """() => {
              const options = document.querySelector('#trainingTagOptions');
              options.style.maxHeight = '124px';
              options.scrollTop = 0;
              const inputs = [...options.querySelectorAll('input[data-training-tag-id]')];
              inputs[0].focus({ preventScroll: true });
              window.__trainingTagNavigationChecked = inputs.map((input) => input.checked);
              return {
                count: inputs.length,
                inputType: inputs[0].type,
                checkedCount: inputs.filter((input) => input.checked).length,
                shortcuts: inputs.every((input) => input.getAttribute('aria-keyshortcuts')
                  === choiceGridNavigationShortcuts),
              };
            }"""
        )
        assert personal_tag_navigation_state == {
            "count": 17,
            "inputType": "checkbox",
            "checkedCount": 0,
            "shortcuts": True,
        }, personal_tag_navigation_state
        page.keyboard.press("ArrowDown")
        page.keyboard.press("PageDown")
        personal_page_target = page.evaluate(
            "() => [...document.querySelectorAll('#trainingTagOptions [data-training-tag-id]')].indexOf(document.activeElement)"
        )
        assert personal_page_target > 1, personal_page_target
        page.keyboard.press("PageDown")
        page.keyboard.press("PageUp")
        page.keyboard.press("End")
        assert page.evaluate(
            "() => [...document.querySelectorAll('#trainingTagOptions [data-training-tag-id]')].indexOf(document.activeElement)"
        ) == 16
        page.keyboard.press("Home")
        personal_navigation_result = page.evaluate(
            """() => {
              const options = document.querySelector('#trainingTagOptions');
              const inputs = [...options.querySelectorAll('[data-training-tag-id]')];
              const row = document.activeElement.closest('.training-option-row');
              const optionsRect = options.getBoundingClientRect();
              const rowRect = row.getBoundingClientRect();
              return {
                activeIndex: inputs.indexOf(document.activeElement),
                checkedUnchanged: inputs.every(
                  (input, index) => input.checked === window.__trainingTagNavigationChecked[index]
                ),
                fullyVisible: rowRect.top >= optionsRect.top + options.clientTop - 0.5
                  && rowRect.bottom <= optionsRect.top + options.clientTop
                    + options.clientHeight + 0.5,
                dialogScrollTop: document.querySelector('#trainingSetupDialog').scrollTop,
                workspaceScrollTop: document.querySelector('#trainingWorkspace').scrollTop,
              };
            }"""
        )
        assert personal_navigation_result == {
            "activeIndex": 0,
            "checkedUnchanged": True,
            "fullyVisible": True,
            "dialogScrollTop": 0,
            "workspaceScrollTop": 0,
        }, personal_navigation_result
        page.keyboard.press("Space")
        assert page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        page.keyboard.press("Space")
        assert not page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        filtered_tag_identity = page.evaluate(
            """() => {
              const input = document.querySelector(
                '[data-training-tag-id="11111112-aaaa-bbbb-cccc-000000000001"]'
              );
              window.__trainingFilteredTagInput = input;
              return Boolean(input);
            }"""
        )
        assert filtered_tag_identity
        page.locator("#trainingTagSearch").fill("合成训练标签 1")
        assert page.locator("#trainingTagOptions [data-training-tag-id]").count() == 6
        assert page.evaluate(
            """() => document.querySelector(
              '[data-training-tag-id="11111112-aaaa-bbbb-cccc-000000000001"]'
            ) === window.__trainingFilteredTagInput"""
        )
        page.locator(
            '[data-training-tag-id="11111112-aaaa-bbbb-cccc-000000000001"]'
        ).focus()
        page.keyboard.press("End")
        assert page.evaluate(
            "() => [...document.querySelectorAll('#trainingTagOptions [data-training-tag-id]')].indexOf(document.activeElement)"
        ) == 5
        page.locator("#trainingTagSearch").fill("")
        assert page.locator("#trainingTagOptions [data-training-tag-id]").count() == 17
        assert page.evaluate(
            """() => document.querySelector(
              '[data-training-tag-id="11111112-aaaa-bbbb-cccc-000000000001"]'
            ) === window.__trainingFilteredTagInput"""
        )
        page.locator(f'[data-training-tag-id="{TAG_ID}"]').focus()
        assert tag_navigation_reads == {
            "setup": len(training_setup_requests),
            "workspace": len(workspace_requests),
            "jobs": len(jobs_requests),
            "launches": len(launches),
        }
        page.screenshot(
            path="/tmp/imageall-training-tag-list-keyboard.png",
            full_page=False,
        )
        page.evaluate(
            """() => {
              state.training.setup.snapshot.tags = window.__trainingNavigationOriginalTags;
              resetTrainingSetupSelection('featureKnn');
              renderTrainingSetup();
              document.querySelector('#trainingTagOptions').style.removeProperty('max-height');
            }"""
        )
        training_navigation_reads = {
            "setup": len(training_setup_requests),
            "workspace": len(workspace_requests),
            "jobs": len(jobs_requests),
            "launches": len(launches),
        }
        training_navigation_state = page.evaluate(
            """() => {
              const options = document.querySelector('#trainingScopeOptions');
              options.style.maxHeight = '124px';
              options.scrollTop = 0;
              const inputs = [...options.querySelectorAll(
                'input[data-training-source-id]'
              )];
              inputs[0].focus({ preventScroll: true });
              window.__trainingSourceNavigationChecked = inputs.map(
                (input) => input.checked
              );
              return {
                count: inputs.length,
                shortcuts: inputs.every((input) => input.getAttribute('aria-keyshortcuts')
                  === choiceGridNavigationShortcuts),
                columns: renderedGridColumnCount(options, ':scope > .training-option-row'),
                dialogScrollTop: document.querySelector('#trainingSetupDialog').scrollTop,
                workspaceScrollTop: document.querySelector('#trainingWorkspace').scrollTop,
              };
            }"""
        )
        assert training_navigation_state == {
            "count": 13,
            "shortcuts": True,
            "columns": 1,
            "dialogScrollTop": 0,
            "workspaceScrollTop": 0,
        }, training_navigation_state
        page.keyboard.press("ArrowDown")
        assert page.evaluate(
            "() => [...document.querySelectorAll('#trainingScopeOptions [data-training-source-id]')].indexOf(document.activeElement)"
        ) == 1
        page.keyboard.press("PageDown")
        training_page_target = page.evaluate(
            "() => [...document.querySelectorAll('#trainingScopeOptions [data-training-source-id]')].indexOf(document.activeElement)"
        )
        assert training_page_target > 1, training_page_target
        page.keyboard.press("PageDown")
        page.keyboard.press("PageUp")
        page.keyboard.press("End")
        assert page.evaluate(
            "() => [...document.querySelectorAll('#trainingScopeOptions [data-training-source-id]')].indexOf(document.activeElement)"
        ) == 12
        page.keyboard.press("Home")
        training_navigation_result = page.evaluate(
            """() => {
              const options = document.querySelector('#trainingScopeOptions');
              const inputs = [...options.querySelectorAll('[data-training-source-id]')];
              const row = document.activeElement.closest('.training-option-row');
              const optionsRect = options.getBoundingClientRect();
              const rowRect = row.getBoundingClientRect();
              return {
                activeIndex: inputs.indexOf(document.activeElement),
                checkedUnchanged: inputs.every(
                  (input, index) => input.checked === window.__trainingSourceNavigationChecked[index]
                ),
                fullyVisible: rowRect.top >= optionsRect.top + options.clientTop - 0.5
                  && rowRect.bottom <= optionsRect.top + options.clientTop
                    + options.clientHeight + 0.5,
                dialogScrollTop: document.querySelector('#trainingSetupDialog').scrollTop,
                workspaceScrollTop: document.querySelector('#trainingWorkspace').scrollTop,
              };
            }"""
        )
        assert training_navigation_result == {
            "activeIndex": 0,
            "checkedUnchanged": True,
            "fullyVisible": True,
            "dialogScrollTop": 0,
            "workspaceScrollTop": 0,
        }, training_navigation_result
        assert training_navigation_reads == {
            "setup": len(training_setup_requests),
            "workspace": len(workspace_requests),
            "jobs": len(jobs_requests),
            "launches": len(launches),
        }
        page.screenshot(
            path="/tmp/imageall-training-source-grid-keyboard.png",
            full_page=False,
        )
        page.evaluate(
            "document.querySelector('#trainingScopeOptions').style.removeProperty('max-height')"
        )
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
        page.wait_for_function("() => document.querySelector('#appView').inert")
        assert page.locator("#appView").evaluate("element => element.inert")
        assert page.locator("#trainingWorkspace").get_attribute("role") == "dialog"
        assert page.locator("#trainingWorkspace").get_attribute("aria-modal") == "true"
        assert page.locator("#closeTrainingButton").is_visible()
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
        page.locator("#compactToolbarMenuButton").focus()
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
        page.locator("#jobsPopover").wait_for(state="hidden")
        assert page.evaluate(
            "() => document.activeElement?.id"
        ) == "compactToolbarMenuButton"
        mobile_jobs_requests = len(jobs_requests)
        page.go_forward()
        page.locator("#jobsPopover:not(.hidden)").wait_for(state="visible")
        assert len(jobs_requests) == mobile_jobs_requests
        page.keyboard.press("j")
        page.locator("#jobsPopover").wait_for(state="hidden")
        assert page.evaluate(
            "() => document.activeElement?.id"
        ) == "compactToolbarMenuButton"

        page.keyboard.press("Meta+f")
        page.locator("#trainingWorkspace").wait_for(state="hidden")
        page.wait_for_function(
            "() => history.state?.imageAllWorkspace?.route === 'gallery' "
            "&& history.state?.imageAllWorkspace?.navigationLevel === 'workspace' "
            "&& document.activeElement?.id === 'searchInput'"
        )
        assert not page.locator("#appView").evaluate("element => element.inert")
        page.screenshot(
            path="/tmp/imageall-mobile-workspace-command-search-390.png",
            full_page=True,
        )
        page.go_back()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "runID => history.state?.imageAllWorkspace?.route === 'training' "
            "&& document.querySelector('#appView').inert "
            "&& document.querySelector(`[data-training-run-id='${runID}']`)"
            "?.getAttribute('aria-selected') === 'true' "
            "&& document.activeElement?.dataset.trainingRunId === runID",
            arg=FAILED_RUN_ID,
        )

        # A browser refresh must preserve the active Mac-style workspace and
        # its durable navigation context instead of silently returning to the
        # gallery root.
        page.set_viewport_size({"width": 1440, "height": 960})
        if page.locator("#trainingWorkspace").is_hidden():
            if page.locator("#trainingButton").is_visible():
                page.locator("#trainingButton").click()
            else:
                page.locator("#compactToolbarMenuButton").click()
                page.locator(
                    '[data-compact-toolbar-target="trainingButton"]'
                ).click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "() => document.querySelector('#trainingWorkspace')?.getAttribute('role') === 'region'"
        )
        page.locator("#trainingRecordScopeFilter").select_option("all")
        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').click()
        page.locator("#trainingRunPane").evaluate(
            "element => { element.scrollTop = Math.min(96, element.scrollHeight - element.clientHeight); }"
        )
        preserved_training_scroll = page.locator("#trainingRunPane").evaluate(
            "element => element.scrollTop"
        )
        page.locator("#trainingDetailPane").evaluate(
            "element => { element.scrollTop = Math.min(160, element.scrollHeight - element.clientHeight); }"
        )
        preserved_training_detail_scroll = page.locator(
            "#trainingDetailPane"
        ).evaluate("element => element.scrollTop")
        assert preserved_training_detail_scroll > 0
        page.wait_for_function(
            "expected => history.state?.imageAllWorkspace?.context?.trainingDetailScrollTop === expected",
            arg=preserved_training_detail_scroll,
        )
        page.reload(wait_until="domcontentloaded")
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        page.wait_for_function(
            "runID => document.querySelector(`[data-training-run-id=\"${runID}\"]`)?.getAttribute('aria-selected') === 'true'",
            arg=FAILED_RUN_ID,
        )
        assert page.locator("#trainingRecordScopeFilter").input_value() == "all"
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "training"
        assert abs(
            page.locator("#trainingRunPane").evaluate("element => element.scrollTop")
            - preserved_training_scroll
        ) <= 1
        restored_training_detail = page.locator("#trainingDetailPane").evaluate(
            "element => ({ scrollTop: element.scrollTop, maximum: Math.max(0, element.scrollHeight - element.clientHeight) })"
        )
        assert abs(
            restored_training_detail["scrollTop"]
            - min(preserved_training_detail_scroll, restored_training_detail["maximum"])
        ) <= 1, (
            preserved_training_detail_scroll,
            restored_training_detail,
        )

        # Nested workflow context survives too: review still knows it should
        # return to the originating training run after a refresh.
        page.locator(f'[data-training-run-id="{FAILED_RUN_ID}"]').focus()
        page.keyboard.press("v")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator("#closeReviewButton").get_attribute(
            "aria-label"
        ) == "返回训练记录"
        page.reload(wait_until="domcontentloaded")
        page.locator("#reviewWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.route"
        ) == "review"
        assert page.locator("#closeReviewButton").get_attribute(
            "aria-label"
        ) == "返回训练记录"
        assert page.locator("#reviewOverviewGrid").get_by_text(
            "猫", exact=True
        ).is_visible()
        assert not page_errors, page_errors
        assert not failed_resources, failed_resources
        assert not console_errors, console_errors
        assert not unexpected_dialogs, unexpected_dialogs
        context.close()
        browser.close()

    print("training-recovery-keyboard-browser: ok")


if __name__ == "__main__":
    main()
