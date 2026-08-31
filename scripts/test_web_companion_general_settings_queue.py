#!/usr/bin/env python3
import json
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8806"


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def main():
    updates = []
    held_updates = []
    hold_model = [False]
    settings = {
        "localModel": {
            "isEnabled": False,
            "state": "disabled",
            "modelName": "DINOv2 Small",
            "runtimeName": "App 内 Core ML（本机）",
            "detail": "模型不会初始化或运行。",
        },
        "idleThumbnailPrewarmEnabled": True,
        "idleThresholdSeconds": 180,
        "toolbarDisplayMode": "iconOnly",
        "maxPendingSuggestionsPerTag": 500,
        "suggestionThresholds": None,
    }

    def apply_patch(payload):
        if "modelEnabled" in payload:
            enabled = payload["modelEnabled"]
            settings["localModel"] = {
                **settings["localModel"],
                "isEnabled": enabled,
                "state": "ready" if enabled else "disabled",
                "detail": "模型已在 App 内完成校验并可供本地推理。"
                if enabled else "模型不会初始化或运行。",
            }
        if "idleThumbnailPrewarmEnabled" in payload:
            settings["idleThumbnailPrewarmEnabled"] = payload[
                "idleThumbnailPrewarmEnabled"
            ]
        if "toolbarDisplayMode" in payload:
            settings["toolbarDisplayMode"] = payload["toolbarDisplayMode"]

    def route_api(route):
        path = urlparse(route.request.url).path
        if path == "/v1/capabilities":
            fulfill_json(route, {
                "protocolVersion": 2,
                "hostID": "11111111-1111-4111-8111-111111111111",
                "hostDisplayName": "Synthetic Mac",
                "hostAppVersion": "test",
                "capabilities": ["generalSettings"],
            })
        elif path == "/v1/settings/general":
            if route.request.method == "GET":
                fulfill_json(route, settings)
                return
            payload = route.request.post_data_json
            updates.append(payload)
            if hold_model[0] and "modelEnabled" in payload:
                hold_model[0] = False
                held_updates.append((route, payload))
                return
            apply_patch(payload)
            fulfill_json(route, {"settings": settings, "replayed": False})
        elif path in {"/v1/sources", "/v1/tags", "/v1/tag-groups", "/v1/jobs"}:
            fulfill_json(route, [])
        elif path == "/v1/assets":
            fulfill_json(route, {"items": [], "nextCursor": None})
        elif path == "/v1/embedding-preparation":
            fulfill_json(route, {"mediaKind": "image", "isAvailable": True, "activities": []})
        elif path == "/v1/sample-suggestions":
            fulfill_json(route, {
                "mediaKind": "image",
                "isAvailable": True,
                "maximumSampleCount": 500,
                "activities": [],
            })
        elif path == "/v1/tag-library-suggestions":
            fulfill_json(route, {
                "mediaKind": "image",
                "maximumPendingCount": 500,
                "personalCentroidAvailable": False,
                "personalAdamWAvailable": False,
                "tags": [],
                "activities": [],
            })
        else:
            fulfill_json(route, {}, status=404)

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(
            headless=True,
            executable_path="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        )
        context = browser.new_context(
            viewport={"width": 1100, "height": 820},
            service_workers="block",
        )
        context.add_init_script(
            """
            class QuietWebSocket extends EventTarget { send() {} close() {} }
            Object.defineProperty(globalThis, "WebSocket", { value: QuietWebSocket });
            """
        )
        page = context.new_page()
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
            lambda route: fulfill_json(route, {
                "authenticated": True,
                "authMode": "pairedDevice",
                "deviceName": "Synthetic Browser",
            }),
        )
        page.route("**/v1/**", route_api)
        page.goto(BASE_URL, wait_until="domcontentloaded")
        page.locator("#appView:not(.hidden)").wait_for()
        page.wait_for_function(
            "() => state.capabilities?.capabilities?.includes('generalSettings')"
            " && state.online === true"
        )
        page.evaluate("() => openGeneralSettings()")
        page.locator("#generalSettingsContent:not(.hidden)").wait_for()

        hold_model[0] = True
        page.locator("#generalSettingsModelToggle").click()
        page.wait_for_function("() => state.generalSettings.submitting === true")
        assert len(held_updates) == 1
        assert page.locator("#generalSettingsModelToggle").get_attribute("aria-checked") == "true"
        assert page.locator("#generalSettingsModelState").inner_text() == "正在校验"

        page.locator("#generalSettingsPrewarmToggle").click()
        assert page.locator("#generalSettingsPrewarmToggle").get_attribute("aria-checked") == "false"
        assert "2 项" in page.locator("#generalSettingsSaveStatus").inner_text()
        assert len(updates) == 1
        page.screenshot(
            path="/tmp/imageall-general-settings-queued-save-pending.png",
            full_page=True,
        )

        held_route, held_payload = held_updates.pop()
        apply_patch(held_payload)
        fulfill_json(held_route, {"settings": settings, "replayed": False})
        page.wait_for_function("() => state.generalSettings.submitting === false")
        assert updates[0]["modelEnabled"] is True
        assert updates[1]["idleThumbnailPrewarmEnabled"] is False
        assert updates[0]["operationID"] != updates[1]["operationID"]
        assert page.locator("#generalSettingsModelState").inner_text() == "模型已就绪"
        assert page.locator("#generalSettingsSaveStatus").inner_text() == ""

        hold_model[0] = True
        page.locator("#generalSettingsModelToggle").click()
        page.locator("#generalSettingsPrewarmToggle").click()
        page.wait_for_function("() => state.generalSettings.updateQueue.length === 1")
        failed_route, _ = held_updates.pop()
        fulfill_json(failed_route, {"error": "synthetic model rejection"}, status=409)
        page.wait_for_function("() => state.generalSettings.submitting === false")
        assert page.locator("#generalSettingsModelToggle").get_attribute("aria-checked") == "true"
        assert page.locator("#generalSettingsPrewarmToggle").get_attribute("aria-checked") == "true"
        assert updates[-1]["idleThumbnailPrewarmEnabled"] is True
        assert page.locator("#generalSettingsError").is_visible()
        page.screenshot(path="/tmp/imageall-general-settings-queued-save.png", full_page=True)

        page.set_viewport_size({"width": 1600, "height": 820})
        page.wait_for_function(
            "() => !document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        page.locator(
            '#toolbarDisplayModeControl [data-toolbar-display-mode="iconAndTitle"]'
        ).click()
        page.wait_for_function(
            "() => document.querySelector('#appView').dataset.toolbarDisplayMode === 'iconAndTitle'"
        )
        page.locator("#generalSettingsCloseButton").click()
        page.locator("#generalSettingsDialog").wait_for(state="hidden")
        normal_required = page.evaluate("() => fullToolbarRequiredWidth()")
        page.locator("#storageButton").focus()
        near_miss_width = max(721, normal_required - 20)
        page.set_viewport_size({"width": near_miss_width, "height": 820})
        page.wait_for_function(
            "() => document.querySelector('#appView').classList.contains('toolbar-condensed')"
        )
        assert not page.locator("#appView").evaluate(
            "node => node.classList.contains('compact-toolbar-active')"
        ), page.evaluate(
            "() => ({ ...document.querySelector('#appView').dataset, width: innerWidth })"
        )
        condensed_toolbar_metrics = page.evaluate(
            """() => ({
              normalRequired: Number(document.querySelector('#appView')
                .dataset.toolbarNormalRequiredWidth),
              condensedRequired: Number(document.querySelector('#appView')
                .dataset.toolbarRequiredWidth),
              available: Number(document.querySelector('#appView')
                .dataset.toolbarAvailableWidth),
              scroll: document.documentElement.scrollWidth,
              viewport: innerWidth,
            })"""
        )
        assert condensed_toolbar_metrics["normalRequired"] \
            > condensed_toolbar_metrics["available"], condensed_toolbar_metrics
        assert condensed_toolbar_metrics["condensedRequired"] \
            <= condensed_toolbar_metrics["available"], condensed_toolbar_metrics
        assert condensed_toolbar_metrics["scroll"] \
            <= condensed_toolbar_metrics["viewport"], condensed_toolbar_metrics
        for selector in [
            "#toolbarConnectFolderButton",
            "#toolbarExportPortableDataButton",
            "#storageButton",
            "#jobsButton",
        ]:
            assert page.locator(selector).is_visible(), selector
        assert not page.locator("#compactToolbarMenuButton").is_visible()
        assert page.evaluate("document.activeElement?.id") == "storageButton", page.evaluate(
            "() => ({ active: document.activeElement?.id, "
            "classes: document.querySelector('#appView').className, "
            "dataset: { ...document.querySelector('#appView').dataset } })"
        )
        page.set_viewport_size({"width": 1440, "height": 820})
        page.wait_for_function(
            "() => document.querySelector('#appView').classList.contains('toolbar-condensed')"
        )
        assert not page.locator("#appView").evaluate(
            "node => node.classList.contains('compact-toolbar-active')"
        ), page.evaluate(
            "() => ({ ...document.querySelector('#appView').dataset, width: innerWidth })"
        )
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        assert page.locator("#toolbarConnectFolderButton").is_visible()
        assert page.locator("#toolbarExportPortableDataButton").is_visible()
        assert page.locator("#storageButton").is_visible()
        assert page.locator("#jobsButton").is_visible()
        page.evaluate(
            "() => new Promise(resolve => requestAnimationFrame(() => "
            "requestAnimationFrame(() => requestAnimationFrame(resolve))))"
        )
        assert page.locator("#appView").get_attribute("data-toolbar-layout") == "condensed", (
            page.evaluate(
                "() => ({ classes: document.querySelector('#appView').className, "
                "dataset: { ...document.querySelector('#appView').dataset }, width: innerWidth, "
                "titlebar: { gap: getComputedStyle(document.querySelector('.titlebar')).gap, "
                "padding: getComputedStyle(document.querySelector('.titlebar')).paddingInline }, "
                "actionsGap: getComputedStyle(document.querySelector('.titlebar-actions')).gap, "
                "buttonPadding: getComputedStyle(document.querySelector('#storageButton')).paddingInline })"
            )
        )
        assert not page.locator("#appView").evaluate(
            "node => node.classList.contains('compact-toolbar-active')"
        )
        page.screenshot(
            path="/tmp/imageall-adaptive-toolbar-condensed.png",
            full_page=True,
        )
        page.set_viewport_size({"width": 820, "height": 820})
        page.wait_for_function(
            "() => document.querySelector('#appView').classList.contains('compact-toolbar-active')"
        )
        assert page.locator("#appView").get_attribute("data-toolbar-layout") == "compact"
        assert page.locator("#compactToolbarMenuButton").is_visible()
        assert not page.locator("#storageButton").is_visible()
        assert page.evaluate("document.documentElement.scrollWidth <= innerWidth")
        context.close()
        browser.close()

    print("Web Companion general settings queue checks passed")


if __name__ == "__main__":
    main()
