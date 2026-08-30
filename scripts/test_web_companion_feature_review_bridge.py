#!/usr/bin/env python3
import base64
import json
import re
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8804"
TAG_ID = "11111111-aaaa-bbbb-cccc-111111111111"
SECOND_TAG_ID = "11111111-aaaa-bbbb-cccc-222222222222"
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
    training_setup_reads = [0]
    job_action_fail_next = [False]
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
        page.route(
            "**/v1/training/activities?**",
            lambda route: fulfill_json(route, []),
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
            f"**/v1/assets/{ASSET_ID}",
            lambda route: fulfill_json(
                route,
                {
                    "assetID": ASSET_ID,
                    "sourceID": SOURCE_IDS[0],
                    "sourceName": "Apple Photos",
                    "fileName": "CAT_FEATURE.JPG",
                    "relativePath": None,
                    "mediaType": "public.jpeg",
                    "availability": "available",
                    "contentRevision": 1,
                    "acceptedTagCount": 1,
                    "rejectedTagCount": 0,
                    "mediaCreatedAtMs": 1_700_000_000_000,
                    "mediaModifiedAtMs": 1_700_000_100_000,
                    "width": 1200,
                    "height": 900,
                    "fingerprintSizeBytes": 800_000,
                    "tags": [{
                        "tagID": TAG_ID,
                        "displayName": "猫",
                        "decision": "accepted",
                    }],
                    "pendingSuggestions": [{
                        "tagID": TAG_ID,
                        "displayName": "猫",
                        "suggestionOrigin": "featurePrint",
                    }],
                },
            ),
        )
        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )

        def route_job_action(route):
            payload = route.request.post_data_json
            job_id = urlparse(route.request.url).path.split("/")[-2]
            if job_id == JOB_ID and job_action_fail_next[0]:
                job_action_fail_next[0] = False
                fulfill_json(
                    route,
                    {"message": "合成任务动作失败"},
                    status=409,
                )
                return
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
        def route_training_setup(route):
            training_setup_reads[0] += 1
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
                            "displayName": "狗",
                            "acceptedSampleCount": 8,
                            "rejectedSampleCount": 6,
                            "featureMode": "generate",
                            "personalEligible": True,
                        },
                    ],
                    "sources": [
                        {"id": SOURCE_IDS[0], "displayName": "Apple Photos"},
                        {"id": SOURCE_IDS[1], "displayName": "旅行归档"},
                    ],
                    "methods": [
                        {"method": "featureKnn", "isAvailable": True},
                        {"method": "personalCentroid", "isAvailable": True},
                        {"method": "personalAdamW", "isAvailable": False},
                    ],
                },
            )

        page.route("**/v1/training/setup?**", route_training_setup)
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
        review_button = page.locator("#reviewButton")
        if review_button.is_visible():
            review_button.click()
        else:
            page.locator("#compactToolbarMenuButton").click()
            page.locator('[data-compact-toolbar-target="reviewButton"]').click()
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

        review_source_frame = page.evaluate(
            """sourceIDs => {
              const options = document.querySelector('#reviewSourceFilterOptions');
              options.style.maxHeight = '46px';
              options.style.overflowY = 'auto';
              options.scrollTop = 12;
              const first = options.querySelector(
                `[data-review-source-id="${sourceIDs[0]}"]`
              );
              const second = options.querySelector(
                `[data-review-source-id="${sourceIDs[1]}"]`
              );
              second.focus({ preventScroll: true });
              window.__reviewSourceContinuityFrame = {
                first,
                second,
                secondCheck: second.querySelector('.review-source-check'),
                secondName: second.querySelector('span:last-child'),
              };
              return { scrollTop: options.scrollTop };
            }""",
            SOURCE_IDS,
        )
        assert review_source_frame["scrollTop"] > 0, review_source_frame
        second_source_bounds = second_source.bounding_box()
        assert second_source_bounds is not None
        page.mouse.move(
            second_source_bounds["x"] + second_source_bounds["width"] / 2,
            second_source_bounds["y"] + second_source_bounds["height"] / 2,
        )
        page.mouse.click(
            second_source_bounds["x"] + second_source_bounds["width"] / 2,
            second_source_bounds["y"] + second_source_bounds["height"] / 2,
        )
        page.wait_for_function(
            "() => document.querySelector('#reviewSourceFilterSummary')?.textContent"
            " === '仅显示：Apple Photos'"
        )
        page.wait_for_timeout(100)
        review_source_continuity = page.evaluate(
            """({ sourceIDs, expectedScrollTop }) => {
              const frame = window.__reviewSourceContinuityFrame;
              const options = document.querySelector('#reviewSourceFilterOptions');
              const first = options.querySelector(
                `[data-review-source-id="${sourceIDs[0]}"]`
              );
              const second = options.querySelector(
                `[data-review-source-id="${sourceIDs[1]}"]`
              );
              return {
                first: first === frame.first,
                second: second === frame.second,
                secondCheck: second?.querySelector('.review-source-check') === frame.secondCheck,
                secondName: second?.querySelector('span:last-child') === frame.secondName,
                focused: document.activeElement === second,
                hovered: second?.matches(':hover') || false,
                scroll: options.scrollTop === expectedScrollTop,
                checked: second?.getAttribute('aria-checked'),
              };
            }""",
            {
                "sourceIDs": SOURCE_IDS,
                "expectedScrollTop": review_source_frame["scrollTop"],
            },
        )
        assert review_source_continuity == {
            "first": True,
            "second": True,
            "secondCheck": True,
            "secondName": True,
            "focused": True,
            "hovered": True,
            "scroll": True,
            "checked": "false",
        }, review_source_continuity
        assert overview_source_queries[-1] == (SOURCE_IDS[0],)
        page.evaluate(
            "() => document.querySelector('#reviewSourceFilterOptions')"
            ".style.removeProperty('max-height')"
        )
        page.evaluate(
            "() => document.querySelector('#reviewSourceFilterOptions')"
            ".style.removeProperty('overflow-y')"
        )

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

        source_button.click()
        source_popover.wait_for(state="visible")
        second_source.focus()
        source_popover.evaluate(
            "element => { element.style.maxHeight = '70px'; "
            "element.style.overflowY = 'auto'; element.scrollTop = 24; }"
        )
        review_source_scroll = source_popover.evaluate("element => element.scrollTop")
        review_source_reads = len(overview_source_queries)
        review_source_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert '"navigationLevel":"actionMenu"' in review_source_history_payload
        assert '"actionMenuKind":"reviewSources"' in review_source_history_payload
        assert SOURCE_IDS[1] not in review_source_history_payload
        assert "actionMenuFocusedSelector" not in review_source_history_payload
        assert "actionMenuScrollTop" not in review_source_history_payload
        page.evaluate("() => history.back()")
        source_popover.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.id === 'reviewSourceFilterButton'"
        )
        page.evaluate("() => history.forward()")
        source_popover.wait_for(state="visible")
        page.wait_for_function(
            "sourceID => document.activeElement?.dataset.reviewSourceId === sourceID",
            arg=SOURCE_IDS[1],
        )
        assert source_popover.evaluate("element => element.scrollTop") == review_source_scroll
        assert len(overview_source_queries) == review_source_reads
        assert page.locator(
            f'[data-review-source-id="{SOURCE_IDS[0]}"]'
        ).get_attribute("aria-checked") == "true"
        assert page.locator(
            f'[data-review-source-id="{SOURCE_IDS[1]}"]'
        ).get_attribute("aria-checked") == "false"
        page.keyboard.press("Escape")
        source_popover.wait_for(state="hidden")

        assert page.locator("#reviewLocalModelStateBadge").inner_text() == "服务已就绪"
        assert "coreml / scene-personal-v1" in page.locator("#reviewLocalModelStatus").inner_text()
        standard_card = page.locator("#standardLibrarySuggestionCard")
        personal_card = page.locator(".review-local-model-personal-card")
        assert standard_card.is_visible()
        assert page.locator("#personalLibrarySuggestionPath").inner_text() == "全库建议"

        standard_card.get_by_role("button", name="扫描全库").click()
        standard_pause = standard_card.get_by_role("button", name="暂停")
        standard_pause.wait_for(state="visible")
        assert library_launches[-1]["track"] == "standard"
        assert library_launches[-1]["sourceIDs"] == [SOURCE_IDS[0]]
        assert "已检 36 / 120" in page.locator("#standardLibrarySuggestionStatus").inner_text()
        page.evaluate(
            """() => {
              const container = document.querySelector('#standardLibrarySuggestionActions');
              const primary = container.querySelector(
                '[data-library-suggestion-action-key$=":primary"]'
              );
              const cancel = container.querySelector(
                '[data-library-suggestion-action-key$=":cancel"]'
              );
              window.__librarySuggestionActionFrame = {
                container,
                primary,
                primaryLabel: primary.querySelector(
                  '[data-library-suggestion-action-part="label"]'
                ),
                cancel,
                cancelLabel: cancel.querySelector(
                  '[data-library-suggestion-action-part="label"]'
                ),
                childMutations: 0,
              };
              new MutationObserver((records) => {
                window.__librarySuggestionActionFrame.childMutations += records.filter(
                  (record) => record.type === 'childList' && record.target === container
                ).length;
              }).observe(container, { childList: true, subtree: true });
              renderReviewLocalModelStatus();
            }"""
        )
        assert page.evaluate(
            """() => {
              const frame = window.__librarySuggestionActionFrame;
              return frame.container === document.querySelector(
                  '#standardLibrarySuggestionActions'
                )
                && frame.primary === frame.container.querySelector(
                  '[data-library-suggestion-action-key$=":primary"]'
                )
                && frame.primaryLabel === frame.primary.querySelector(
                  '[data-library-suggestion-action-part="label"]'
                )
                && frame.cancel === frame.container.querySelector(
                  '[data-library-suggestion-action-key$=":cancel"]'
                )
                && frame.cancelLabel === frame.cancel.querySelector(
                  '[data-library-suggestion-action-part="label"]'
                )
                && frame.childMutations === 0;
            }"""
        )
        standard_pause.click()
        standard_continue = standard_card.get_by_role("button", name="继续")
        standard_continue.wait_for(state="visible")
        page.wait_for_function(
            """() => {
              const frame = window.__librarySuggestionActionFrame;
              return frame.primary === document.activeElement
                && frame.primary === frame.container.querySelector(
                  '[data-library-suggestion-action-key$=":primary"][data-action="resume"]'
                )
                && frame.cancel === frame.container.querySelector(
                  '[data-library-suggestion-action-key$=":cancel"]'
                )
                && frame.primaryLabel === frame.primary.querySelector(
                  '[data-library-suggestion-action-part="label"]'
                )
                && frame.cancelLabel === frame.cancel.querySelector(
                  '[data-library-suggestion-action-part="label"]'
                )
                && frame.childMutations === 0;
            }"""
        )
        standard_continue.click()
        standard_card.get_by_role("button", name="暂停").wait_for(state="visible")
        page.wait_for_function(
            """() => {
              const frame = window.__librarySuggestionActionFrame;
              return frame.primary === document.activeElement
                && frame.primary.dataset.action === 'pause'
                && frame.childMutations === 0;
            }"""
        )
        standard_cancel = standard_card.get_by_role("button", name="取消")
        standard_cancel.click()
        page.wait_for_function(
            """() => document.activeElement?.id
              === 'generateStandardLibrarySuggestionsButton'
              && !document.activeElement.disabled"""
        )

        page.locator("#generateLibrarySuggestionsButton").click()
        personal_card.get_by_role("button", name="取消").wait_for(state="visible")
        assert library_launches[-1]["track"] == "personal"
        assert library_launches[-1]["sourceIDs"] == [SOURCE_IDS[0]]
        personal_card.get_by_role("button", name="取消").click()
        page.wait_for_function(
            """() => document.activeElement?.id === 'generateLibrarySuggestionsButton'
              && !document.activeElement.disabled"""
        )
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
        training_image_tab = page.locator('[data-training-media-kind="image"]')
        training_video_tab = page.locator('[data-training-media-kind="video"]')
        assert training_image_tab.get_attribute("tabindex") == "0"
        assert training_video_tab.get_attribute("tabindex") == "-1"
        training_image_tab.focus()
        page.keyboard.press("End")
        page.wait_for_function(
            "() => state.training.mediaKind === 'video' && !state.training.loading"
        )
        assert page.evaluate(
            "() => document.activeElement?.dataset.trainingMediaKind"
        ) == "video"
        assert training_video_tab.get_attribute("aria-pressed") == "true"
        page.keyboard.press("Home")
        page.wait_for_function(
            "() => state.training.mediaKind === 'image' && !state.training.loading"
        )
        assert page.evaluate(
            "() => document.activeElement?.dataset.trainingMediaKind"
        ) == "image"
        assert training_image_tab.get_attribute("aria-pressed") == "true"
        assert page.locator(f'[data-training-run-id="{RUN_ID}"]').get_attribute("aria-selected") == "true"
        page.evaluate(
            f"""() => {{
              const actions = document.querySelector("#trainingDetailActions");
              window.__stableTrainingDetailActions = {{
                viewJob: actions.querySelector('[data-training-job-id="{JOB_ID}"]'),
                primary: actions.querySelector(
                  '[data-training-run-job-id="{JOB_ID}"][data-action="pause"]'
                ),
                cancel: actions.querySelector(
                  '[data-training-run-job-id="{JOB_ID}"][data-action="cancel"]'
                ),
                review: actions.querySelector('[data-training-review-run-id="{RUN_ID}"]'),
                scrollTop: document.querySelector("#trainingDetailPane").scrollTop,
              }};
            }}"""
        )
        training_pause = page.locator(
            f'#trainingDetailActions [data-training-run-job-id="{JOB_ID}"]'
            '[data-action="pause"]'
        )
        training_pause.click()
        training_resume = page.locator(
            f'#trainingDetailActions [data-training-run-job-id="{JOB_ID}"]'
            '[data-action="resume"]'
        )
        training_resume.wait_for(state="visible")
        page.wait_for_function(
            "() => document.activeElement?.dataset.action === 'resume'"
        )
        stable_training_detail_actions = page.evaluate(
            f"""() => {{
              const frame = window.__stableTrainingDetailActions;
              const actions = document.querySelector("#trainingDetailActions");
              const primary = actions.querySelector(
                '[data-training-run-job-id="{JOB_ID}"][data-action="resume"]'
              );
              return {{
                viewJob: actions.querySelector('[data-training-job-id="{JOB_ID}"]')
                  === frame.viewJob,
                primary: primary === frame.primary,
                cancel: actions.querySelector(
                  '[data-training-run-job-id="{JOB_ID}"][data-action="cancel"]'
                ) === frame.cancel,
                review: actions.querySelector('[data-training-review-run-id="{RUN_ID}"]')
                  === frame.review,
                focus: document.activeElement === frame.primary,
                scroll: document.querySelector("#trainingDetailPane").scrollTop
                  === frame.scrollTop,
              }};
            }}"""
        )
        assert all(stable_training_detail_actions.values()), stable_training_detail_actions
        assert actions[-1] == "pause"
        page.evaluate(
            f"""() => {{
              const actions = document.querySelector("#trainingDetailActions");
              window.__failedTrainingDetailActionFrame = {{
                viewJob: actions.querySelector('[data-training-job-id="{JOB_ID}"]'),
                primary: actions.querySelector(
                  '[data-training-run-job-id="{JOB_ID}"][data-action="resume"]'
                ),
                cancel: actions.querySelector(
                  '[data-training-run-job-id="{JOB_ID}"][data-action="cancel"]'
                ),
                review: actions.querySelector('[data-training-review-run-id="{RUN_ID}"]'),
                scrollTop: document.querySelector("#trainingDetailPane").scrollTop,
              }};
            }}"""
        )
        failed_resource_count = len(failed_resources)
        console_error_count = len(console_errors)
        job_action_fail_next[0] = True
        training_resume.click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('合成任务动作失败')"
        )
        page.wait_for_function(
            f"""() => !document.querySelector(
              '#trainingDetailActions [data-training-run-job-id="{JOB_ID}"]'
              + '[data-action="resume"]'
            ).disabled"""
        )
        failed_training_detail_action = page.evaluate(
            f"""() => {{
              const frame = window.__failedTrainingDetailActionFrame;
              const actions = document.querySelector("#trainingDetailActions");
              return {{
                viewJob: actions.querySelector('[data-training-job-id="{JOB_ID}"]')
                  === frame.viewJob,
                primary: actions.querySelector(
                  '[data-training-run-job-id="{JOB_ID}"][data-action="resume"]'
                ) === frame.primary,
                cancel: actions.querySelector(
                  '[data-training-run-job-id="{JOB_ID}"][data-action="cancel"]'
                ) === frame.cancel,
                review: actions.querySelector('[data-training-review-run-id="{RUN_ID}"]')
                  === frame.review,
                focus: document.activeElement === frame.primary,
                scroll: document.querySelector("#trainingDetailPane").scrollTop
                  === frame.scrollTop,
              }};
            }}"""
        )
        assert all(failed_training_detail_action.values()), failed_training_detail_action
        assert task_state["value"] == "paused"
        assert actions[-1] == "pause"
        assert len(failed_resources) == failed_resource_count + 1
        assert failed_resources[-1][0] == 409
        failed_resources.pop()
        assert len(console_errors) == console_error_count + 1
        assert "409" in console_errors[-1]
        console_errors.pop()
        page.get_by_role("button", name="打开标签审核").click()
        page.locator("#reviewQueueLayout:not(.hidden)").wait_for(state="visible")
        assert page.locator("#reviewTagSelect").input_value() == TAG_ID
        assert page.locator("#reviewGrid .review-card").count() == 1
        assert queue_source_queries[-1] == (SOURCE_IDS[0],)

        page.locator("#reviewBackButton").click()
        page.locator("#reviewOverview:not(.hidden)").wait_for(state="visible")
        page.get_by_role("button", name="取消").click()
        page.get_by_role("button", name="更新特征向量").wait_for(state="visible")
        assert actions[-2:] == ["pause", "cancel"]

        page.get_by_role("button", name="更新特征向量").click()
        dialog = page.locator("#trainingSetupDialog")
        dialog.wait_for(state="visible")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "trainingSetup"
        assert page.locator('[data-training-setup-method="featureKnn"]').get_attribute("aria-checked") == "true"
        assert page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        assert page.locator("[data-training-source-id]:checked").count() == 1
        assert page.locator(
            f'[data-training-source-id="{SOURCE_IDS[0]}"]'
        ).is_checked()
        second_training_source = page.locator(
            f'[data-training-source-id="{SOURCE_IDS[1]}"]'
        )
        training_source_frame = page.evaluate(
            """sourceIDs => {
              const options = document.querySelector('#trainingScopeOptions');
              options.style.maxHeight = '46px';
              options.scrollTop = options.scrollHeight;
              const firstInput = options.querySelector(
                `[data-training-source-id="${sourceIDs[0]}"]`
              );
              const secondInput = options.querySelector(
                `[data-training-source-id="${sourceIDs[1]}"]`
              );
              secondInput.focus({ preventScroll: true });
              window.__trainingSourceContinuityFrame = {
                firstRow: firstInput.closest('label'),
                firstInput,
                secondRow: secondInput.closest('label'),
                secondInput,
                secondName: secondInput.nextElementSibling,
              };
              return { scrollTop: options.scrollTop };
            }""",
            SOURCE_IDS,
        )
        assert training_source_frame["scrollTop"] > 0, training_source_frame
        second_training_source_bounds = second_training_source.bounding_box()
        assert second_training_source_bounds is not None
        page.mouse.move(
            second_training_source_bounds["x"]
            + second_training_source_bounds["width"] / 2,
            second_training_source_bounds["y"]
            + second_training_source_bounds["height"] / 2,
        )
        page.mouse.click(
            second_training_source_bounds["x"]
            + second_training_source_bounds["width"] / 2,
            second_training_source_bounds["y"]
            + second_training_source_bounds["height"] / 2,
        )
        training_source_continuity = page.evaluate(
            """({ sourceIDs, expectedScrollTop }) => {
              const frame = window.__trainingSourceContinuityFrame;
              const options = document.querySelector('#trainingScopeOptions');
              const firstInput = options.querySelector(
                `[data-training-source-id="${sourceIDs[0]}"]`
              );
              const secondInput = options.querySelector(
                `[data-training-source-id="${sourceIDs[1]}"]`
              );
              return {
                firstRow: firstInput?.closest('label') === frame.firstRow,
                firstInput: firstInput === frame.firstInput,
                secondRow: secondInput?.closest('label') === frame.secondRow,
                secondInput: secondInput === frame.secondInput,
                secondName: secondInput?.nextElementSibling === frame.secondName,
                focused: document.activeElement === secondInput,
                hovered: secondInput?.matches(':hover') || false,
                scroll: options.scrollTop === expectedScrollTop,
                checked: secondInput?.checked || false,
              };
            }""",
            {
                "sourceIDs": SOURCE_IDS,
                "expectedScrollTop": training_source_frame["scrollTop"],
            },
        )
        assert training_source_continuity == {
            "firstRow": True,
            "firstInput": True,
            "secondRow": True,
            "secondInput": True,
            "secondName": True,
            "focused": True,
            "hovered": True,
            "scroll": True,
            "checked": True,
        }, training_source_continuity
        page.evaluate(
            "document.querySelector('#trainingScopeOptions').style.removeProperty('max-height')"
        )
        second_training_source.uncheck()
        page.locator("#trainingTagSearch").fill("")
        second_training_tag = page.locator(
            f'[data-training-tag-id="{SECOND_TAG_ID}"]'
        )
        training_tag_frame = page.evaluate(
            """tagIDs => {
              const options = document.querySelector('#trainingTagOptions');
              options.style.maxHeight = '46px';
              options.scrollTop = options.scrollHeight;
              const firstInput = options.querySelector(
                `[data-training-tag-id="${tagIDs[0]}"]`
              );
              const secondInput = options.querySelector(
                `[data-training-tag-id="${tagIDs[1]}"]`
              );
              secondInput.focus({ preventScroll: true });
              window.__trainingTagContinuityFrame = {
                firstRow: firstInput.closest('label'),
                firstInput,
                secondRow: secondInput.closest('label'),
                secondInput,
                secondName: secondInput.nextElementSibling,
              };
              return { scrollTop: options.scrollTop };
            }""",
            [TAG_ID, SECOND_TAG_ID],
        )
        assert training_tag_frame["scrollTop"] > 0, training_tag_frame
        second_training_tag_bounds = second_training_tag.bounding_box()
        assert second_training_tag_bounds is not None
        page.mouse.move(
            second_training_tag_bounds["x"]
            + second_training_tag_bounds["width"] / 2,
            second_training_tag_bounds["y"]
            + second_training_tag_bounds["height"] / 2,
        )
        page.mouse.click(
            second_training_tag_bounds["x"]
            + second_training_tag_bounds["width"] / 2,
            second_training_tag_bounds["y"]
            + second_training_tag_bounds["height"] / 2,
        )
        training_tag_continuity = page.evaluate(
            """({ tagIDs, expectedScrollTop }) => {
              const frame = window.__trainingTagContinuityFrame;
              const options = document.querySelector('#trainingTagOptions');
              const firstInput = options.querySelector(
                `[data-training-tag-id="${tagIDs[0]}"]`
              );
              const secondInput = options.querySelector(
                `[data-training-tag-id="${tagIDs[1]}"]`
              );
              return {
                firstRow: firstInput?.closest('label') === frame.firstRow,
                firstInput: firstInput === frame.firstInput,
                secondRow: secondInput?.closest('label') === frame.secondRow,
                secondInput: secondInput === frame.secondInput,
                secondName: secondInput?.nextElementSibling === frame.secondName,
                focused: document.activeElement === secondInput,
                hovered: secondInput?.matches(':hover') || false,
                scroll: options.scrollTop === expectedScrollTop,
                checked: secondInput?.checked || false,
              };
            }""",
            {
                "tagIDs": [TAG_ID, SECOND_TAG_ID],
                "expectedScrollTop": training_tag_frame["scrollTop"],
            },
        )
        assert training_tag_continuity == {
            "firstRow": True,
            "firstInput": True,
            "secondRow": True,
            "secondInput": True,
            "secondName": True,
            "focused": True,
            "hovered": True,
            "scroll": True,
            "checked": True,
        }, training_tag_continuity
        page.evaluate(
            "document.querySelector('#trainingTagOptions').style.removeProperty('max-height')"
        )
        page.locator(f'[data-training-tag-id="{TAG_ID}"]').check()
        personal_method = page.locator(
            '[data-training-setup-method="personalCentroid"]'
        )
        page.evaluate(
            """() => {
              const methods = document.querySelector('#trainingSetupMethods');
              const feature = methods.querySelector(
                '[data-training-setup-method="featureKnn"]'
              );
              const personal = methods.querySelector(
                '[data-training-setup-method="personalCentroid"]'
              );
              const adamw = methods.querySelector(
                '[data-training-setup-method="personalAdamW"]'
              );
              feature.focus({ preventScroll: true });
              window.__trainingMethodContinuityFrame = { feature, personal, adamw };
            }"""
        )
        assert page.locator(
            '[data-training-setup-method="featureKnn"]'
        ).get_attribute("tabindex") == "0"
        assert personal_method.get_attribute("tabindex") == "-1"
        assert page.locator(
            '[data-training-setup-method="personalAdamW"]'
        ).get_attribute("tabindex") == "-1"
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.trainingSetupMethod"
        ) == "personalCentroid"
        assert personal_method.get_attribute("aria-checked") == "true"
        page.keyboard.press("Home")
        assert page.evaluate(
            "() => document.activeElement?.dataset.trainingSetupMethod"
        ) == "featureKnn"
        page.keyboard.press("ArrowRight")
        assert page.evaluate(
            "() => document.activeElement?.dataset.trainingSetupMethod"
        ) == "personalCentroid"
        personal_method_bounds = personal_method.bounding_box()
        assert personal_method_bounds is not None
        page.mouse.move(
            personal_method_bounds["x"] + personal_method_bounds["width"] / 2,
            personal_method_bounds["y"] + personal_method_bounds["height"] / 2,
        )
        training_method_continuity = page.evaluate(
            """() => {
              const frame = window.__trainingMethodContinuityFrame;
              const methods = document.querySelector('#trainingSetupMethods');
              const feature = methods.querySelector(
                '[data-training-setup-method="featureKnn"]'
              );
              const personal = methods.querySelector(
                '[data-training-setup-method="personalCentroid"]'
              );
              const adamw = methods.querySelector(
                '[data-training-setup-method="personalAdamW"]'
              );
              return {
                feature: feature === frame.feature,
                personal: personal === frame.personal,
                adamw: adamw === frame.adamw,
                focused: document.activeElement === personal,
                hovered: personal?.matches(':hover') || false,
                selected: personal?.getAttribute('aria-checked') === 'true',
              };
            }"""
        )
        assert training_method_continuity == {
            "feature": True,
            "personal": True,
            "adamw": True,
            "focused": True,
            "hovered": True,
            "selected": True,
        }, training_method_continuity
        page.evaluate(
            """() => {
              const input = document.querySelector(
                '#trainingScopeOptions [data-training-scope="allSources"]'
              );
              window.__trainingScopeContinuityFrame = {
                row: input.closest('label'),
                input,
                title: input.nextElementSibling,
              };
            }"""
        )
        page.locator(f'[data-training-tag-id="{TAG_ID}"]').check()
        training_scope_continuity = page.evaluate(
            """() => {
              const frame = window.__trainingScopeContinuityFrame;
              const input = document.querySelector(
                '#trainingScopeOptions [data-training-scope="allSources"]'
              );
              return {
                row: input?.closest('label') === frame.row,
                input: input === frame.input,
                title: input?.nextElementSibling === frame.title,
                checked: input?.checked || false,
              };
            }"""
        )
        assert training_scope_continuity == {
            "row": True,
            "input": True,
            "title": True,
            "checked": True,
        }, training_scope_continuity
        page.locator('[data-training-setup-method="featureKnn"]').click()
        page.locator(
            f'[data-training-source-id="{SOURCE_IDS[1]}"]'
        ).uncheck()
        training_reads_after_open = training_setup_reads[0]
        page.locator("#trainingTagSearch").fill("猫草稿")
        training_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "猫草稿" not in training_history_payload
        assert "Apple Photos" not in training_history_payload
        training_history_frame = page.evaluate(
            """sourceID => {
              const options = document.querySelector('#trainingScopeOptions');
              options.style.maxHeight = '46px';
              options.scrollTop = options.scrollHeight;
              const input = options.querySelector(
                `[data-training-source-id="${sourceID}"]`
              );
              input.focus({ preventScroll: true });
              window.__trainingHistoryContinuityFrame = {
                row: input.closest('label'),
                input,
                name: input.nextElementSibling,
              };
              return { scrollTop: options.scrollTop };
            }""",
            SOURCE_IDS[0],
        )
        assert training_history_frame["scrollTop"] > 0, training_history_frame
        page.evaluate("() => history.back()")
        dialog.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.dataset.reviewFeatureTagId != null"
        )
        page.evaluate("() => history.forward()")
        page.locator("#trainingSetupDialog[open]").wait_for()
        assert page.locator("#trainingTagSearch").input_value() == "猫草稿"
        assert training_setup_reads[0] == training_reads_after_open
        training_history_continuity = page.evaluate(
            """({ sourceID, expectedScrollTop }) => {
              const frame = window.__trainingHistoryContinuityFrame;
              const options = document.querySelector('#trainingScopeOptions');
              const input = options.querySelector(
                `[data-training-source-id="${sourceID}"]`
              );
              return {
                row: input?.closest('label') === frame.row,
                input: input === frame.input,
                name: input?.nextElementSibling === frame.name,
                focused: document.activeElement === input,
                scroll: options.scrollTop === expectedScrollTop,
                checked: input?.checked || false,
              };
            }""",
            {
                "sourceID": SOURCE_IDS[0],
                "expectedScrollTop": training_history_frame["scrollTop"],
            },
        )
        assert training_history_continuity == {
            "row": True,
            "input": True,
            "name": True,
            "focused": True,
            "scroll": True,
            "checked": True,
        }, training_history_continuity
        page.evaluate(
            "document.querySelector('#trainingScopeOptions').style.removeProperty('max-height')"
        )
        page.locator("#trainingTagSearch").fill("猫")
        assert page.locator(f'[data-training-tag-id="{TAG_ID}"]').is_checked()
        page.screenshot(
            path="/tmp/imageall-training-setup-continuity-wide.png",
            full_page=True,
        )
        page.locator("#launchTrainingButton").click()
        page.wait_for_function("() => !document.querySelector('#trainingSetupDialog').open")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) != "trainingSetup"
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
