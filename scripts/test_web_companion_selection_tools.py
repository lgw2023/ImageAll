#!/usr/bin/env python3
import base64
import json

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8802"
SOURCE_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
ASSET_IDS = [
    "11111111-1111-1111-1111-111111111111",
    "22222222-2222-2222-2222-222222222222",
]
PREPARATION_ID = "33333333-3333-3333-3333-333333333333"
SLIMMING_JOB_ID = "44444444-4444-4444-4444-444444444444"
SAMPLE_SUGGESTION_ID = "77777777-7777-7777-7777-777777777777"
CAT_TAG_ID = "88888888-8888-8888-8888-888888888888"
TRAVEL_TAG_ID = "99999999-9999-9999-9999-999999999999"
SUBJECT_GROUP_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
SCENE_GROUP_ID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"
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
    submitted_preparations = []
    submitted_slimming = []
    submitted_sample_suggestions = []
    submitted_tag_decisions = []
    preparation_reads = 0
    preparation_active = False
    sample_reads = 0
    sample_active = False
    page_errors = []
    console_errors = []
    failed_resources = []
    unexpected_dialogs = []

    def preparation_activity(phase):
        completed = 2 if phase == "completed" else 1
        return {
            "operationID": PREPARATION_ID,
            "mediaKind": "image",
            "phase": phase,
            "completedUnitCount": completed,
            "totalUnitCount": 2,
            "preparedCount": completed,
            "cachedCount": 0,
            "cloudOnlyCount": 0,
            "failedCount": 0,
            "availableActions": ["cancel"] if phase == "running" else [],
        }

    def sample_activity(phase):
        return {
            "operationID": SAMPLE_SUGGESTION_ID,
            "mediaKind": "image",
            "phase": phase,
            "completedUnitCount": 2 if phase == "completed" else 0,
            "totalUnitCount": 2,
            "suggestedCount": 3 if phase == "completed" else 0,
            "skippedCount": 0,
            "availableActions": ["cancel"] if phase == "running" else [],
        }

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
        def accept_unexpected_dialog(dialog):
            unexpected_dialogs.append(dialog.message)
            dialog.accept()

        page.on("dialog", accept_unexpected_dialog)
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
                {"authenticated": True, "authMode": "pairedDevice", "deviceName": "Synthetic"},
            ),
        )
        page.route(
            "**/v1/capabilities",
            lambda route: fulfill_json(
                route,
                {
                    "protocolVersion": 1,
                    "hostID": "55555555-5555-5555-5555-555555555555",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                },
            ),
        )
        page.route(
            "**/v1/sources",
            lambda route: fulfill_json(
                route,
                [{"id": SOURCE_ID, "kind": "photos", "displayName": "Apple Photos", "state": "active"}],
            ),
        )
        page.route(
            "**/v1/tags",
            lambda route: fulfill_json(route, [
                {"id": CAT_TAG_ID, "displayName": "猫", "state": "active", "groupID": SUBJECT_GROUP_ID},
                {"id": TRAVEL_TAG_ID, "displayName": "旅行", "state": "active", "groupID": SCENE_GROUP_ID},
            ]),
        )
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(route, [
                {"id": SUBJECT_GROUP_ID, "displayName": "主体", "sortOrder": 0},
                {"id": SCENE_GROUP_ID, "displayName": "场景", "sortOrder": 1},
            ]),
        )
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
        page.route(
            "**/v1/assets?**",
            lambda route: fulfill_json(
                route,
                {
                    "items": [
                        {
                            "id": asset_id,
                            "fileName": f"IMG_{index + 1:04}.JPG",
                            "sourceID": SOURCE_ID,
                            "sourceDisplayName": "Apple Photos",
                            "availability": "available",
                            "contentRevision": 1,
                            "acceptedTagCount": 0,
                            "rejectedTagCount": 0,
                        }
                        for index, asset_id in enumerate(ASSET_IDS)
                    ],
                    "nextCursor": None,
                },
            ),
        )
        page.route(
            "**/v1/assets/*/thumbnail?**",
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )
        page.route(
            "**/v1/tags/selection",
            lambda route: fulfill_json(route, [
                {"tagID": CAT_TAG_ID, "acceptedCount": 2, "rejectedCount": 0, "unknownCount": 0},
                {"tagID": TRAVEL_TAG_ID, "acceptedCount": 1, "rejectedCount": 0, "unknownCount": 1},
            ]),
        )

        def handle_tag_decision(route):
            payload = route.request.post_data_json
            submitted_tag_decisions.append(payload)
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "appliedAssetCount": len(payload["assetIDs"]),
                    "replayed": False,
                    "undoID": "cccccccc-1111-2222-3333-cccccccccccc",
                },
            )

        page.route("**/v1/tag-decisions/batch", handle_tag_decision)
        page.route(
            "**/v1/review/overview?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "sourceIDs": [],
                    "totalPendingSuggestionCount": 0,
                    "tags": [],
                },
            ),
        )

        def handle_preparation(route):
            nonlocal preparation_reads, preparation_active
            if route.request.method == "POST":
                payload = route.request.post_data_json
                submitted_preparations.append(payload)
                preparation_active = True
                preparation_reads = 0
                fulfill_json(
                    route,
                    {"activity": preparation_activity("running"), "replayed": False},
                    status=202,
                )
                return
            activities = []
            if preparation_active:
                preparation_reads += 1
                phase = "completed" if preparation_reads >= 2 else "running"
                activities = [preparation_activity(phase)]
                if phase == "completed":
                    preparation_active = False
            fulfill_json(
                route,
                {"mediaKind": "image", "isAvailable": True, "activities": activities},
            )

        page.route("**/v1/embedding-preparation?**", handle_preparation)
        page.route("**/v1/embedding-preparation/requests", handle_preparation)

        def handle_sample_suggestions(route):
            nonlocal sample_reads, sample_active
            if route.request.method == "POST":
                submitted_sample_suggestions.append(route.request.post_data_json)
                sample_active = True
                sample_reads = 0
                fulfill_json(
                    route,
                    {"activity": sample_activity("running"), "replayed": False},
                    status=202,
                )
                return
            activities = []
            if sample_active:
                sample_reads += 1
                phase = "completed" if sample_reads >= 2 else "running"
                activities = [sample_activity(phase)]
                if phase == "completed":
                    sample_active = False
            fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "isAvailable": True,
                    "maximumSampleCount": 500,
                    "activities": activities,
                },
            )

        page.route("**/v1/sample-suggestions?**", handle_sample_suggestions)
        page.route("**/v1/sample-suggestions/requests", handle_sample_suggestions)
        page.route(
            "**/v1/tag-library-suggestions?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "maximumPendingCount": 500, "personalCentroidAvailable": False, "personalAdamWAvailable": False, "tags": [], "activities": []}),
        )

        def handle_slimming_launch(route):
            submitted_slimming.append(route.request.post_data_json)
            fulfill_json(
                route,
                {
                    "operationID": "66666666-6666-6666-6666-666666666666",
                    "jobID": SLIMMING_JOB_ID,
                    "acceptedAtMs": 1_700_000_000_000,
                    "memberCount": 2,
                    "replayed": False,
                },
                status=202,
            )

        page.route("**/v1/library-slimming/launch", handle_slimming_launch)
        page.route(
            "**/v1/library-slimming/workspace?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "jobs": [],
                    "selectedJobID": SLIMMING_JOB_ID,
                    "clusters": [],
                    "selectedClusterID": None,
                    "members": [],
                    "pendingAnalysisCount": 2,
                    "analyzedAssetCount": 0,
                    "policyVersion": "librarySlimming.v1",
                },
            ),
        )
        page.route(
            "**/v1/library-slimming/removals?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "requests": []}),
        )
        page.route(
            "**/v1/library-slimming/identical-cleanup/requests?**",
            lambda route: fulfill_json(route, {"mediaKind": "image", "requests": []}),
        )

        page.goto(BASE_URL, wait_until="networkidle")
        page.locator("#selectionModeButton").click()
        cards = page.locator("#assetGrid > .asset-card")
        assert cards.count() == 2
        cards.nth(0).click()
        cards.nth(1).click(modifiers=["Meta"])
        assert "已选择 2 项" in page.locator("#selectionSummary").inner_text()
        page.locator("#selectionInspector:not(.hidden)").wait_for()
        assert page.locator("#selectionInspectorTags .inspector-tag-group").count() == 2
        cat_chip = page.locator(
            f'#selectionInspectorTags [data-tag-chip-action][data-tag-id="{CAT_TAG_ID}"]'
        )
        travel_chip = page.locator(
            f'#selectionInspectorTags [data-tag-chip-action][data-tag-id="{TRAVEL_TAG_ID}"]'
        )
        page.wait_for_function(
            "([catID, travelID]) => "
            "document.querySelector(`#selectionInspectorTags [data-tag-id=\"${catID}\"]`)?.dataset.decision === 'accepted' "
            "&& document.querySelector(`#selectionInspectorTags [data-tag-chip-action][data-tag-id=\"${travelID}\"]`)?.dataset.decision === 'mixed' "
            "&& document.querySelector(`#selectionInspectorTags [data-tag-chip-action][data-tag-id=\"${travelID}\"]`)?.innerText.includes('混合')",
            arg=[CAT_TAG_ID, TRAVEL_TAG_ID],
        )
        assert cat_chip.get_attribute("data-decision") == "accepted"
        assert travel_chip.get_attribute("data-decision") == "mixed"
        assert "混合" in travel_chip.inner_text()
        scene_toggle = page.locator(
            f'#selectionInspectorTags [data-inspector-tag-group-toggle="{SCENE_GROUP_ID}"]'
        )
        scene_toggle.click()
        assert scene_toggle.get_attribute("aria-expanded") == "false"
        assert page.evaluate(
            "(groupID) => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
            ".collapsedInspectorTagGroupIDs.includes(groupID)",
            SCENE_GROUP_ID,
        )
        scene_toggle.click()
        travel_chip.click()
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        assert submitted_tag_decisions[-1]["action"] == "accept"
        assert set(submitted_tag_decisions[-1]["assetIDs"]) == set(ASSET_IDS)
        travel_chip.click(button="right")
        page.wait_for_function(
            "(tagID) => document.activeElement?.dataset.tagId === tagID",
            arg=TRAVEL_TAG_ID,
        )
        assert submitted_tag_decisions[-1]["action"] == "clear"
        assert not unexpected_dialogs, unexpected_dialogs

        page.locator("#prepareSelectedFeaturesButton").click()
        page.locator("#embeddingPreparationStatus:not(.hidden)").wait_for()
        assert submitted_preparations[-1]["mediaKind"] == "image"
        assert set(submitted_preparations[-1]["assetIDs"]) == set(ASSET_IDS)
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('新准备 2')",
            timeout=5_000,
        )
        assert page.locator("#embeddingPreparationStatus").is_hidden()

        page.locator("#generateSelectedSuggestionsButton").click()
        page.locator("#reviewWorkspace:not(.hidden)").wait_for()
        assert submitted_sample_suggestions[-1]["assetIDs"] == ASSET_IDS
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('写入 3 条建议')",
            timeout=5_000,
        )
        page.locator("#generateLibrarySuggestionsButton").click()
        assert submitted_sample_suggestions[-1]["assetIDs"] == []

        page.locator("#closeReviewButton").click()
        page.locator("#findSimilarSelectionButton").click()
        page.locator("#slimmingWorkspace:not(.hidden)").wait_for()
        assert submitted_slimming[-1]["mode"] == "seeds"
        assert submitted_slimming[-1]["sourceIDs"] is None
        assert set(submitted_slimming[-1]["seedAssetIDs"]) == set(ASSET_IDS)

        page.locator("#closeSlimmingButton").click()
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        assert page.locator("#selectionInspectorPrepareFeaturesButton").is_visible()
        assert page.locator("#selectionInspectorGenerateSuggestionsButton").is_visible()
        assert page.locator("#selectionInspectorFindSimilarButton").is_visible()
        page.screenshot(path="/tmp/imageall-selection-tools-synthetic.png", full_page=True)

        assert not page_errors, page_errors
        assert not console_errors, {"console": console_errors, "resources": failed_resources}
        browser.close()

    print(
        "selection tools browser flow passed; "
        f"preparations={len(submitted_preparations)}; "
        f"suggestions={len(submitted_sample_suggestions)}; slimming={len(submitted_slimming)}; "
        f"tag decisions={len(submitted_tag_decisions)}"
    )


if __name__ == "__main__":
    main()
