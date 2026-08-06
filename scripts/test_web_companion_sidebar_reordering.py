#!/usr/bin/env python3
import base64
import json
import re
from urllib.parse import parse_qs, urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8808"
SOURCE_PHOTOS = "10000000-0000-4000-8000-000000000001"
SOURCE_FOLDER = "10000000-0000-4000-8000-000000000002"
GROUP_SUBJECT = "20000000-0000-4000-8000-000000000001"
GROUP_SCENE = "20000000-0000-4000-8000-000000000002"
TAG_CAT = "30000000-0000-4000-8000-000000000001"
TAG_DOG = "30000000-0000-4000-8000-000000000002"
TAG_TRAVEL = "30000000-0000-4000-8000-000000000003"
ASSET_ID = "40000000-0000-4000-8000-000000000001"
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
    tags = [
        {"id": TAG_CAT, "displayName": "猫", "state": "active", "groupID": GROUP_SUBJECT},
        {"id": TAG_DOG, "displayName": "狗", "state": "active", "groupID": GROUP_SUBJECT},
        {"id": TAG_TRAVEL, "displayName": "旅行", "state": "active", "groupID": GROUP_SCENE},
    ]
    groups = [
        {
            "id": GROUP_SUBJECT,
            "displayName": "主体",
            "sortOrder": 0,
            "isSystem": False,
        },
        {
            "id": GROUP_SCENE,
            "displayName": "场景",
            "sortOrder": 1,
            "isSystem": True,
        },
    ]
    tag_moves = []
    tag_renames = []
    archived_tag_ids = []
    group_renames = []
    asset_queries = []
    fail_next_move = [False]
    page_errors = []
    console_errors = []

    def source_names(page):
        return page.locator("#sourceList [data-source-id] > span:nth-child(2)").all_inner_texts()

    def sidebar_group_names(page, group_id):
        return page.locator(
            f'#tagNavigation [data-tag-drop-group-id="{group_id}"] [data-quick-tag-id]'
        ).all_inner_texts()

    def inspector_group_names(page, container, group_id):
        return page.locator(
            f'#{container} [data-inspector-tag-group-id="{group_id}"] '
            ".inspector-tag-chip strong"
        ).all_inner_texts()

    def sidebar_group_toggle(page, group_id):
        return page.locator(
            f'#tagNavigation [data-sidebar-tag-group-toggle="{group_id}"]'
        )

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
        page.route("**/favicon.ico", lambda route: route.fulfill(status=204, body=""))
        page.route(
            "**/world-map/index.html",
            lambda route: route.fulfill(
                status=200,
                content_type="text/html; charset=utf-8",
                body="<!doctype html><title>Map test shell</title>",
            ),
        )
        page.route(
            "**/web/session",
            lambda route: fulfill_json(
                route,
                {"authenticated": True, "authMode": "account", "username": "test"},
            ),
        )
        page.route(
            "**/v1/capabilities",
            lambda route: fulfill_json(
                route,
                {
                    "protocolVersion": 1,
                    "hostID": "50000000-0000-4000-8000-000000000001",
                    "hostDisplayName": "Synthetic Mac",
                    "hostAppVersion": "test",
                },
            ),
        )
        page.route(
            "**/v1/sources",
            lambda route: fulfill_json(route, [
                {
                    "id": SOURCE_PHOTOS,
                    "kind": "photos",
                    "displayName": "Apple Photos",
                    "state": "active",
                },
                {
                    "id": SOURCE_FOLDER,
                    "kind": "folder",
                    "displayName": "Downloads",
                    "state": "active",
                },
            ]),
        )
        page.route("**/v1/tags", lambda route: fulfill_json(route, list(tags)))
        page.route(
            "**/v1/tag-groups",
            lambda route: fulfill_json(route, list(groups)),
        )
        page.route("**/v1/jobs", lambda route: fulfill_json(route, []))
        def asset_page(route):
            asset_queries.append(route.request.url)
            fulfill_json(route, {
                "items": [{
                    "id": ASSET_ID,
                    "fileName": "SYNTHETIC.JPG",
                    "sourceID": SOURCE_PHOTOS,
                    "sourceDisplayName": "Apple Photos",
                    "availability": "available",
                    "contentRevision": 1,
                    "acceptedTagCount": 1,
                    "rejectedTagCount": 0,
                }],
                "nextCursor": None,
            })

        page.route("**/v1/assets?**", asset_page)

        def asset_detail(route):
            fulfill_json(route, {
                "assetID": ASSET_ID,
                "sourceID": SOURCE_PHOTOS,
                "sourceName": "Apple Photos",
                "fileName": "SYNTHETIC.JPG",
                "relativePath": None,
                "mediaType": "public.jpeg",
                "availability": "available",
                "contentRevision": 1,
                "acceptedTagCount": 1,
                "rejectedTagCount": 0,
                "width": 1200,
                "height": 900,
                "tags": [
                    {
                        "tagID": tag["id"],
                        "displayName": tag["displayName"],
                        "decision": "accepted" if tag["id"] == TAG_CAT else "unknown",
                    }
                    for tag in tags
                ],
                "pendingSuggestions": [],
            })

        page.route(re.compile(r".*/v1/assets/[0-9a-f-]+$"), asset_detail)
        page.route(
            re.compile(r".*/v1/assets/[0-9a-f-]+/(thumbnail|preview)(\?.*)?$"),
            lambda route: route.fulfill(status=200, content_type="image/png", body=PIXEL),
        )
        page.route(
            "**/v1/tags/selection?**",
            lambda route: fulfill_json(route, [
                {
                    "tagID": tag["id"],
                    "acceptedCount": 1 if tag["id"] == TAG_CAT else 0,
                    "rejectedCount": 0,
                    "unknownCount": 0 if tag["id"] == TAG_CAT else 1,
                }
                for tag in tags
            ]),
        )
        page.route(
            "**/v1/tags/selection",
            lambda route: fulfill_json(route, [
                {
                    "tagID": tag["id"],
                    "acceptedCount": 1 if tag["id"] == TAG_CAT else 0,
                    "rejectedCount": 0,
                    "unknownCount": 0 if tag["id"] == TAG_CAT else 1,
                }
                for tag in tags
            ]),
        )
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
                {
                    "mediaKind": "image",
                    "isAvailable": True,
                    "maximumSampleCount": 500,
                    "activities": [],
                },
            ),
        )
        page.route(
            "**/v1/tag-library-suggestions?**",
            lambda route: fulfill_json(
                route,
                {
                    "mediaKind": "image",
                    "maximumPendingCount": 500,
                    "personalCentroidAvailable": False,
                    "personalAdamWAvailable": False,
                    "tags": [],
                    "activities": [],
                },
            ),
        )

        def move_tag(route):
            tag_id = urlparse(route.request.url).path.split("/")[-2]
            payload = route.request.post_data_json
            tag_moves.append({"tagID": tag_id, **payload})
            if fail_next_move[0]:
                fail_next_move[0] = False
                fulfill_json(
                    route,
                    {"code": "conflict", "message": "synthetic move denied"},
                    status=409,
                )
                return
            for tag in tags:
                if tag["id"] == tag_id:
                    tag["groupID"] = payload["groupID"]
                    moved = dict(tag)
                    break
            fulfill_json(
                route,
                {
                    "operationID": payload["operationID"],
                    "tag": moved,
                    "replayed": False,
                },
            )

        page.route(re.compile(r".*/v1/tags/[0-9a-f-]+/move$"), move_tag)

        def rename_tag(route):
            tag_id = urlparse(route.request.url).path.split("/")[-2]
            payload = route.request.post_data_json
            tag_renames.append({"tagID": tag_id, **payload})
            tag = next(item for item in tags if item["id"] == tag_id)
            tag["displayName"] = payload["name"]
            fulfill_json(route, {"operationID": payload["operationID"], "tag": tag})

        def archive_tag(route):
            tag_id = urlparse(route.request.url).path.split("/")[-2]
            payload = route.request.post_data_json
            archived_tag_ids.append(tag_id)
            tag = next(item for item in tags if item["id"] == tag_id)
            tag["state"] = "archived"
            fulfill_json(route, {"operationID": payload["operationID"], "tag": tag})

        def rename_group(route):
            group_id = urlparse(route.request.url).path.split("/")[-2]
            payload = route.request.post_data_json
            group_renames.append({"groupID": group_id, **payload})
            group = next(item for item in groups if item["id"] == group_id)
            group["displayName"] = payload["name"]
            fulfill_json(route, {"operationID": payload["operationID"], "group": group})

        page.route(re.compile(r".*/v1/tags/[0-9a-f-]+/rename$"), rename_tag)
        page.route(re.compile(r".*/v1/tags/[0-9a-f-]+/archive$"), archive_tag)
        page.route(re.compile(r".*/v1/tag-groups/[0-9a-f-]+/rename$"), rename_group)

        page.goto(BASE_URL, wait_until="networkidle")
        assert source_names(page) == ["Apple Photos", "Downloads"]
        page.locator(f'[data-source-id="{SOURCE_FOLDER}"]').drag_to(
            page.locator(f'[data-source-id="{SOURCE_PHOTOS}"]')
        )
        page.wait_for_function(
            "id => document.querySelector('#sourceList [data-source-id]')?.dataset.sourceId === id",
            arg=SOURCE_FOLDER,
        )
        assert source_names(page) == ["Downloads", "Apple Photos"]
        page.wait_for_function(
            "id => document.activeElement?.dataset.sourceId === id",
            arg=SOURCE_FOLDER,
        )
        assert page.evaluate("() => document.activeElement?.dataset.sourceId") == SOURCE_FOLDER
        assert page.evaluate(
            "() => JSON.parse(localStorage.getItem('imageall.web.workspace-preferences'))"
            ".sourceOrderIDs[0]"
        ) == SOURCE_FOLDER

        page.reload(wait_until="networkidle")
        assert source_names(page) == ["Downloads", "Apple Photos"]
        folder = page.locator(f'[data-source-id="{SOURCE_FOLDER}"]')
        folder.focus()
        folder.press("Alt+ArrowDown")
        assert source_names(page) == ["Apple Photos", "Downloads"]

        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        scene_toggle = sidebar_group_toggle(page, GROUP_SCENE)
        assert subject_toggle.get_attribute("aria-expanded") == "true"
        assert subject_toggle.locator(".tag-navigation-group-count").inner_text() == "2"
        subject_toggle.click()
        assert subject_toggle.get_attribute("aria-expanded") == "false"
        assert not page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').is_visible()
        page.reload(wait_until="networkidle")
        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        assert subject_toggle.get_attribute("aria-expanded") == "false"
        page.locator("#tagNavigationSearch").fill("猫")
        assert subject_toggle.get_attribute("aria-expanded") == "true"
        assert page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').is_visible()
        page.locator("#tagNavigationSearch").fill("")
        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        assert subject_toggle.get_attribute("aria-expanded") == "false"
        subject_toggle.focus()
        subject_toggle.press("ArrowDown")
        assert page.evaluate(
            "() => document.activeElement?.dataset.sidebarTagGroupToggle"
        ) == GROUP_SCENE
        subject_toggle.click()
        assert subject_toggle.get_attribute("aria-expanded") == "true"

        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫", "狗"]
        page.locator(f'[data-quick-tag-id="{TAG_DOG}"]').drag_to(
            page.locator(f'[data-quick-tag-id="{TAG_CAT}"]')
        )
        page.wait_for_function(
            "id => document.querySelector('#tagNavigation [data-quick-tag-id]')?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["狗", "猫"]
        assert not tag_moves

        page.locator("#assetGrid > .asset-card").click()
        page.locator("#inspectorContent:not(.hidden)").wait_for()
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["狗", "猫"]

        page.locator(f'[data-quick-tag-id="{TAG_DOG}"]').drag_to(
            page.locator(f'[data-quick-tag-id="{TAG_TRAVEL}"]')
        )
        page.wait_for_function("() => document.querySelector('#toastMessage').textContent.includes('移动到')")
        assert len(tag_moves) == 1
        assert tag_moves[0]["tagID"] == TAG_DOG
        assert tag_moves[0]["groupID"] == GROUP_SCENE
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫"]
        assert sidebar_group_names(page, GROUP_SCENE) == ["狗", "旅行"]
        assert inspector_group_names(page, "inspectorTags", GROUP_SCENE) == ["狗", "旅行"]
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        assert page.evaluate("() => document.activeElement?.dataset.quickTagId") == TAG_DOG

        dog = page.locator(f'[data-quick-tag-id="{TAG_DOG}"]')
        dog.focus()
        dog.press("Alt+ArrowRight")
        assert sidebar_group_names(page, GROUP_SCENE) == ["旅行", "狗"]
        assert inspector_group_names(page, "inspectorTags", GROUP_SCENE) == ["旅行", "狗"]
        assert len(tag_moves) == 1

        fail_next_move[0] = True
        page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').drag_to(
            page.locator(f'[data-quick-tag-id="{TAG_TRAVEL}"]')
        )
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('synthetic move denied')"
        )
        assert len(tag_moves) == 2
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫"]
        assert sidebar_group_names(page, GROUP_SCENE) == ["旅行", "狗"]
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["猫"]

        page.locator(
            f'#inspectorTags [data-tag-reorder-surface="single"][data-tag-id="{TAG_DOG}"]'
        ).drag_to(page.locator(
            f'#inspectorTags [data-tag-reorder-surface="single"][data-tag-id="{TAG_CAT}"]'
        ))
        page.wait_for_function(
            "id => document.activeElement?.dataset.tagId === id "
            "&& document.activeElement?.dataset.tagReorderSurface === 'single'",
            arg=TAG_DOG,
        )
        assert len(tag_moves) == 3
        assert tag_moves[-1]["tagID"] == TAG_DOG
        assert tag_moves[-1]["groupID"] == GROUP_SUBJECT
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["狗", "猫"]
        assert sidebar_group_names(page, GROUP_SCENE) == ["旅行"]
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["狗", "猫"]

        inspector_dog = page.locator(
            f'#inspectorTags [data-tag-reorder-surface="single"][data-tag-id="{TAG_DOG}"]'
        )
        inspector_dog.focus()
        inspector_dog.press("Alt+ArrowDown")
        assert inspector_group_names(page, "inspectorTags", GROUP_SUBJECT) == ["猫", "狗"]
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫", "狗"]
        assert len(tag_moves) == 3
        page.screenshot(path="/tmp/imageall-sidebar-reordering-wide.png", full_page=True)

        page.locator("#tagNavigationSearch").fill("猫")
        assert page.locator(f'[data-quick-tag-id="{TAG_CAT}"]').get_attribute("draggable") == "false"
        page.locator("#tagNavigationSearch").fill("")

        page.reload(wait_until="networkidle")
        assert source_names(page) == ["Apple Photos", "Downloads"]
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["猫", "狗"]
        assert sidebar_group_names(page, GROUP_SCENE) == ["旅行"]
        page.locator("#selectionModeButton").click()
        page.locator("#assetGrid > .asset-card").click()
        page.locator("#selectionInspector:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => document.querySelector('#selectionInspectorTags .inspector-tag-chip')"
        )
        page.wait_for_function(
            "() => !document.querySelector("
            "'#selectionInspectorTags [data-action=\"accept\"]'"
            ")?.disabled"
        )
        assert inspector_group_names(page, "selectionInspectorTags", GROUP_SUBJECT) == ["猫", "狗"]
        selection_dog = page.locator(
            f'#selectionInspectorTags [data-tag-reorder-surface="selection"]'
            f'[data-tag-id="{TAG_DOG}"]'
        )
        assert selection_dog.get_attribute("draggable") == "true"
        assert not selection_dog.is_disabled()
        selection_cat = page.locator(
            f'#selectionInspectorTags [data-tag-reorder-surface="selection"]'
            f'[data-tag-id="{TAG_CAT}"]'
        )
        assert not selection_cat.is_disabled()
        dog_box = selection_dog.bounding_box()
        cat_box = selection_cat.bounding_box()
        assert dog_box and cat_box
        page.mouse.move(
            dog_box["x"] + dog_box["width"] / 2,
            dog_box["y"] + dog_box["height"] / 2,
        )
        page.mouse.down()
        page.mouse.move(
            dog_box["x"] + dog_box["width"] / 2,
            dog_box["y"] + dog_box["height"] / 2 - 8,
            steps=4,
        )
        page.mouse.move(
            cat_box["x"] + cat_box["width"] / 2,
            cat_box["y"] + cat_box["height"] / 2,
            steps=12,
        )
        page.mouse.up()
        page.wait_for_function(
            "id => document.activeElement?.dataset.tagId === id "
            "&& document.activeElement?.dataset.tagReorderSurface === 'selection'",
            arg=TAG_DOG,
        )
        selection_subject_order = inspector_group_names(
            page, "selectionInspectorTags", GROUP_SUBJECT
        )
        assert selection_subject_order == ["狗", "猫"], selection_subject_order
        assert sidebar_group_names(page, GROUP_SUBJECT) == ["狗", "猫"]
        assert len(tag_moves) == 3

        page.wait_for_timeout(300)
        dog_chip = page.locator(f'[data-quick-tag-id="{TAG_DOG}"]')
        travel_chip = page.locator(f'[data-quick-tag-id="{TAG_TRAVEL}"]')
        dog_chip.click()
        assert dog_chip.get_attribute("data-tag-filter-state") == "included"
        travel_chip.click(modifiers=["Meta"])
        assert travel_chip.get_attribute("data-tag-filter-state") == "included"
        query = parse_qs(urlparse(asset_queries[-1]).query)
        assert set(query["acceptedTagIDs"][0].split(",")) == {TAG_DOG, TAG_TRAVEL}
        assert query["tagMatchMode"] == ["all"]

        dog_chip.click(modifiers=["Meta", "Alt"])
        assert dog_chip.get_attribute("data-tag-filter-state") == "excluded"
        assert dog_chip.get_attribute("aria-label") == "狗，已排除"
        query = parse_qs(urlparse(asset_queries[-1]).query)
        assert query["acceptedTagIDs"] == [TAG_TRAVEL]
        assert query["excludedTagIDs"] == [TAG_DOG]

        dog_chip.click(button="right")
        tag_menu = page.locator("#tagContextMenu:not(.hidden)")
        tag_menu.wait_for()
        assert tag_menu.locator("#tagContextMenuTitle").inner_text() == "标签 · 狗"
        assert tag_menu.locator("[data-tag-context-action]").all_inner_texts() == [
            "仅筛选此标签",
            "取消排除此标签",
            "重命名…",
            "归档标签",
        ]
        page.screenshot(path="/tmp/imageall-tag-context-menu.png", full_page=True)
        tag_menu.locator('[data-tag-context-action="filterOnly"]').click()
        assert dog_chip.get_attribute("data-tag-filter-state") == "included"
        assert travel_chip.get_attribute("data-tag-filter-state") == "none"

        dog_chip.focus()
        dog_chip.press("Shift+F10")
        tag_menu.wait_for()
        page.wait_for_function(
            "() => document.activeElement?.dataset.tagContextAction === 'filterOnly'"
        )
        page.keyboard.press("End")
        assert page.evaluate(
            "() => document.activeElement?.dataset.tagContextAction"
        ) == "archiveTag"
        page.keyboard.press("Escape")
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )

        dog_chip.click(button="right")
        tag_menu.locator('[data-tag-context-action="renameTag"]').click()
        page.locator("#tagManagerDialog[open]").wait_for()
        assert page.locator("#tagManagerTagSelect").input_value() == TAG_DOG
        assert page.evaluate("() => document.activeElement?.id") == "tagManagerTagName"
        page.locator("#tagManagerTagName").fill("狗狗")
        page.locator("#renameManagedTagButton").click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('狗狗')"
        )
        assert len(tag_renames) == 1
        page.locator("#closeTagManagerButton").click()
        page.wait_for_function(
            "id => document.activeElement?.dataset.quickTagId === id",
            arg=TAG_DOG,
        )
        assert page.locator(f'[data-quick-tag-id="{TAG_DOG}"]').inner_text() == "狗狗"

        subject_toggle = sidebar_group_toggle(page, GROUP_SUBJECT)
        subject_toggle.focus()
        subject_toggle.press("Shift+F10")
        tag_menu.wait_for()
        assert tag_menu.locator("#tagContextMenuTitle").inner_text() == "标签分组 · 主体"
        tag_menu.locator('[data-tag-context-action="renameGroup"]').click()
        page.locator("#tagManagerDialog[open]").wait_for()
        assert page.locator("#tagManagerGroupSelect").input_value() == GROUP_SUBJECT
        assert page.evaluate("() => document.activeElement?.id") == "tagManagerGroupName"
        page.locator("#tagManagerGroupName").fill("主体分类")
        page.locator("#renameTagGroupButton").click()
        page.wait_for_function(
            "() => document.querySelector('#toastMessage').textContent.includes('主体分类')"
        )
        assert len(group_renames) == 1
        page.locator("#closeTagManagerButton").click()
        page.wait_for_function(
            "id => document.activeElement?.dataset.sidebarTagGroupToggle === id",
            arg=GROUP_SUBJECT,
        )
        assert subject_toggle.locator("strong").inner_text() == "主体分类"

        subject_toggle.click(button="right")
        tag_menu.locator('[data-tag-context-action="deleteGroup"]').click()
        page.locator("#confirmDialog[open]").wait_for()
        assert "主体分类" in page.locator("#confirmDialogMessage").inner_text()
        page.locator("#cancelConfirmButton").click()
        page.wait_for_function(
            "id => document.activeElement?.dataset.sidebarTagGroupToggle === id",
            arg=GROUP_SUBJECT,
        )

        cat_chip = page.locator(f'[data-quick-tag-id="{TAG_CAT}"]')
        cat_chip.click(button="right")
        tag_menu.locator('[data-tag-context-action="archiveTag"]').click()
        page.locator("#confirmDialog[open]").wait_for()
        page.locator("#confirmActionButton").click()
        page.wait_for_function(
            "id => !document.querySelector(`[data-quick-tag-id=\"${id}\"]`)",
            arg=TAG_CAT,
        )
        assert archived_tag_ids == [TAG_CAT]
        page.wait_for_function(
            "id => document.activeElement?.dataset.sidebarTagGroupToggle === id",
            arg=GROUP_SUBJECT,
        )

        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(100)
        dimensions = page.evaluate(
            "() => ({ viewport: innerWidth, scroll: document.documentElement.scrollWidth })"
        )
        assert dimensions["scroll"] <= dimensions["viewport"], dimensions
        page.screenshot(path="/tmp/imageall-sidebar-reordering-synthetic.png", full_page=True)

        assert not page_errors, page_errors
        unexpected_console_errors = [
            message for message in console_errors
            if "status of 409" not in message
        ]
        assert not unexpected_console_errors, unexpected_console_errors
        assert any("status of 409" in message for message in console_errors)
        browser.close()

    print(
        "sidebar reordering browser flow passed; "
        f"source order persisted; tag moves={len(tag_moves)} (1 rejected); "
        f"renames={len(tag_renames) + len(group_renames)}; archived={len(archived_tag_ids)}"
    )


if __name__ == "__main__":
    main()
