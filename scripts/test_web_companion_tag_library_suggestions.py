#!/usr/bin/env python3
import base64
import json
import re

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8803"
TAG_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
SOURCE_IDS = [
    "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb",
    "cccccccc-1111-2222-3333-cccccccccccc",
]
REVIEW_IDS = [
    "dddddddd-1111-2222-3333-dddddddddddd",
    "eeeeeeee-1111-2222-3333-eeeeeeeeeeee",
]
OPERATION_ID = "ffffffff-1111-2222-3333-ffffffffffff"
PIXEL = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def overview(completed):
    pending = 2 if completed else 0
    return {
        "mediaKind": "image",
        "sourceIDs": [],
        "totalPendingSuggestionCount": pending,
        "tags": [{
            "id": TAG_ID,
            "displayName": "猫",
            "acceptedSampleCount": 8,
            "rejectedSampleCount": 5,
            "pendingSuggestionCount": pending,
            "pendingSuggestionCounts": {
                "featurePrint": 0,
                "standardModel": 0,
                "personalModel": pending,
                "personalAdamW": 0,
            },
            "taskStatus": "completed" if completed else "ready",
            "checkedCount": 40 if completed else 0,
            "totalCount": 40 if completed else None,
            "skippedCount": 1 if completed else 0,
            "missingPositiveCount": 0,
            "missingNegativeCount": 0,
            "canGenerate": True,
            "canUpdate": False,
            "canGeneratePersonalModel": True,
            "canReview": completed,
            "canPause": False,
            "canResume": False,
            "canCancel": False,
            "activeJobID": None,
        }],
    }


def activity(phase):
    terminal = phase == "completed"
    return {
        "operationID": OPERATION_ID,
        "mediaKind": "image",
        "method": "personalCentroid",
        "tagID": TAG_ID,
        "phase": phase,
        "completedUnitCount": 40 if terminal else 12,
        "totalUnitCount": 40,
        "aboveThresholdCount": 3 if terminal else 1,
        "insertedCount": 2 if terminal else 0,
        "skippedCount": 1 if terminal else 0,
        "errorCode": None,
        "availableActions": [] if terminal else ["cancel"],
    }


