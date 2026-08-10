#!/usr/bin/env python3
import asyncio
import base64
import json
import re
from urllib.parse import parse_qs, urlparse

from playwright.async_api import async_playwright


BASE_URL = "http://127.0.0.1:8807"
SOURCE_ID = "a0000000-0000-4000-8000-000000000001"
GROUP_ID = "a0000000-0000-4000-8000-000000000002"
CAT_TAG_ID = "a0000000-0000-4000-8000-000000000003"
OUTDOOR_TAG_ID = "a0000000-0000-4000-8000-000000000004"
ASSET_IDS = [f"b0000000-0000-4000-8000-{index:012d}" for index in range(1, 25)]
PNG_BYTES = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)


def asset_summary(asset_id, index):
    return {
        "id": asset_id,
        "sourceID": SOURCE_ID,
        "sourceName": "合成图库",
        "fileName": f"SYNTHETIC_{index:03d}.JPG",
        "mediaType": "public.jpeg",
        "mediaKind": "image",
        "availability": "available",
        "contentRevision": 1,
        "acceptedTagCount": 0,
        "rejectedTagCount": 0,
        "mediaCreatedAtMs": 1_700_000_000_000 + index,
        "width": 1200,
        "height": 900,
    }


async def main():
    local_requests = []
    tag_decisions = []
    standard_assets = set()
    accepted_tags = {}
    page_errors = []
    console_errors = []
    resource_errors = []
    tags = [{
        "id": CAT_TAG_ID,
        "displayName": "猫",
        "state": "active",
        "groupID": GROUP_ID,
    }]

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        context = await browser.new_context(
            viewport={"width": 1440, "height": 960},
            service_workers="block",
        )
        await context.add_init_script(
            """
            class QuietWebSocket extends EventTarget { send() {} close() {} }
            Object.defineProperty(globalThis, "WebSocket", { value: QuietWebSocket });
            """
        )
        page = await context.new_page()
        page.on(
            "console",
            lambda message: console_errors.append(message.text)
            if message.type == "error" else None,
        )
        page.on("pageerror", lambda error: page_errors.append(str(error)))
        page.on(
            "response",
            lambda response: resource_errors.append((response.status, response.url))
            if response.status >= 400 else None,
        )

        async def fulfill_json(route, payload, status=200):
            await route.fulfill(
                status=status,
                content_type="application/json; charset=utf-8",
                body=json.dumps(payload, ensure_ascii=False),
            )

        async def route_session(route):
            await fulfill_json(route, {
                "authenticated": True,
                "authMode": "pairedDevice",
                "deviceName": "合成浏览器",
            })

        async def route_favicon(route):
            await route.fulfill(status=204, body="")

        async def route_world_map(route):
            await route.fulfill(
                status=200,
                content_type="text/html; charset=utf-8",
                body="<!doctype html><title>合成照片世界</title>",
            )

        async def route_api(route):
            parsed = urlparse(route.request.url)
            path = parsed.path
            if path == "/v1/capabilities":
                await fulfill_json(route, {
                    "protocolVersion": 2,
                    "hostAppVersion": "test",
                    "capabilities": ["assetLocalSuggestions"],
                })
                return
            if path == "/v1/sources":
                await fulfill_json(route, [{
                    "id": SOURCE_ID,
                    "kind": "folder",
                    "displayName": "合成图库",
                    "state": "active",
                }])
                return
            if path == "/v1/tags":
                await fulfill_json(route, tags)
                return
            if path == "/v1/tag-groups":
                await fulfill_json(route, [{
                    "id": GROUP_ID,
                    "displayName": "主体与场景",
                    "sortOrder": 0,
                    "isSystem": False,
                }])
                return
            if path == "/v1/jobs":
                await fulfill_json(route, [])
                return
            if path == "/v1/embedding-preparation":
                await fulfill_json(route, {
                    "mediaKind": "image", "isAvailable": False, "activities": [],
                })
                return
            if path == "/v1/sample-suggestions":
                await fulfill_json(route, {
                    "mediaKind": "image",
                    "isAvailable": False,
                    "maximumSampleCount": 500,
                    "activities": [],
                })
                return
            if path == "/v1/tag-library-suggestions":
                await fulfill_json(route, {
                    "mediaKind": "image",
                    "maximumPendingCount": 500,
                    "personalCentroidAvailable": False,
                    "personalAdamWAvailable": False,
                    "tags": [],
                    "activities": [],
                })
                return
            if path == "/v1/assets":
                query = parse_qs(parsed.query)
                assert query.get("mediaKinds") == ["image"]
                await fulfill_json(route, {
                    "items": [asset_summary(asset_id, index) for index, asset_id in enumerate(ASSET_IDS, 1)],
                    "nextCursor": None,
                })
                return

            local_match = re.fullmatch(r"/v1/assets/([0-9a-f-]+)/local-suggestions", path)
            if local_match:
                asset_id = local_match.group(1)
                payload = route.request.post_data_json
                local_requests.append({"assetID": asset_id, **payload})
                track = payload["track"]
                if track == "personal" and asset_id == ASSET_IDS[0]:
                    await asyncio.sleep(0.45)
                if track == "standard":
                    standard_assets.add(asset_id)
                    if not any(tag["id"] == OUTDOOR_TAG_ID for tag in tags):
                        tags.append({
                            "id": OUTDOOR_TAG_ID,
                            "displayName": "户外",
                            "state": "active",
                            "groupID": GROUP_ID,
                        })
                    suggestions = [{
                        "id": "standard|scene.outdoor",
                        "track": "standard",
                        "tagID": None,
                        "displayName": "户外",
                        "recommendation": "suggested",
                    }]
                else:
                    suggestions = [{
                        "id": f"personal|{CAT_TAG_ID}",
                        "track": "personal",
                        "tagID": CAT_TAG_ID,
                        "displayName": "猫",
                        "recommendation": "suggested",
                    }]
                await fulfill_json(route, {
                    "operationID": payload["operationID"],
                    "assetID": asset_id,
                    "track": track,
                    "state": "results",
                    "suggestions": suggestions,
                    "replayed": False,
                })
                return

            detail_match = re.fullmatch(r"/v1/assets/([0-9a-f-]+)", path)
            if detail_match:
                asset_id = detail_match.group(1)
                index = ASSET_IDS.index(asset_id) + 1
                decision = accepted_tags.get(asset_id, "unknown")
                pending = []
                if asset_id in standard_assets:
                    pending.append({
                        "tagID": OUTDOOR_TAG_ID,
                        "displayName": "户外",
                        "suggestionOrigin": "standardModel",
                    })
                await fulfill_json(route, {
                    "assetID": asset_id,
                    "sourceID": SOURCE_ID,
                    "sourceName": "合成图库",
                    "fileName": f"SYNTHETIC_{index:03d}.JPG",
                    "relativePath": None,
                    "mediaType": "public.jpeg",
                    "availability": "available",
                    "contentRevision": 1,
                    "acceptedTagCount": 1 if decision == "accepted" else 0,
                    "rejectedTagCount": 1 if decision == "rejected" else 0,
                    "mediaCreatedAtMs": 1_700_000_000_000 + index,
                    "mediaModifiedAtMs": 1_700_000_100_000 + index,
                    "width": 1200,
                    "height": 900,
                    "fingerprintSizeBytes": 800_000,
                    "tags": [{
                        "tagID": CAT_TAG_ID,
                        "displayName": "猫",
                        "decision": decision,
                    }],
                    "pendingSuggestions": pending,
                })
                return

            image_match = re.fullmatch(r"/v1/assets/([0-9a-f-]+)/(thumbnail|preview)", path)
            if image_match:
                await route.fulfill(status=200, content_type="image/png", body=PNG_BYTES)
                return
            if path == "/v1/tag-decisions/batch":
                payload = route.request.post_data_json
                tag_decisions.append(payload)
                for asset_id in payload["assetIDs"]:
                    accepted_tags[asset_id] = {
                        "accept": "accepted", "reject": "rejected", "clear": "unknown",
                    }[payload["action"]]
                await fulfill_json(route, {
                    "operationID": payload["operationID"],
                    "appliedAssetCount": len(payload["assetIDs"]),
                    "replayed": False,
                    "undoID": "c0000000-0000-4000-8000-000000000001",
                })
                return
            await fulfill_json(route, {"code": "notFound", "message": path}, status=404)

        await page.route("**/favicon.ico", route_favicon)
        await page.route("**/world-map/index.html", route_world_map)
        await page.route("**/web/session", route_session)
        await page.route("**/v1/**", route_api)
        await page.goto(BASE_URL, wait_until="networkidle")

        first_card = page.locator(f'.asset-card[data-asset-id="{ASSET_IDS[0]}"]')
        second_card = page.locator(f'.asset-card[data-asset-id="{ASSET_IDS[1]}"]')
        await first_card.click()
        await page.locator("#assetFileName").wait_for(state="visible")
        assert await page.locator(".asset-card").count() == len(ASSET_IDS)
        await page.locator("#libraryScroll").evaluate("element => { element.scrollTop = 180; }")
        scroll_before = await page.locator("#libraryScroll").evaluate("element => element.scrollTop")

        await page.locator("#inspectorStandardModelButton").click()
        await page.locator("#inspectorLocalModelBody").get_by_text("户外").wait_for()
        assert await page.locator("#inspectorLocalModelBody").get_by_text("建议复核").count() == 1
        assert "score" not in await page.locator("#inspectorLocalModelSection").inner_text()
        assert await page.locator("#inspectorSuggestions").get_by_text("户外").count() == 1
        assert await page.locator("#libraryScroll").evaluate("element => element.scrollTop") == scroll_before

        await page.locator("#inspectorPersonalModelButton").click()
        await second_card.click()
        await page.locator("#assetFileName").get_by_text("SYNTHETIC_002.JPG").wait_for()
        await page.wait_for_timeout(600)
        assert "猫" not in await page.locator("#inspectorLocalModelBody").inner_text()
        assert "对当前照片运行" in await page.locator("#inspectorLocalModelBody").inner_text()

        await page.locator("#inspectorPersonalModelButton").click()
        personal_result = page.locator(".inspector-local-model-result").filter(has_text="猫")
        await personal_result.wait_for()
        await personal_result.locator('[data-action="accept"]').click()
        await page.wait_for_function(
            "() => !document.querySelector('[data-local-suggestion-id]')"
        )
        assert tag_decisions[-1]["assetIDs"] == [ASSET_IDS[1]]
        assert tag_decisions[-1]["tagID"] == CAT_TAG_ID
        assert tag_decisions[-1]["action"] == "accept"
        assert await page.locator(".asset-card").count() == len(ASSET_IDS)
        assert await page.locator("#assetFileName").inner_text() == "SYNTHETIC_002.JPG"

        await page.set_viewport_size({"width": 390, "height": 844})
        source_sidebar_open = await page.locator("#sourceSidebar").evaluate(
            "element => element.classList.contains('open')"
        )
        if source_sidebar_open:
            await page.locator("#sidebarToggle").click()
        inspector_open = await page.locator("#inspector").evaluate(
            "element => element.classList.contains('open')"
        )
        if not inspector_open:
            await page.locator("#toggleInspectorButton").click()
        await page.locator("#inspectorLocalModelSection").wait_for(state="visible")
        await page.locator("#inspectorPersonalModelButton").click()
        await page.locator(".inspector-local-model-result").filter(has_text="猫").wait_for()
        assert await page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        bounds = await page.locator("#inspectorLocalModelSection").bounding_box()
        assert bounds is not None and bounds["x"] >= 0 and bounds["x"] + bounds["width"] <= 390

        await page.screenshot(
            path="/tmp/imageall-asset-local-suggestions-390.png",
            full_page=True,
        )
        assert len(local_requests) == 4
        assert local_requests[0]["track"] == "standard"
        assert local_requests[1]["assetID"] == ASSET_IDS[0]
        assert local_requests[2]["assetID"] == ASSET_IDS[1]
        assert local_requests[3]["assetID"] == ASSET_IDS[1]
        assert page_errors == [], page_errors
        assert resource_errors == [], resource_errors
        assert console_errors == [], console_errors
        await browser.close()

    print("asset local suggestions browser regression passed")


if __name__ == "__main__":
    asyncio.run(main())
