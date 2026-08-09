#!/usr/bin/env python3
import base64
import json
import re
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8804"
TAG_ID = "11111111-aaaa-bbbb-cccc-111111111111"
GROUP_ID = "11111111-aaaa-bbbb-cccc-999999999999"
SOURCE_IDS = [
    "22222222-aaaa-bbbb-cccc-222222222222",
    "33333333-aaaa-bbbb-cccc-333333333333",
]
JOB_ID = "44444444-aaaa-bbbb-cccc-444444444444"
STANDARD_JOB_ID = "44444444-aaaa-bbbb-cccc-555555555555"
PERSONAL_JOB_ID = "44444444-aaaa-bbbb-cccc-666666666666"
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
    library_task_state = {"standard": None, "personal": None}
    actions = []
    launches = []
    library_launches = []
    overview_source_queries = []
    queue_source_queries = []
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
        result = []
        if value != "cancelled":
            result.append({
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
            })
        for track, job_id, kind in [
            ("standard", STANDARD_JOB_ID, "standardSuggestions"),
            ("personal", PERSONAL_JOB_ID, "personalizationSuggestions"),
        ]:
            state = library_task_state[track]
            if state is None:
                continue
            result.append({
                "id": job_id,
                "kind": kind,
                "state": state,
                "controlRequest": "none",
                "progress": {"completedUnitCount": 36, "totalUnitCount": 120},
                "attempts": 1,
                "maxAttempts": 3,
                "lastErrorCode": None,
                "availableActions": (
                    ["resume", "cancel"] if state in {"paused", "retryableFailed"}
                    else (["pause", "cancel"] if state in {"pending", "running"} else [])
                ),
                "navigationTarget": None,
            })
        return result

    def library_suggestions():
        def job(track, job_id):
            value = library_task_state[track]
            if value is None:
                return None
            return {
                "jobID": job_id,
                "state": value,
                "checkedCount": 36,
                "totalCount": 120,
                "suggestedCount": 8,
                "skippedCount": 2,
                "lastErrorCode": None,
                "availableActions": (
                    ["resume", "cancel"] if value in {"paused", "retryableFailed"}
                    else (["pause", "cancel"] if value in {"pending", "running"} else [])
                ),
            }
        return {
            "mediaKind": "image",
            "service": {
                "state": "ready",
                "serviceVersion": "1.2.3",
                "provider": "coreml",
                "modelID": "scene-personal-v1",
            },
            "standardAvailable": True,
            "personalMode": "fullLibrary",
            "standardJob": job("standard", STANDARD_JOB_ID),
            "personalJob": job("personal", PERSONAL_JOB_ID),
        }

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
                    "capabilities": ["librarySuggestions"],
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
        page.route(
            "**/v1/library-suggestions?**",
            lambda route: fulfill_json(route, library_suggestions()),
        )

        def route_library_suggestion_launch(route):
            payload = route.request.post_data_json
            library_launches.append(payload)
            track = payload["track"]
            library_task_state[track] = "running"
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "track": track,
                    "jobID": STANDARD_JOB_ID if track == "standard" else PERSONAL_JOB_ID,
                    "replayed": False,
                },
                status=202,
            )

        page.route(
            "**/v1/library-suggestions/requests",
            route_library_suggestion_launch,
        )
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
        def requested_source_ids(route):
            values = parse_qs(
                urlparse(route.request.url).query,
                keep_blank_values=True,
            ).get("sourceIDs")
            return tuple(values[0].split(",")) if values and values[0] else None

        def route_review_overview(route):
            overview_source_queries.append(requested_source_ids(route))
            fulfill_json(route, review_overview())

        page.route("**/v1/review/overview?**", route_review_overview)

        def route_review_queue(route):
            queue_source_queries.append(requested_source_ids(route))
            fulfill_json(
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
            )

        page.route(
            "**/v1/review/queue?**",
            route_review_queue,
        )
        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )

        def route_job_action(route):
            payload = route.request.post_data_json
            job_id = urlparse(route.request.url).path.split("/")[-2]
            if job_id == JOB_ID:
                actions.append(payload["action"])
                target = task_state
            elif job_id == STANDARD_JOB_ID:
                actions.append(f"standard:{payload['action']}")
                target = {"value": library_task_state["standard"]}
            else:
                actions.append(f"personal:{payload['action']}")
                target = {"value": library_task_state["personal"]}
            target["value"] = {
                "resume": "running",
                "pause": "paused",
                "cancel": "cancelled",
            }[payload["action"]]
            if job_id == STANDARD_JOB_ID:
                library_task_state["standard"] = target["value"]
            elif job_id == PERSONAL_JOB_ID:
                library_task_state["personal"] = target["value"]
            fulfill_json(route, {})

        page.route(re.compile(r".*/v1/jobs/[0-9a-f-]+/actions$"), route_job_action)
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
        source_button = page.locator("#reviewSourceFilterButton")
        assert source_button.get_attribute("aria-label") == (
            "审核来源：显示全部 2 个来源的待审核建议"
        )
        source_button.click()
        source_popover = page.locator("#reviewSourceFilterPopover")
        source_popover.wait_for(state="visible")
        page.screenshot(path="/tmp/imageall-review-source-filter-wide.png", full_page=True)
        first_source = page.locator(f'[data-review-source-id="{SOURCE_IDS[0]}"]')
        second_source = page.locator(f'[data-review-source-id="{SOURCE_IDS[1]}"]')
        assert first_source.get_attribute("aria-checked") == "true"
        assert second_source.get_attribute("aria-checked") == "true"
        first_source.press("End")
        assert page.evaluate("document.activeElement?.dataset.reviewSourceId") == SOURCE_IDS[1]

        second_source.click()
        page.wait_for_function(
            "() => document.querySelector('#reviewSourceFilterSummary')?.textContent"
            " === '仅显示：Apple Photos'"
        )
        page.wait_for_timeout(100)
        focused_source_id = page.evaluate("document.activeElement?.dataset.reviewSourceId")
        assert focused_source_id == SOURCE_IDS[1], focused_source_id
        assert overview_source_queries[-1] == (SOURCE_IDS[0],)

        overview_count = len(overview_source_queries)
        first_source.click()
        page.wait_for_function(
            "() => document.querySelector('#reviewSourceFilterSummary')?.textContent"
            " === '未选择来源，待审核列表为空'"
        )
        assert len(overview_source_queries) == overview_count
        assert not card.is_visible()

        page.locator("#selectAllReviewSourcesButton").click()
        card.wait_for(state="visible")
        assert overview_source_queries[-1] is None
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.reviewSourceId === sourceID",
            arg=SOURCE_IDS[0],
        )
        second_source.click()
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.reviewSourceId === sourceID",
            arg=SOURCE_IDS[1],
        )
        assert overview_source_queries[-1] == (SOURCE_IDS[0],)
        second_source.press("Escape")
        page.wait_for_function(
            "() => document.activeElement?.id === 'reviewSourceFilterButton'"
        )

        assert page.locator("#reviewLocalModelStateBadge").inner_text() == "服务已就绪"
        assert "coreml / scene-personal-v1" in page.locator("#reviewLocalModelStatus").inner_text()
        standard_card = page.locator("#standardLibrarySuggestionCard")
        personal_card = page.locator(".review-local-model-personal-card")
        assert standard_card.is_visible()
        assert page.locator("#personalLibrarySuggestionPath").inner_text() == "全库建议"

        standard_card.get_by_role("button", name="扫描全库").click()
        standard_card.get_by_role("button", name="暂停").wait_for(state="visible")
        assert library_launches[-1]["track"] == "standard"
        assert library_launches[-1]["sourceIDs"] == [SOURCE_IDS[0]]
        assert "已检 36 / 120" in page.locator("#standardLibrarySuggestionStatus").inner_text()
        standard_card.get_by_role("button", name="暂停").click()
        standard_card.get_by_role("button", name="继续").wait_for(state="visible")
        standard_card.get_by_role("button", name="继续").click()
        standard_card.get_by_role("button", name="取消").wait_for(state="visible")
        standard_card.get_by_role("button", name="取消").click()
        standard_card.get_by_role("button", name="扫描全库").wait_for(state="visible")

        page.locator("#generateLibrarySuggestionsButton").click()
        personal_card.get_by_role("button", name="取消").wait_for(state="visible")
        assert library_launches[-1]["track"] == "personal"
        assert library_launches[-1]["sourceIDs"] == [SOURCE_IDS[0]]
        personal_card.get_by_role("button", name="取消").click()
        page.locator("#generateLibrarySuggestionsButton").wait_for(state="visible")
        assert actions[:4] == [
            "standard:pause",
            "standard:resume",
            "standard:cancel",
            "personal:cancel",
        ]

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
        card.locator("summary", has_text="门槛与生成").click()
        assert card.locator("details.review-card-controls").get_attribute("open") is not None
        page.screenshot(path="/tmp/imageall-review-overview-groups.png", full_page=True)
        assert card.get_by_role("button", name="继续").is_visible()
        assert card.get_by_role("button", name="取消").is_visible()
        assert card.get_by_role("button", name="训练记录").is_visible()

        card.get_by_role("button", name="继续").click()
        page.wait_for_function("() => document.querySelector('[data-action=\"pause\"]') !== null")
        assert actions[-1] == "resume"

        page.get_by_role("button", name="训练记录").click()
        page.locator("#trainingWorkspace:not(.hidden)").wait_for(state="visible")
        assert page.locator(f'[data-training-run-id="{RUN_ID}"]').get_attribute("aria-selected") == "true"
        page.get_by_role("button", name="打开标签审核").click()
        page.locator("#reviewQueueLayout:not(.hidden)").wait_for(state="visible")
        assert page.locator("#reviewTagSelect").input_value() == TAG_ID
        assert page.locator("#reviewGrid .review-card").count() == 1
        assert queue_source_queries[-1] == (SOURCE_IDS[0],)

        page.locator("#reviewBackButton").click()
        page.locator("#reviewOverview:not(.hidden)").wait_for(state="visible")
        page.get_by_role("button", name="取消").click()
        page.get_by_role("button", name="更新特征向量").wait_for(state="visible")
        assert actions[-2:] == ["resume", "cancel"]

        page.get_by_role("button", name="更新特征向量").click()
        dialog = page.locator("#trainingSetupDialog")
        dialog.wait_for(state="visible")
        assert page.locator('[data-training-setup-method="featureKnn"]').get_attribute("aria-checked") == "true"
        assert page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        assert page.locator("[data-training-source-id]:checked").count() == 1
        assert page.locator(
            f'[data-training-source-id="{SOURCE_IDS[0]}"]'
        ).is_checked()
        page.locator("#launchTrainingButton").click()
        page.wait_for_function("() => !document.querySelector('#trainingSetupDialog').open")
        assert len(launches) == 1
        assert launches[0]["method"] == "featureKnn"
        assert launches[0]["tagIDs"] == [TAG_ID]
        assert launches[0]["sourceIDs"] == [SOURCE_IDS[0]]

        page.set_viewport_size({"width": 390, "height": 844})
        source_button.click()
        source_popover.wait_for(state="visible")
        source_bounds = source_popover.bounding_box()
        assert source_bounds is not None
        assert source_bounds["x"] >= 0
        assert source_bounds["x"] + source_bounds["width"] <= 390.5
        page.screenshot(path="/tmp/imageall-review-source-filter-390.png", full_page=True)
        page.keyboard.press("Escape")
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        assert not page_errors, page_errors
        assert not failed_resources, failed_resources
        assert not console_errors, console_errors
        context.close()
        browser.close()

    print("feature-review-bridge-browser: ok")


if __name__ == "__main__":
    main()