def main():
    submitted = []
    suggestion_active = False
    suggestion_reads = 0
    tag_snapshot_reads = 0
    suggestion_completed = False
    review_overview_checked_count = 0
    review_queue_reads = 0
    review_queue_score_adjustment = 0.0
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
                    "hostID": "11111111-1111-1111-1111-111111111111",
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
                [{"id": TAG_ID, "displayName": "猫", "state": "active", "groupID": None}],
            ),
        )
        page.route("**/v1/tag-groups", lambda route: fulfill_json(route, []))
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
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

        def route_review_overview(route):
            payload = overview(suggestion_completed)
            payload["tags"][0]["checkedCount"] = review_overview_checked_count
            fulfill_json(route, payload)

        page.route("**/v1/review/overview?**", route_review_overview)

        def route_review_queue(route):
            nonlocal review_queue_reads
            review_queue_reads += 1
            fulfill_json(
                route,
                {
                    "items": [{
                        "assetID": asset_id,
                        "fileName": f"CAT_{index + 1:04}.JPG",
                        "availability": "available",
                        "acceptedTagCount": 0,
                        "rejectedTagCount": 0,
                        "suggestionOrigin": "personalModel",
                        "score": 0.91 - index * 0.04
                        + (review_queue_score_adjustment if index == 0 else 0.0),
                    } for index, asset_id in enumerate(REVIEW_IDS)],
                    "nextCursor": None,
                },
            )

        page.route("**/v1/review/queue?**", route_review_queue)

        def route_asset_detail(route):
            asset_id = route.request.url.rsplit("/", 1)[-1]
            index = REVIEW_IDS.index(asset_id)
            fulfill_json(
                route,
                {
                    "assetID": asset_id,
                    "sourceID": SOURCE_IDS[0],
                    "sourceName": "Apple Photos",
                    "fileName": f"CAT_{index + 1:04}.JPG",
                    "relativePath": None,
                    "mediaType": "public.jpeg",
                    "availability": "available",
                    "contentRevision": 1,
                    "acceptedTagCount": 0,
                    "rejectedTagCount": 0,
                    "mediaCreatedAtMs": 1_700_000_000_000 + index,
                    "mediaModifiedAtMs": 1_700_000_100_000 + index,
                    "width": 1200,
                    "height": 900,
                    "fingerprintSizeBytes": 800_000,
                    "tags": [{
                        "tagID": TAG_ID,
                        "displayName": "猫",
                        "decision": "unknown",
                    }],
                    "pendingSuggestions": [{
                        "tagID": TAG_ID,
                        "displayName": "猫",
                        "suggestionOrigin": "personalModel",
                    }],
                },
            )

        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+$"),
            route_asset_detail,
        )
        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )

        def route_tag_snapshot(route):
            nonlocal suggestion_reads, tag_snapshot_reads, suggestion_active, suggestion_completed
            tag_snapshot_reads += 1
            activities = []
            if suggestion_active:
                suggestion_reads += 1
                phase = "completed" if suggestion_reads >= 2 else "scoring"
                activities = [activity(phase)]
                if phase == "completed":
                    suggestion_active = False
                    suggestion_completed = True
            fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "maximumPendingCount": 25,
                    "personalCentroidAvailable": True,
                    "personalAdamWAvailable": True,
                    "tags": [{
                        "tagID": TAG_ID,
                        "personalEligible": True,
                        "personalCentroidMinScore": 0.42,
                        "personalAdamWMinScore": 0.61,
                    }],
                    "activities": activities,
                },
            )

        page.route("**/v1/tag-library-suggestions?**", route_tag_snapshot)

        def route_tag_submit(route):
            nonlocal suggestion_active, suggestion_reads
            payload = route.request.post_data_json
            submitted.append(payload)
            suggestion_active = True
            suggestion_reads = 0
            fulfill_json(
                route,
                {"activity": activity("preparingCandidates"), "replayed": False},
                status=202,
            )

        page.route("**/v1/tag-library-suggestions/requests", route_tag_submit)

        page.goto(BASE_URL, wait_until="networkidle")
        page.locator("#reviewButton").click()
        page.locator(
            f'[data-review-control-tag-id="{TAG_ID}"] > summary'
        ).click()
        centroid_button = page.get_by_role("button", name="个人模型 Top 25")
        centroid_button.wait_for(state="visible")
        page.evaluate(
            f"""
            () => {{
              const originalFetch = window.fetch.bind(window);
              window.__reviewOverviewRefreshRelease = null;
              window.fetch = (input, init) => {{
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/review/overview") return originalFetch(input, init);
                return new Promise((resolve, reject) => {{
                  window.__reviewOverviewRefreshRelease = () => {{
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  }};
                }});
              }};
              const grid = document.querySelector("#reviewOverviewGrid");
              const content = document.querySelector(".review-overview-content");
              const openButton = document.querySelector(
                '[data-review-overview-tag-id="{TAG_ID}"]'
              );
              const details = document.querySelector(
                '[data-review-control-tag-id="{TAG_ID}"]'
              );
              const action = details.querySelector('[data-tag-suggestion-method="personalCentroid"]');
              grid.style.paddingBottom = "720px";
              content.scrollTop = 60;
              action.focus({{ preventScroll: true }});
              window.__reviewOverviewStableFrame = {{
                card: openButton.closest(".review-overview-card"),
                openButton,
                details,
                action,
                group: openButton.closest(".review-overview-group"),
                groupToggle: openButton.closest(".review-overview-group")
                  .querySelector("[data-review-overview-group-toggle]"),
                scrollTop: content.scrollTop,
              }};
              void loadReviewOverview();
            }}
            """
        )
        page.wait_for_function("() => state.review.overviewLoading")
        assert page.evaluate(
            f"""
            () => {{
              const frame = window.__reviewOverviewStableFrame;
              const openButton = document.querySelector(
                '[data-review-overview-tag-id="{TAG_ID}"]'
              );
              const details = document.querySelector(
                '[data-review-control-tag-id="{TAG_ID}"]'
              );
              return frame.card === openButton.closest(".review-overview-card")
                && frame.openButton === openButton
                && frame.details === details
                && frame.action === details.querySelector(
                  '[data-tag-suggestion-method="personalCentroid"]'
                )
                && frame.group === openButton.closest(".review-overview-group")
                && frame.groupToggle === openButton.closest(".review-overview-group")
                  .querySelector("[data-review-overview-group-toggle]")
                && details.open
                && document.activeElement === frame.action
                && document.querySelector(".review-overview-content").scrollTop
                  === frame.scrollTop;
            }}
            """
        ), "review overview refresh replaced the expanded card while pending"
        page.evaluate("() => window.__reviewOverviewRefreshRelease()")
        page.wait_for_function("() => !state.review.overviewLoading")
        assert page.evaluate(
            f"""
            () => {{
              const frame = window.__reviewOverviewStableFrame;
              const openButton = document.querySelector(
                '[data-review-overview-tag-id="{TAG_ID}"]'
              );
              const details = document.querySelector(
                '[data-review-control-tag-id="{TAG_ID}"]'
              );
              return frame.card === openButton.closest(".review-overview-card")
                && frame.openButton === openButton
                && frame.details === details
                && frame.action === details.querySelector(
                  '[data-tag-suggestion-method="personalCentroid"]'
                )
                && frame.group === openButton.closest(".review-overview-group")
                && frame.groupToggle === openButton.closest(".review-overview-group")
                  .querySelector("[data-review-overview-group-toggle]")
                && details.open
                && document.activeElement === frame.action
                && document.querySelector(".review-overview-content").scrollTop
                  === frame.scrollTop;
            }}
            """
        ), "unchanged review overview refresh replaced the expanded card"
        page.evaluate(
            f"""
            () => {{
              const originalFetch = window.fetch.bind(window);
              window.__reviewOverviewRefreshRelease = null;
              window.fetch = (input, init) => {{
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/review/overview") return originalFetch(input, init);
                return new Promise((resolve, reject) => {{
                  window.__reviewOverviewRefreshRelease = () => {{
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  }};
                }});
              }};
              const openButton = document.querySelector(
                '[data-review-overview-tag-id="{TAG_ID}"]'
              );
              const details = document.querySelector(
                '[data-review-control-tag-id="{TAG_ID}"]'
              );
              const action = details.querySelector('[data-tag-suggestion-method="personalCentroid"]');
              const content = document.querySelector(".review-overview-content");
              action.focus({{ preventScroll: true }});
              window.__reviewOverviewChangedFrame = {{
                card: openButton.closest(".review-overview-card"),
                openButton,
                details,
                action,
                group: openButton.closest(".review-overview-group"),
                groupToggle: openButton.closest(".review-overview-group")
                  .querySelector("[data-review-overview-group-toggle]"),
                scrollTop: content.scrollTop,
              }};
              void loadReviewOverview();
            }}
            """
        )
        page.wait_for_function("() => Boolean(window.__reviewOverviewRefreshRelease)")
        review_overview_checked_count = 1
        page.evaluate("() => window.__reviewOverviewRefreshRelease()")
        page.wait_for_function("() => !state.review.overviewLoading")
        assert page.evaluate(
            f"""
            () => {{
              const frame = window.__reviewOverviewChangedFrame;
              const openButton = document.querySelector(
                '[data-review-overview-tag-id="{TAG_ID}"]'
              );
              const details = document.querySelector(
                '[data-review-control-tag-id="{TAG_ID}"]'
              );
              return frame.card === openButton.closest(".review-overview-card")
                && frame.openButton === openButton
                && frame.details === details
                && frame.action === details.querySelector(
                  '[data-tag-suggestion-method="personalCentroid"]'
                )
                && frame.group === openButton.closest(".review-overview-group")
                && frame.groupToggle === openButton.closest(".review-overview-group")
                  .querySelector("[data-review-overview-group-toggle]")
                && openButton.querySelector(".review-overview-status")
                  .textContent.includes("1 项已检查")
                && details.open
                && document.activeElement === frame.action
                && document.querySelector(".review-overview-content").scrollTop
                  === frame.scrollTop;
            }}
            """
        ), "changed review overview did not update the existing card in place"
        page.evaluate(
            f"""
            () => {{
              const originalFetch = window.fetch.bind(window);
              window.fetch = (input, init) => {{
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/review/overview") return originalFetch(input, init);
                window.fetch = originalFetch;
                return Promise.reject(new Error("模拟审核总览刷新失败"));
              }};
              const openButton = document.querySelector(
                '[data-review-overview-tag-id="{TAG_ID}"]'
              );
              const details = document.querySelector(
                '[data-review-control-tag-id="{TAG_ID}"]'
              );
              const action = details.querySelector('[data-tag-suggestion-method="personalCentroid"]');
              const content = document.querySelector(".review-overview-content");
              action.focus({{ preventScroll: true }});
              window.__reviewOverviewFailedFrame = {{
                card: openButton.closest(".review-overview-card"),
                openButton,
                details,
                action,
                group: openButton.closest(".review-overview-group"),
                groupToggle: openButton.closest(".review-overview-group")
                  .querySelector("[data-review-overview-group-toggle]"),
                scrollTop: content.scrollTop,
              }};
              void loadReviewOverview();
            }}
            """
        )
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent"
            ".includes('模拟审核总览刷新失败')"
        )
        failed_refresh_frame = page.evaluate(
            f"""
            () => {{
              const frame = window.__reviewOverviewFailedFrame;
              const openButton = document.querySelector(
                '[data-review-overview-tag-id="{TAG_ID}"]'
              );
              const details = document.querySelector(
                '[data-review-control-tag-id="{TAG_ID}"]'
              );
              return {{
                card: frame.card === openButton.closest(".review-overview-card"),
                openButton: frame.openButton === openButton,
                details: frame.details === details,
                action: frame.action === details.querySelector(
                  '[data-tag-suggestion-method="personalCentroid"]'
                ),
                group: frame.group === openButton.closest(".review-overview-group"),
                groupToggle: frame.groupToggle === openButton.closest(".review-overview-group")
                  .querySelector("[data-review-overview-group-toggle]"),
                expanded: details.open,
                focused: document.activeElement === details.querySelector(":scope > summary"),
                scroll: document.querySelector(".review-overview-content").scrollTop
                  === frame.scrollTop,
              }};
            }}
            """
        )
        assert all(failed_refresh_frame.values()), failed_refresh_frame
        page.screenshot(
            path="/tmp/imageall-review-overview-refresh-continuity.png",
            full_page=True,
        )
        assert review_queue_reads == 0, "生成入口不应提前打开审核队列"
        page.locator("#reviewSourceFilterButton").click()
        second_review_source = page.locator(
            f'[data-review-source-id="{SOURCE_IDS[1]}"]'
        )
        second_review_source.click()
        page.wait_for_function(
            "() => document.querySelector('#reviewSourceFilterSummary')?.textContent"
            " === '仅显示：Apple Photos'"
        )
        second_review_source.press("Escape")
        centroid_button.click()

        dialog = page.locator("#tagSuggestionDialog")
        dialog.wait_for(state="visible")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) == "tagSuggestion"
        assert "猫" in page.locator("#tagSuggestionDialogTitle").inner_text()
        assert page.locator("#tagSuggestionThresholdSummary").inner_text() == "0.420"
        assert page.locator("#tagSuggestionLimitSummary").inner_text() == "Top 25"
        assert page.locator("#tagSuggestionSourceOptions input:checked").count() == 1
        assert page.locator(
            f'#tagSuggestionSourceOptions input[value="{SOURCE_IDS[0]}"]'
        ).is_checked()
        tag_reads_after_open = tag_snapshot_reads
        second_tag_source = page.locator(
            f'#tagSuggestionSourceOptions input[value="{SOURCE_IDS[1]}"]'
        )
        tag_source_frame = page.evaluate(
            """sourceIDs => {
              const options = document.querySelector('#tagSuggestionSourceOptions');
              options.style.gridTemplateColumns = '1fr';
              options.style.maxHeight = '46px';
              options.scrollTop = options.scrollHeight;
              const firstInput = options.querySelector(`input[value="${sourceIDs[0]}"]`);
              const secondInput = options.querySelector(`input[value="${sourceIDs[1]}"]`);
              secondInput.focus({ preventScroll: true });
              window.__tagSuggestionSourceContinuityFrame = {
                firstLabel: firstInput.closest('label'),
                firstInput,
                secondLabel: secondInput.closest('label'),
                secondInput,
                secondName: secondInput.nextElementSibling,
              };
              return { scrollTop: options.scrollTop };
            }""",
            SOURCE_IDS,
        )
        assert tag_source_frame["scrollTop"] > 0, tag_source_frame
        second_tag_source_bounds = second_tag_source.bounding_box()
        assert second_tag_source_bounds is not None
        page.mouse.move(
            second_tag_source_bounds["x"] + second_tag_source_bounds["width"] / 2,
            second_tag_source_bounds["y"] + second_tag_source_bounds["height"] / 2,
        )
        page.mouse.click(
            second_tag_source_bounds["x"] + second_tag_source_bounds["width"] / 2,
            second_tag_source_bounds["y"] + second_tag_source_bounds["height"] / 2,
        )
        page.wait_for_function(
            "() => document.querySelector('#tagSuggestionSelectionSummary')?.textContent"
            " === '已选择 2 个来源'"
        )
        tag_source_continuity = page.evaluate(
            """({ sourceIDs, expectedScrollTop }) => {
              const frame = window.__tagSuggestionSourceContinuityFrame;
              const options = document.querySelector('#tagSuggestionSourceOptions');
              const firstInput = options.querySelector(`input[value="${sourceIDs[0]}"]`);
              const secondInput = options.querySelector(`input[value="${sourceIDs[1]}"]`);
              return {
                firstLabel: firstInput?.closest('label') === frame.firstLabel,
                firstInput: firstInput === frame.firstInput,
                secondLabel: secondInput?.closest('label') === frame.secondLabel,
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
                "expectedScrollTop": tag_source_frame["scrollTop"],
            },
        )
        assert tag_source_continuity == {
            "firstLabel": True,
            "firstInput": True,
            "secondLabel": True,
            "secondInput": True,
            "secondName": True,
            "focused": True,
            "hovered": True,
            "scroll": True,
            "checked": True,
        }, tag_source_continuity
        suggestion_history_payload = page.evaluate(
            "() => JSON.stringify(history.state?.imageAllWorkspace || null)"
        )
        assert "猫" not in suggestion_history_payload
        assert "Apple Photos" not in suggestion_history_payload
        page.evaluate("() => history.back()")
        dialog.wait_for(state="hidden")
        page.wait_for_function(
            "() => document.activeElement?.dataset.tagSuggestionMethod === 'personalCentroid'"
        )
        page.evaluate("() => history.forward()")
        page.locator("#tagSuggestionDialog[open]").wait_for()
        tag_source_history_continuity = page.evaluate(
            """expectedScrollTop => {
              const frame = window.__tagSuggestionSourceContinuityFrame;
              const options = document.querySelector('#tagSuggestionSourceOptions');
              const secondInput = options.querySelector(
                `input[value="${frame.secondInput.value}"]`
              );
              return {
                firstLabel: frame.firstLabel.isConnected,
                firstInput: frame.firstInput.isConnected,
                secondLabel: secondInput?.closest('label') === frame.secondLabel,
                secondInput: secondInput === frame.secondInput,
                secondName: secondInput?.nextElementSibling === frame.secondName,
                focused: document.activeElement === secondInput,
                scroll: options.scrollTop === expectedScrollTop,
                checked: secondInput?.checked || false,
              };
            }""",
            tag_source_frame["scrollTop"],
        )
        assert tag_source_history_continuity == {
            "firstLabel": True,
            "firstInput": True,
            "secondLabel": True,
            "secondInput": True,
            "secondName": True,
            "focused": True,
            "scroll": True,
            "checked": True,
        }, tag_source_history_continuity
        assert page.locator("#tagSuggestionSourceOptions input:checked").count() == 2
        assert tag_snapshot_reads == tag_reads_after_open
        page.evaluate(
            """() => {
              const options = document.querySelector('#tagSuggestionSourceOptions');
              options.style.removeProperty('grid-template-columns');
              options.style.removeProperty('max-height');
            }"""
        )
        page.locator(
            f'#tagSuggestionSourceOptions input[value="{SOURCE_IDS[1]}"]'
        ).uncheck()

        page.set_viewport_size({"width": 390, "height": 844})
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        dialog_width = dialog.evaluate("element => element.getBoundingClientRect().width")
        assert dialog_width <= 370.5

        assert page.locator("#tagSuggestionSelectionSummary").inner_text() == "已选择 1 个来源"
        page.locator("#launchTagSuggestionButton").click()
        page.wait_for_function("() => !document.querySelector('#tagSuggestionDialog').open")
        assert page.evaluate(
            "() => history.state?.imageAllWorkspace?.navigationLevel"
        ) != "tagSuggestion"
        assert len(submitted) == 1
        assert submitted[0]["mediaKind"] == "image"
        assert submitted[0]["method"] == "personalCentroid"
        assert submitted[0]["tagID"] == TAG_ID
        assert submitted[0]["sourceIDs"] == [SOURCE_IDS[0]]

        page.locator("#reviewQueueLayout:not(.hidden)").wait_for(state="visible", timeout=6_000)
        assert page.locator("#reviewTagSelect").input_value() == TAG_ID
        assert review_queue_reads >= 1
        assert page.locator("#reviewGrid .review-card").count() == 2
        page.set_viewport_size({"width": 1440, "height": 960})
        page.wait_for_timeout(200)
        page.wait_for_function(
            "() => [...document.querySelectorAll('#reviewGrid .review-card img')]"
            ".every(image => image.complete && !image.classList.contains('loading'))"
        )
        page.evaluate(
            """() => {
              const originalFetch = window.fetch.bind(window);
              window.__reviewQueueRefreshRelease = null;
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/review/queue") return originalFetch(input, init);
                return new Promise((resolve, reject) => {
                  window.__reviewQueueRefreshRelease = () => {
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  };
                });
              };
              const grid = document.querySelector("#reviewGrid");
              const pane = document.querySelector("#reviewQueuePane");
              const card = grid.querySelector('[data-review-index="0"]');
              const main = card.querySelector(".review-card-main");
              grid.style.paddingBottom = "720px";
              pane.scrollTop = 80;
              main.focus({ preventScroll: true });
              window.__reviewQueueStableFrame = {
                cards: [...grid.querySelectorAll(":scope > .review-card")],
                mains: [...grid.querySelectorAll(":scope > .review-card > .review-card-main")],
                images: [...grid.querySelectorAll(":scope > .review-card img")],
                focused: main,
                scrollTop: pane.scrollTop,
              };
              document.querySelector("#refreshReviewButton").click();
            }"""
        )
        page.wait_for_function("() => Boolean(window.__reviewQueueRefreshRelease)")
        pending_queue_frame = page.evaluate(
            """() => {
              const frame = window.__reviewQueueStableFrame;
              const grid = document.querySelector("#reviewGrid");
              const pane = document.querySelector("#reviewQueuePane");
              const cards = [...grid.querySelectorAll(":scope > .review-card")];
              const mains = [...grid.querySelectorAll(":scope > .review-card > .review-card-main")];
              const images = [...grid.querySelectorAll(":scope > .review-card img")];
              return {
                cards: cards.length === frame.cards.length
                  && cards.every((card, index) => card === frame.cards[index]),
                mains: mains.every((main, index) => main === frame.mains[index]),
                images: images.length === frame.images.length
                  && images.every((image, index) => image === frame.images[index]),
                focus: document.activeElement === frame.focused,
                scroll: pane.scrollTop === frame.scrollTop,
              };
            }"""
        )
        assert all(pending_queue_frame.values()), pending_queue_frame
        page.evaluate("() => window.__reviewQueueRefreshRelease()")
        page.wait_for_function("() => !state.review.loading")
        assert page.evaluate(
            """() => {
              const frame = window.__reviewQueueStableFrame;
              const grid = document.querySelector("#reviewGrid");
              const pane = document.querySelector("#reviewQueuePane");
              const cards = [...grid.querySelectorAll(":scope > .review-card")];
              const mains = [...grid.querySelectorAll(":scope > .review-card > .review-card-main")];
              const images = [...grid.querySelectorAll(":scope > .review-card img")];
              return cards.length === frame.cards.length
                && cards.every((card, index) => card === frame.cards[index])
                && mains.every((main, index) => main === frame.mains[index])
                && images.every((image, index) => image === frame.images[index])
                && document.activeElement === frame.focused
                && pane.scrollTop === frame.scrollTop;
            }"""
        ), "unchanged review queue refresh replaced the successful frame"
        page.evaluate(
            """() => {
              const originalFetch = window.fetch.bind(window);
              window.__reviewQueueChangedRelease = null;
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/review/queue") return originalFetch(input, init);
                return new Promise((resolve, reject) => {
                  window.__reviewQueueChangedRelease = () => {
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  };
                });
              };
              const grid = document.querySelector("#reviewGrid");
              const pane = document.querySelector("#reviewQueuePane");
              const cards = [...grid.querySelectorAll(":scope > .review-card")];
              const main = cards[0].querySelector(".review-card-main");
              main.focus({ preventScroll: true });
              const untouchedMutations = [];
              const untouchedObserver = new MutationObserver((records) => {
                untouchedMutations.push(...records.map(record => ({
                  type: record.type,
                  attribute: record.attributeName,
                  target: record.target.id || record.target.className || record.target.nodeName,
                })));
              });
              untouchedObserver.observe(cards[1], {
                attributes: true,
                characterData: true,
                childList: true,
                subtree: true,
              });
              window.__reviewQueueChangedFrame = {
                cards,
                mains: cards.map(card => card.querySelector(".review-card-main")),
                images: cards.map(card => card.querySelector("img")),
                scores: cards.map(card => card.querySelector(".review-score")),
                focused: main,
                scrollTop: pane.scrollTop,
                untouchedObserver,
                untouchedMutations,
              };
              document.querySelector("#refreshReviewButton").click();
            }"""
        )
        page.wait_for_function("() => Boolean(window.__reviewQueueChangedRelease)")
        review_queue_score_adjustment = -0.11
        page.evaluate("() => window.__reviewQueueChangedRelease()")
        page.wait_for_function("() => !state.review.loading")
        changed_queue_frame = page.evaluate(
            """() => {
              const frame = window.__reviewQueueChangedFrame;
              const grid = document.querySelector("#reviewGrid");
              const pane = document.querySelector("#reviewQueuePane");
              const cards = [...grid.querySelectorAll(":scope > .review-card")];
              frame.untouchedMutations.push(...frame.untouchedObserver.takeRecords().map(record => ({
                type: record.type,
                attribute: record.attributeName,
                target: record.target.id || record.target.className || record.target.nodeName,
              })));
              frame.untouchedObserver.disconnect();
              return {
                cards: cards.length === frame.cards.length
                  && cards.every((card, index) => card === frame.cards[index]),
                controls: cards.every((card, index) => (
                  card.querySelector(".review-card-main") === frame.mains[index]
                  && card.querySelector("img") === frame.images[index]
                  && card.querySelector(".review-score") === frame.scores[index]
                )),
                content: cards[0].querySelector(".review-score").textContent === "80%",
                untouched: frame.untouchedMutations.length === 0,
                mutationDetails: frame.untouchedMutations,
                focus: document.activeElement === frame.focused,
                scroll: pane.scrollTop === frame.scrollTop,
              };
            }"""
        )
        assert all(
            changed_queue_frame[key]
            for key in ["cards", "controls", "content", "untouched", "focus", "scroll"]
        ), changed_queue_frame
        page.evaluate(
            """() => {
              const originalFetch = window.fetch.bind(window);
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/review/queue") return originalFetch(input, init);
                window.fetch = originalFetch;
                return Promise.reject(new Error("模拟审核队列刷新失败"));
              };
              const grid = document.querySelector("#reviewGrid");
              const pane = document.querySelector("#reviewQueuePane");
              const cards = [...grid.querySelectorAll(":scope > .review-card")];
              const main = cards[0].querySelector(".review-card-main");
              main.focus({ preventScroll: true });
              window.__reviewQueueFailedFrame = {
                cards,
                mains: cards.map(card => card.querySelector(".review-card-main")),
                images: cards.map(card => card.querySelector("img")),
                scores: cards.map(card => card.querySelector(".review-score")),
                focused: main,
                scrollTop: pane.scrollTop,
                selectedAssetIDs: [...state.review.selectedAssetIDs].sort(),
                selectedIndex: state.review.selectedIndex,
              };
              document.querySelector("#refreshReviewButton").click();
            }"""
        )
        page.wait_for_function(
            "() => !state.review.loading "
            "&& document.querySelector('#toastMessage').textContent"
            ".includes('模拟审核队列刷新失败')"
        )
        failed_queue_frame = page.evaluate(
            """() => {
              const frame = window.__reviewQueueFailedFrame;
              const grid = document.querySelector("#reviewGrid");
              const pane = document.querySelector("#reviewQueuePane");
              const cards = [...grid.querySelectorAll(":scope > .review-card")];
              return {
                cards: cards.length === frame.cards.length
                  && cards.every((card, index) => card === frame.cards[index]),
                controls: cards.every((card, index) => (
                  card.querySelector(".review-card-main") === frame.mains[index]
                  && card.querySelector("img") === frame.images[index]
                  && card.querySelector(".review-score") === frame.scores[index]
                )),
                lastGoodContent: cards[0].querySelector(".review-score").textContent === "80%",
                selection: JSON.stringify([...state.review.selectedAssetIDs].sort())
                  === JSON.stringify(frame.selectedAssetIDs)
                  && state.review.selectedIndex === frame.selectedIndex,
                focus: document.activeElement === frame.focused,
                scroll: pane.scrollTop === frame.scrollTop,
              };
            }"""
        )
        assert all(failed_queue_frame.values()), failed_queue_frame
        page.screenshot(
            path="/tmp/imageall-review-queue-refresh-continuity.png",
            full_page=True,
        )
        assert not page_errors, page_errors
        assert not failed_resources, failed_resources
        assert not console_errors, console_errors
        context.close()
        browser.close()

    print("tag-library-suggestion-browser: ok")


if __name__ == "__main__":
    main()
