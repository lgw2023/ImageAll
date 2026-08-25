#!/usr/bin/env python3
import json
from urllib.parse import urlparse

from playwright.sync_api import sync_playwright


BASE_URL = "http://127.0.0.1:8811"
PHOTOS_SOURCE_ID = "aaaaaaaa-1111-2222-3333-aaaaaaaaaaaa"
FOLDER_SOURCE_ID = "bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"


def fulfill_json(route, payload, status=200):
    route.fulfill(
        status=status,
        content_type="application/json; charset=utf-8",
        body=json.dumps(payload, ensure_ascii=False),
    )


def main():
    page_errors = []
    console_errors = []
    unexpected_requests = []
    source_management_reads = 0
    sources = [
        {
            "id": PHOTOS_SOURCE_ID,
            "kind": "photos",
            "displayName": "Synthetic Photos",
            "state": "active",
        },
        {
            "id": FOLDER_SOURCE_ID,
            "kind": "folder",
            "displayName": "Synthetic Archive",
            "state": "active",
        },
    ]
    source_requests = []

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
                body="<!doctype html><title>Map fixture</title>",
            ),
        )
        page.route(
            "**/web/session",
            lambda route: fulfill_json(
                route,
                {"authenticated": True, "authMode": "account", "username": "fixture"},
            ),
        )

        def route_v1(route):
            nonlocal source_management_reads
            path = urlparse(route.request.url).path
            if path == "/v1/capabilities":
                fulfill_json(
                    route,
                    {
                        "protocolVersion": 2,
                        "hostID": "cccccccc-1111-2222-3333-cccccccccccc",
                        "hostDisplayName": "Synthetic Mac",
                        "hostAppVersion": "test",
                        "capabilities": ["sourceManagement"],
                    },
                )
            elif path == "/v1/sources":
                fulfill_json(route, sources)
            elif path in {"/v1/tags", "/v1/tag-groups", "/v1/jobs"}:
                fulfill_json(route, [])
            elif path == "/v1/assets":
                fulfill_json(route, {"items": [], "nextCursor": None})
            elif path == "/v1/embedding-preparation":
                fulfill_json(
                    route,
                    {"mediaKind": "image", "isAvailable": True, "activities": []},
                )
            elif path == "/v1/sample-suggestions":
                fulfill_json(
                    route,
                    {
                        "mediaKind": "image",
                        "isAvailable": True,
                        "maximumSampleCount": 500,
                        "activities": [],
                    },
                )
            elif path == "/v1/tag-library-suggestions":
                fulfill_json(
                    route,
                    {
                        "mediaKind": "image",
                        "maximumPendingCount": 500,
                        "personalCentroidAvailable": False,
                        "personalAdamWAvailable": False,
                        "tags": [],
                        "activities": [],
                    },
                )
            elif path == "/v1/training/activities":
                fulfill_json(route, [])
            elif path == "/v1/source-management":
                source_management_reads += 1
                fulfill_json(
                    route,
                    {
                        "sources": sources,
                        "canConnectPhotos": False,
                        "requests": source_requests,
                    },
                )
            else:
                unexpected_requests.append((route.request.method, path))
                fulfill_json(route, {"error": "unexpected synthetic route"}, status=404)

        page.route("**/v1/**", route_v1)
        page.goto(BASE_URL, wait_until="networkidle")
        page.locator("#sourceManagerButton").click()
        page.locator("#sourceManagerDialog[open]").wait_for()
        page.locator("#sourceManagerList .source-manager-row").first.wait_for()
        assert source_management_reads >= 1
        assert page.locator("#sourceManagerList .source-manager-row").count() == 2

        page.evaluate(
            f"""() => {{
              const originalFetch = window.fetch.bind(window);
              window.__sourceManagerRefreshRelease = null;
              window.fetch = (input, init) => {{
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/source-management") return originalFetch(input, init);
                return new Promise((resolve, reject) => {{
                  window.__sourceManagerRefreshRelease = () => {{
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  }};
                }});
              }};
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const row = workspace.querySelector(
                '[data-source-manager-select="{PHOTOS_SOURCE_ID}"]'
              );
              detail.style.paddingBottom = "640px";
              detail.scrollTop = 72;
              row.focus({{ preventScroll: true }});
              window.__sourceManagerStableFrame = {{
                navigation,
                rows: [...navigation.querySelectorAll(".source-manager-row")],
                detail,
                view: detail.querySelector('[data-source-manager-view="{PHOTOS_SOURCE_ID}"]'),
                action: detail.querySelector('[data-source-action="syncPhotos"]'),
                focused: row,
                navigationScrollTop: navigation.scrollTop,
                detailScrollTop: detail.scrollTop,
              }};
              document.querySelector("#sourceManagerRefreshButton").click();
            }}"""
        )
        page.wait_for_function("() => Boolean(window.__sourceManagerRefreshRelease)")
        pending_frame = page.evaluate(
            """() => {
              const frame = window.__sourceManagerStableFrame;
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              return {
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                detail: detail === frame.detail,
                view: detail.querySelector("[data-source-manager-view]") === frame.view,
                action: detail.querySelector('[data-source-action="syncPhotos"]') === frame.action,
                selected: detail.dataset.sourceManagerDetail
                  === frame.focused.dataset.sourceManagerSelect,
                focus: document.activeElement === frame.focused,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
              };
            }"""
        )
        assert all(pending_frame.values()), pending_frame
        page.evaluate("() => window.__sourceManagerRefreshRelease()")
        page.wait_for_function("() => !state.sourceManagement.loading")
        unchanged_frame = page.evaluate(
            """() => {
              const frame = window.__sourceManagerStableFrame;
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              return {
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                detail: detail === frame.detail,
                view: detail.querySelector("[data-source-manager-view]") === frame.view,
                action: detail.querySelector('[data-source-action="syncPhotos"]') === frame.action,
                selected: detail.dataset.sourceManagerDetail
                  === frame.focused.dataset.sourceManagerSelect,
                focus: document.activeElement === frame.focused,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
              };
            }"""
        )
        assert all(unchanged_frame.values()), unchanged_frame

        page.evaluate(
            f"""() => {{
              const originalFetch = window.fetch.bind(window);
              window.__sourceManagerChangedRelease = null;
              window.fetch = (input, init) => {{
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/source-management") return originalFetch(input, init);
                return new Promise((resolve, reject) => {{
                  window.__sourceManagerChangedRelease = () => {{
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  }};
                }});
              }};
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              const action = detail.querySelector('[data-source-action="syncPhotos"]');
              const stableMutations = [];
              const stableObserver = new MutationObserver(records => stableMutations.push(...records));
              stableObserver.observe(rows[0], {{
                attributes: true,
                characterData: true,
                childList: true,
                subtree: true,
              }});
              stableObserver.observe(detail, {{
                attributes: true,
                characterData: true,
                childList: true,
                subtree: true,
              }});
              action.focus({{ preventScroll: true }});
              window.__sourceManagerChangedFrame = {{
                navigation,
                rows,
                detail,
                view: detail.querySelector('[data-source-manager-view="{PHOTOS_SOURCE_ID}"]'),
                action,
                focused: action,
                navigationScrollTop: navigation.scrollTop,
                detailScrollTop: detail.scrollTop,
                stableObserver,
                stableMutations,
              }};
              void loadSourceManagement({{ quiet: true }});
            }}"""
        )
        page.wait_for_function("() => Boolean(window.__sourceManagerChangedRelease)")
        sources[1]["state"] = "authorizationRequired"
        page.evaluate("() => window.__sourceManagerChangedRelease()")
        page.wait_for_function(
            f"() => state.sourceManagement.snapshot.sources"
            f".find(source => source.id === '{FOLDER_SOURCE_ID}')?.state"
            " === 'authorizationRequired'"
        )
        changed_frame = page.evaluate(
            f"""() => {{
              const frame = window.__sourceManagerChangedFrame;
              frame.stableMutations.push(...frame.stableObserver.takeRecords());
              frame.stableObserver.disconnect();
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              const changedBadge = workspace.querySelector(
                '[data-source-manager-select="{FOLDER_SOURCE_ID}"] .source-manager-state-badge'
              );
              return {{
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                detail: detail === frame.detail,
                view: detail.querySelector("[data-source-manager-view]") === frame.view,
                action: detail.querySelector('[data-source-action="syncPhotos"]') === frame.action,
                changedState: changedBadge?.dataset.state === "authorizationRequired"
                  && changedBadge.textContent === "需授权",
                focus: document.activeElement === frame.focused,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
                stableUntouched: frame.stableMutations.length === 0,
              }};
            }}"""
        )
        assert all(changed_frame.values()), changed_frame

        source_requests[:] = [{
            "id": "dddddddd-1111-2222-3333-dddddddddddd",
            "operationID": "eeeeeeee-1111-2222-3333-eeeeeeeeeeee",
            "action": "prewarmThumbnails",
            "sourceID": PHOTOS_SOURCE_ID,
            "sourceDisplayName": "Synthetic Photos",
            "phase": "running",
            "message": "正在准备缩略图 1 / 10",
            "updatedAtMs": 1_700_000_000_001,
            "completedCount": 1,
            "totalCount": 10,
            "warmedCount": 1,
            "failedCount": 0,
            "reusedCount": 0,
            "ineligibleCount": 0,
            "completedSourceCount": 0,
            "totalSourceCount": 1,
        }]
        page.evaluate(
            """() => {
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const prewarm = detail.querySelector(
                '[data-source-action="prewarmThumbnails"]'
              );
              detail.style.paddingBottom = "640px";
              detail.scrollTop = 66;
              prewarm.focus({ preventScroll: true });
              window.__sourceManagerRequestStartedFrame = {
                navigation,
                rows: [...navigation.querySelectorAll(".source-manager-row")],
                detail,
                header: detail.querySelector(".source-manager-detail-header"),
                status: detail.querySelector(".source-manager-detail-status"),
                update: detail.querySelector(".source-manager-action-group-update"),
                recovery: detail.querySelector(".source-manager-action-group-recovery"),
                remove: detail.querySelector(".source-manager-action-group-remove"),
                syncAction: detail.querySelector('[data-source-action="syncPhotos"]'),
                deleteAction: detail.querySelector('[data-source-action="delete"]'),
                navigationScrollTop: navigation.scrollTop,
                detailScrollTop: detail.scrollTop,
              };
              void loadSourceManagement({ quiet: true });
            }"""
        )
        page.wait_for_function(
            "() => state.sourceManagement.snapshot.requests[0]?.completedCount === 1"
        )
        page.wait_for_function(
            "() => Boolean(document.querySelector('#sourceManagerPending [data-source-pending-action]'))"
        )
        request_started_frame = page.evaluate(
            """() => {
              const frame = window.__sourceManagerRequestStartedFrame;
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              const cancel = detail.querySelector('[data-source-action="cancelPrewarm"]');
              return {
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                detail: detail === frame.detail,
                header: detail.querySelector(".source-manager-detail-header") === frame.header,
                status: detail.querySelector(".source-manager-detail-status") === frame.status,
                update: detail.querySelector(".source-manager-action-group-update")
                  === frame.update,
                recovery: detail.querySelector(".source-manager-action-group-recovery")
                  === frame.recovery,
                remove: detail.querySelector(".source-manager-action-group-remove")
                  === frame.remove,
                syncAction: detail.querySelector('[data-source-action="syncPhotos"]')
                  === frame.syncAction && frame.syncAction.disabled,
                deleteAction: detail.querySelector('[data-source-action="delete"]')
                  === frame.deleteAction,
                oldActionRemoved: !detail.querySelector(
                  '[data-source-action="prewarmThumbnails"]'
                ),
                cancelAction: Boolean(cancel),
                focusMigrated: document.activeElement === cancel,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
              };
            }"""
        )
        assert all(request_started_frame.values()), request_started_frame

        page.evaluate(
            """() => {
              clearTimeout(state.sourceManagement.pollTimer);
              state.sourceManagement.pollTimer = null;
              const originalFetch = window.fetch.bind(window);
              window.__sourceManagerProgressRelease = null;
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/source-management") return originalFetch(input, init);
                return new Promise((resolve, reject) => {
                  window.__sourceManagerProgressRelease = () => {
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  };
                });
              };
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const pending = document.querySelector("#sourceManagerPending");
              const cancel = pending.querySelector("[data-source-pending-action]");
              detail.style.paddingBottom = "640px";
              detail.scrollTop = 68;
              cancel.focus({ preventScroll: true });
              window.__sourceManagerProgressFrame = {
                navigation,
                rows: [...navigation.querySelectorAll(".source-manager-row")],
                detail,
                pending,
                message: pending.querySelector("span"),
                progress: pending.querySelector("progress"),
                counts: pending.querySelector("small"),
                cancel,
                focused: cancel,
                navigationScrollTop: navigation.scrollTop,
                detailScrollTop: detail.scrollTop,
              };
              void loadSourceManagement({ quiet: true, notifyTerminal: true });
            }"""
        )
        page.wait_for_function("() => Boolean(window.__sourceManagerProgressRelease)")
        pending_progress_frame = page.evaluate(
            """() => {
              const frame = window.__sourceManagerProgressFrame;
              const pending = document.querySelector("#sourceManagerPending");
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              return {
                pending: pending === frame.pending,
                message: pending.querySelector("span") === frame.message,
                progress: pending.querySelector("progress") === frame.progress,
                counts: pending.querySelector("small") === frame.counts,
                cancel: pending.querySelector("[data-source-pending-action]") === frame.cancel,
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                detail: detail === frame.detail,
                focus: document.activeElement === frame.focused,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
              };
            }"""
        )
        assert all(pending_progress_frame.values()), pending_progress_frame

        source_requests[0].update({
            "message": "正在准备缩略图 2 / 10",
            "updatedAtMs": 1_700_000_000_002,
            "completedCount": 2,
            "warmedCount": 2,
        })
        page.evaluate("() => window.__sourceManagerProgressRelease()")
        page.wait_for_function(
            "() => state.sourceManagement.snapshot.requests[0]?.completedCount === 2"
        )
        changed_progress_frame = page.evaluate(
            """() => {
              const frame = window.__sourceManagerProgressFrame;
              const pending = document.querySelector("#sourceManagerPending");
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              return {
                pending: pending === frame.pending,
                message: pending.querySelector("span") === frame.message
                  && frame.message.textContent.includes("2 / 10"),
                progress: pending.querySelector("progress") === frame.progress
                  && frame.progress.value === 2,
                counts: pending.querySelector("small") === frame.counts
                  && frame.counts.textContent.includes("生成 2"),
                cancel: pending.querySelector("[data-source-pending-action]") === frame.cancel,
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                detail: detail === frame.detail,
                focus: document.activeElement === frame.focused,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
              };
            }"""
        )
        assert all(changed_progress_frame.values()), changed_progress_frame

        page.evaluate(
            """() => {
              clearTimeout(state.sourceManagement.pollTimer);
              state.sourceManagement.pollTimer = null;
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const cancel = detail.querySelector('[data-source-action="cancelPrewarm"]');
              cancel.focus({ preventScroll: true });
              window.__sourceManagerRequestEndedFrame = {
                navigation,
                rows: [...navigation.querySelectorAll(".source-manager-row")],
                detail,
                header: detail.querySelector(".source-manager-detail-header"),
                status: detail.querySelector(".source-manager-detail-status"),
                update: detail.querySelector(".source-manager-action-group-update"),
                recovery: detail.querySelector(".source-manager-action-group-recovery"),
                remove: detail.querySelector(".source-manager-action-group-remove"),
                syncAction: detail.querySelector('[data-source-action="syncPhotos"]'),
                deleteAction: detail.querySelector('[data-source-action="delete"]'),
                navigationScrollTop: navigation.scrollTop,
                detailScrollTop: detail.scrollTop,
              };
              void loadSourceManagement({ quiet: true });
            }"""
        )
        source_requests.clear()
        page.wait_for_function(
            "() => state.sourceManagement.snapshot.requests.length === 0"
        )
        request_ended_frame = page.evaluate(
            """() => {
              const frame = window.__sourceManagerRequestEndedFrame;
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              const syncAction = detail.querySelector('[data-source-action="syncPhotos"]');
              return {
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                detail: detail === frame.detail,
                header: detail.querySelector(".source-manager-detail-header") === frame.header,
                status: detail.querySelector(".source-manager-detail-status") === frame.status,
                update: detail.querySelector(".source-manager-action-group-update")
                  === frame.update,
                recovery: detail.querySelector(".source-manager-action-group-recovery")
                  === frame.recovery,
                remove: detail.querySelector(".source-manager-action-group-remove")
                  === frame.remove,
                syncAction: syncAction === frame.syncAction && !syncAction.disabled,
                deleteAction: detail.querySelector('[data-source-action="delete"]')
                  === frame.deleteAction,
                oldActionRemoved: !detail.querySelector(
                  '[data-source-action="cancelPrewarm"]'
                ),
                restoredAction: Boolean(detail.querySelector(
                  '[data-source-action="prewarmThumbnails"]'
                )),
                focusMigrated: document.activeElement === syncAction,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
              };
            }"""
        )
        assert all(request_ended_frame.values()), request_ended_frame
        page.evaluate(
            f"""() => {{
              const originalFetch = window.fetch.bind(window);
              window.fetch = (input, init) => {{
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/source-management") return originalFetch(input, init);
                window.fetch = originalFetch;
                return Promise.resolve(new Response(
                  JSON.stringify({{ message: "模拟来源管理刷新失败" }}),
                  {{
                    status: 409,
                    headers: {{ "content-type": "application/json; charset=utf-8" }},
                  }}
                ));
              }};
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              const focused = navigation.querySelector(
                '[data-source-manager-select="{PHOTOS_SOURCE_ID}"]'
              );
              detail.style.paddingBottom = "640px";
              detail.scrollTop = 64;
              focused.focus({{ preventScroll: true }});
              window.__sourceManagerFailureFrame = {{
                navigation,
                rows,
                detail,
                view: detail.querySelector('[data-source-manager-view="{PHOTOS_SOURCE_ID}"]'),
                action: detail.querySelector('[data-source-action="syncPhotos"]'),
                focused,
                navigationScrollTop: navigation.scrollTop,
                detailScrollTop: detail.scrollTop,
              }};
              document.querySelector("#sourceManagerRefreshButton").click();
            }}"""
        )
        page.wait_for_function(
            "() => !state.sourceManagement.loading"
            " && document.querySelector('#toastMessage').textContent"
            " === '模拟来源管理刷新失败'"
        )
        failure_frame = page.evaluate(
            """() => {
              const frame = window.__sourceManagerFailureFrame;
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              return {
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                detail: detail === frame.detail,
                view: detail.querySelector("[data-source-manager-view]") === frame.view,
                action: detail.querySelector('[data-source-action="syncPhotos"]') === frame.action,
                focus: document.activeElement === frame.focused,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
                notice: document.querySelector("#toastMessage").textContent
                  === "模拟来源管理刷新失败",
              };
            }"""
        )
        assert all(failure_frame.values()), failure_frame

        page.evaluate(
            f"""() => {{
              const originalFetch = window.fetch.bind(window);
              window.__sourceManagerSelectedStateRelease = null;
              window.fetch = (input, init) => {{
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/source-management") return originalFetch(input, init);
                return new Promise((resolve, reject) => {{
                  window.__sourceManagerSelectedStateRelease = () => {{
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  }};
                }});
              }};
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              const syncAction = detail.querySelector('[data-source-action="syncPhotos"]');
              detail.style.paddingBottom = "640px";
              detail.scrollTop = 60;
              syncAction.focus({{ preventScroll: true }});
              window.__sourceManagerSelectedStateFrame = {{
                navigation,
                rows,
                detail,
                header: detail.querySelector(".source-manager-detail-header"),
                view: detail.querySelector('[data-source-manager-view="{PHOTOS_SOURCE_ID}"]'),
                status: detail.querySelector(".source-manager-detail-status"),
                recovery: detail.querySelector(".source-manager-action-group-recovery"),
                remove: detail.querySelector(".source-manager-action-group-remove"),
                deleteAction: detail.querySelector('[data-source-action="delete"]'),
                focused: syncAction,
                navigationScrollTop: navigation.scrollTop,
                detailScrollTop: detail.scrollTop,
              }};
              void loadSourceManagement({{ quiet: true }});
            }}"""
        )
        page.wait_for_function(
            "() => Boolean(window.__sourceManagerSelectedStateRelease)"
        )
        sources[0]["state"] = "authorizationRequired"
        page.evaluate("() => window.__sourceManagerSelectedStateRelease()")
        page.wait_for_function(
            f"() => state.sourceManagement.snapshot.sources"
            f".find(source => source.id === '{PHOTOS_SOURCE_ID}')?.state"
            " === 'authorizationRequired'"
            " && Boolean(document.querySelector('[data-source-action=\"reauthorize\"]'))"
        )
        selected_state_frame = page.evaluate(
            f"""() => {{
              const frame = window.__sourceManagerSelectedStateFrame;
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              const reauthorize = detail.querySelector('[data-source-action="reauthorize"]');
              const badge = navigation.querySelector(
                '[data-source-manager-select="{PHOTOS_SOURCE_ID}"] .source-manager-state-badge'
              );
              return {{
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                selectedState: badge?.dataset.state === "authorizationRequired"
                  && badge.textContent === "需授权",
                detail: detail === frame.detail,
                header: detail.querySelector(".source-manager-detail-header") === frame.header,
                view: detail.querySelector("[data-source-manager-view]") === frame.view,
                status: detail.querySelector(".source-manager-detail-status") === frame.status
                  && frame.status.dataset.state === "authorizationRequired"
                  && frame.status.textContent.includes("重新授予"),
                recovery: detail.querySelector(".source-manager-action-group-recovery")
                  === frame.recovery,
                remove: detail.querySelector(".source-manager-action-group-remove")
                  === frame.remove,
                deleteAction: detail.querySelector('[data-source-action="delete"]')
                  === frame.deleteAction,
                oldActionRemoved: !detail.querySelector('[data-source-action="syncPhotos"]'),
                newAction: Boolean(reauthorize),
                focusMigrated: document.activeElement === reauthorize,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
              }};
            }}"""
        )
        assert all(selected_state_frame.values()), selected_state_frame

        page.evaluate(
            """() => {
              const originalFetch = window.fetch.bind(window);
              window.__sourceManagerRestoredStateRelease = null;
              window.fetch = (input, init) => {
                const url = new URL(typeof input === "string" ? input : input.url, location.href);
                if (url.pathname !== "/v1/source-management") return originalFetch(input, init);
                return new Promise((resolve, reject) => {
                  window.__sourceManagerRestoredStateRelease = () => {
                    window.fetch = originalFetch;
                    originalFetch(input, init).then(resolve, reject);
                  };
                });
              };
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const reauthorize = detail.querySelector('[data-source-action="reauthorize"]');
              detail.scrollTop = 56;
              reauthorize.focus({ preventScroll: true });
              window.__sourceManagerRestoredStateFrame = {
                navigation,
                rows: [...navigation.querySelectorAll(".source-manager-row")],
                detail,
                header: detail.querySelector(".source-manager-detail-header"),
                view: detail.querySelector("[data-source-manager-view]"),
                status: detail.querySelector(".source-manager-detail-status"),
                recovery: detail.querySelector(".source-manager-action-group-recovery"),
                remove: detail.querySelector(".source-manager-action-group-remove"),
                deleteAction: detail.querySelector('[data-source-action="delete"]'),
                navigationScrollTop: navigation.scrollTop,
                detailScrollTop: detail.scrollTop,
              };
              void loadSourceManagement({ quiet: true });
            }"""
        )
        page.wait_for_function(
            "() => Boolean(window.__sourceManagerRestoredStateRelease)"
        )
        sources[0]["state"] = "active"
        page.evaluate("() => window.__sourceManagerRestoredStateRelease()")
        page.wait_for_function(
            f"() => state.sourceManagement.snapshot.sources"
            f".find(source => source.id === '{PHOTOS_SOURCE_ID}')?.state === 'active'"
            " && Boolean(document.querySelector('[data-source-action=\"syncPhotos\"]'))"
        )
        restored_state_frame = page.evaluate(
            f"""() => {{
              const frame = window.__sourceManagerRestoredStateFrame;
              const workspace = document.querySelector("#sourceManagerList");
              const navigation = workspace.querySelector(".source-manager-source-list");
              const detail = workspace.querySelector(".source-manager-detail");
              const rows = [...navigation.querySelectorAll(".source-manager-row")];
              const syncAction = detail.querySelector('[data-source-action="syncPhotos"]');
              const badge = navigation.querySelector(
                '[data-source-manager-select="{PHOTOS_SOURCE_ID}"] .source-manager-state-badge'
              );
              return {{
                navigation: navigation === frame.navigation,
                rows: rows.length === frame.rows.length
                  && rows.every((row, index) => row === frame.rows[index]),
                selectedState: badge?.dataset.state === "active"
                  && badge.textContent === "可用",
                detail: detail === frame.detail,
                header: detail.querySelector(".source-manager-detail-header") === frame.header,
                view: detail.querySelector("[data-source-manager-view]") === frame.view,
                status: detail.querySelector(".source-manager-detail-status") === frame.status
                  && frame.status.dataset.state === "active"
                  && frame.status.textContent.includes("可以浏览、同步"),
                recovery: detail.querySelector(".source-manager-action-group-recovery")
                  === frame.recovery,
                remove: detail.querySelector(".source-manager-action-group-remove")
                  === frame.remove,
                deleteAction: detail.querySelector('[data-source-action="delete"]')
                  === frame.deleteAction,
                oldActionRemoved: !detail.querySelector('[data-source-action="reauthorize"]'),
                newAction: Boolean(syncAction),
                focusMigrated: document.activeElement === syncAction,
                navigationScroll: navigation.scrollTop === frame.navigationScrollTop,
                detailScroll: detail.scrollTop === frame.detailScrollTop,
              }};
            }}"""
        )
        assert all(restored_state_frame.values()), restored_state_frame
        page.screenshot(
            path="/tmp/imageall-source-manager-state-continuity.png",
            full_page=True,
        )

        assert not unexpected_requests, unexpected_requests
        assert not page_errors, page_errors
        assert not console_errors, console_errors
        context.close()
        browser.close()

    print("source-management-refresh-browser: ok")


if __name__ == "__main__":
    main()
