#!/usr/bin/env python3
import base64
import json
import re

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8804"
TAG_ID = "11111111-aaaa-bbbb-cccc-111111111111"
GROUP_ID = "11111111-aaaa-bbbb-cccc-999999999999"
SOURCE_IDS = [
    "22222222-aaaa-bbbb-cccc-222222222222",
    "33333333-aaaa-bbbb-cccc-333333333333",
]
JOB_ID = "44444444-aaaa-bbbb-cccc-444444444444"
RUN_ID = "55555555-aaaa-bbbb-cccc-555555555555"
ASSET_ID = "66666666-aaaa-bbbb-cccc-666666666666"
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
    task_state = {"value": "paused"}
    actions = []
    launches = []
    page_errors = []
    console_errors = []
    failed_resources = []

    def review_overview():
        value = task_state["value"]
        active = value in {"paused", "running"}
        return {
            "totalPendingSuggestionCount": 1,
            "tags": [{
                "id": TAG_ID,
                "displayName": "猫",
                "acceptedSampleCount": 12,
                "rejectedSampleCount": 9,
                "pendingSuggestionCount": 1,
                "pendingSuggestionCounts": {
                    "featurePrint": 1,
                    "standardModel": 0,
                    "personalModel": 0,
                    "personalAdamW": 0,
                },
                "taskStatus": value if active else "cancelled",
                "checkedCount": 18,
                "totalCount": 40,
                "skippedCount": 0,
                "missingPositiveCount": 0,
                "missingNegativeCount": 0,
                "canGenerate": False,
                "canUpdate": not active,
                "canGeneratePersonalModel": False,
                "canReview": True,
                "canPause": value == "running",
                "canResume": value == "paused",
                "canCancel": active,
                "activeJobID": JOB_ID if active else None,
            }],
        }

    def jobs():
        value = task_state["value"]
        if value == "cancelled": return []
        return [{
            "id": JOB_ID,
            "kind": "personalizationSuggestions",
            "state": value,
            "controlRequest": "none",
            "progress": {"completedUnitCount": 18, "totalUnitCount": 40},
            "attempts": 1,
            "maxAttempts": 3,
            "lastErrorCode": None,
            "availableActions": ["resume", "cancel"] if value == "paused" else ["pause", "cancel"],
            "navigationTarget": None,
        }]

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
        sources = [
            {"id": SOURCE_IDS[0], "kind": "photos", "displayName": "Apple Photos", "state": "active"},
            {"id": SOURCE_IDS[1], "kind": "folder", "displayName": "旅行归档", "state": "active"},
        ]
        page.route("**/v1/sources", lambda route: fulfill_json(route, sources))
        page.route(
            "**/v1/tags",
            lambda route: fulfill_json(
                route,
                [{"id": TAG_ID, "displayName": "猫", "state": "active", "groupID": GROUP_ID}],
            ),
        )
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(
                route,
                [{
                    "id": GROUP_ID,
                    "displayName": "动物",
                    "sortOrder": 0,
                    "isSystem": False,
                }],
            ),
        )
        page.route("**/v1/jobs", lambda route: fulfill_json(route, jobs()))
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
        page.route("**/v1/review/overview?**", lambda route: fulfill_json(route, review_overview()))
        page.route(
            "**/v1/review/queue?**",
            lambda route: fulfill_json(
                route,
                {
                    "items": [{
                        "assetID": ASSET_ID,
                        "fileName": "CAT_FEATURE.JPG",
                        "availability": "available",
                        "acceptedTagCount": 1,
                        "rejectedTagCount": 0,
                        "suggestionOrigin": "featurePrint",
                        "score": 0.93,
                    }],
                    "nextCursor": None,
                },
            ),
        )
        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )

        def route_job_action(route):
            payload = route.request.post_data_json
            actions.append(payload["action"])
            task_state["value"] = {
                "resume": "running",
                "pause": "paused",
                "cancel": "cancelled",
            }[payload["action"]]
            fulfill_json(route, {})

        page.route(re.compile(rf".*/v1/jobs/{JOB_ID}/actions$"), route_job_action)
        page.route(
            "**/v1/training/setup?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "tags": [{
                        "id": TAG_ID,
                        "displayName": "猫",
                        "acceptedSampleCount": 12,
                        "rejectedSampleCount": 9,
                        "featureMode": "update",
                        "personalEligible": True,
                    }],
                    "sources": [
                        {"id": SOURCE_IDS[0], "displayName": "Apple Photos"},
                        {"id": SOURCE_IDS[1], "displayName": "旅行归档"},
                    ],
                    "methods": [
                        {"method": "featureKnn", "isAvailable": True},
                        {"method": "personalCentroid", "isAvailable": False},
                        {"method": "personalAdamW", "isAvailable": False},
                    ],
                },
            ),
        )
        page.route(
            "**/v1/training/workspace?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "methodFilter": "featureKnn",
                    "runs": [{
                        "id": RUN_ID,
                        "mediaKind": "image",
                        "method": "featureKnn",
                        "state": "running",
                        "createdAtMs": 1_700_000_000_000,
                        "startedAtMs": 1_700_000_000_500,
                        "finishedAtMs": None,
                        "catalogScopeID": "all-active-sources",
                        "jobID": JOB_ID,
                        "tagID": TAG_ID,
                        "sampleSummaryJSON": None,
                        "sampleManifestSHA256": None,
                        "configJSON": None,
                        "metricsJSON": None,
                        "artifactKind": None,
                        "artifactRef": None,
                        "artifactSHA256": None,
                        "resultSummaryJSON": None,
                        "errorCode": None,
                    }],
                    "slots": [],
                    "activities": [],
                },
            ),
        )

        def route_training_launch(route):
            launches.append(route.request.post_data_json)
            fulfill_json(
                route,
                {
                    "operationID": launches[-1]["operationID"],
                    "method": "featureKnn",
                    "acceptedAtMs": 1_700_000_001_000,
                    "scheduledTagCount": 1,
                    "jobID": JOB_ID,
                    "replayed": False,
                },
                status=202,
            )

        page.route("**/v1/training/launch", route_training_launch)

        page.goto(BASE_URL, wait_until="networkidle")
        page.locator("#reviewButton").click()
        card = page.locator(".review-overview-card")
        card.wait_for(state="visible")
        group_toggle = page.locator(f'[data-review-overview-group-toggle="{GROUP_ID}"]')
        assert "动物" in group_toggle.inner_text()
        assert "1 个标签" in group_toggle.inner_text()
        assert "1 条待审" in group_toggle.inner_text()
        group_toggle.click()
        assert group_toggle.get_attribute("aria-expanded") == "false"
        assert not card.is_visible()
        group_toggle.press("Enter")
        assert group_toggle.get_attribute("aria-expanded") == "true"
        card.wait_for(state="visible")
        assert page.evaluate(
            "document.activeElement?.dataset.reviewOverviewGroupToggle"
        ) == GROUP_ID
        page.screenshot(path="/tmp/imageall-review-overview-groups.png", full_page=True)
        assert card.get_by_role("button", name="继续").is_visible()
        assert card.get_by_role("button", name="取消").is_visible()
        assert card.get_by_role("button", name="训练记录").is_visible()

        card.get_by_role("button", name="继续").click()
        page.wait_for_function("() => document.querySelector('[data-action=\"pause\"]') !== null")
        assert actions == ["resume"]

        page.get_by_role("button", name="训练记录").click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator(f'[data-training-run-id="{RUN_ID}"]').get_attribute("aria-selected") == "true"
        page.get_by_role("button", name="打开标签审核").click()
        page.locator("#reviewQueueLayout:not(.hidden)").wait_for(state="visible")
        assert page.locator("#reviewTagSelect").input_value() == TAG_ID
        assert page.locator("#reviewGrid .review-card").count() == 1

        page.locator("#reviewBackButton").click()
        page.locator("#reviewOverview:not(.hidden)").wait_for(state="visible")
        page.get_by_role("button", name="取消").click()
        page.get_by_role("button", name="更新特征向量").wait_for(state="visible")
        assert actions == ["resume", "cancel"]

        page.get_by_role("button", name="更新特征向量").click()
        dialog = page.locator("#trainingSetupDialog")
        dialog.wait_for(state="visible")
        assert page.locator('[data-training-setup-method="featureKnn"]').get_attribute("aria-checked") == "true"
        assert page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        assert page.locator("[data-training-source-id]:checked").count() == 2
        page.locator("#launchTrainingButton").click()
        page.wait_for_function("() => !document.querySelector('#trainingSetupDialog').open")
        assert len(launches) == 1
        assert launches[0]["method"] == "featureKnn"
        assert launches[0]["tagIDs"] == [TAG_ID]
        assert set(launches[0]["sourceIDs"]) == set(SOURCE_IDS)

        page.set_viewport_size({"width": 390, "height": 844})
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        assert not page_errors, page_errors
        assert not failed_resources, failed_resources
        assert not console_errors, console_errors
        context.close()
        browser.close()

    print("feature-review-bridge-browser: ok")


if __name__ == "__main__":
    main()
