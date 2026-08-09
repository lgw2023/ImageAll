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
    suggestion_completed = False
    review_queue_reads = 0
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
            fulfill_json(route, overview(suggestion_completed))

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
                        "score": 0.91 - index * 0.04,
                    } for index, asset_id in enumerate(REVIEW_IDS)],
                    "nextCursor": None,
                },
            )

        page.route("**/v1/review/queue?**", route_review_queue)
        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )

        def route_tag_snapshot(route):
            nonlocal suggestion_reads, suggestion_active, suggestion_completed
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
        assert "猫" in page.locator("#tagSuggestionDialogTitle").inner_text()
        assert page.locator("#tagSuggestionThresholdSummary").inner_text() == "0.420"
        assert page.locator("#tagSuggestionLimitSummary").inner_text() == "Top 25"
        assert page.locator("#tagSuggestionSourceOptions input:checked").count() == 1
        assert page.locator(
            f'#tagSuggestionSourceOptions input[value="{SOURCE_IDS[0]}"]'
        ).is_checked()

        page.set_viewport_size({"width": 390, "height": 844})
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        dialog_width = dialog.evaluate("element => element.getBoundingClientRect().width")
        assert dialog_width <= 370.5

        assert page.locator("#tagSuggestionSelectionSummary").inner_text() == "已选择 1 个来源"
        page.locator("#launchTagSuggestionButton").click()
        page.wait_for_function("() => !document.querySelector('#tagSuggestionDialog').open")
        assert len(submitted) == 1
        assert submitted[0]["mediaKind"] == "image"
        assert submitted[0]["method"] == "personalCentroid"
        assert submitted[0]["tagID"] == TAG_ID
        assert submitted[0]["sourceIDs"] == [SOURCE_IDS[0]]

        page.locator("#reviewQueueLayout:not(.hidden)").wait_for(state="visible", timeout=6_000)
        assert page.locator("#reviewTagSelect").input_value() == TAG_ID
        assert review_queue_reads >= 1
        assert page.locator("#reviewGrid .review-card").count() == 2
        assert not page_errors, page_errors
        assert not failed_resources, failed_resources
        assert not console_errors, console_errors
        context.close()
        browser.close()

    print("tag-library-suggestion-browser: ok")


if __name__ == "__main__":
    main()
