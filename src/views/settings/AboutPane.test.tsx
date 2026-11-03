/** @vitest-environment jsdom */
import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, expect, it, vi } from "vitest";
import { __setBackend } from "@/ipc/client";
import type { Backend } from "@/ipc/types";
import { AboutPane } from "./AboutPane";
import { ReportBug } from "../report/ReportBug";

globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const host = document.createElement("div");
const root = createRoot(host);
const openUrl = vi.fn().mockResolvedValue(undefined);
const checkForUpdate = vi.fn();
const reportAttachment = vi.fn();
async function mount(report = false) {
  __setBackend({ appVersion: () => Promise.resolve("1.2.1"), openUrl, checkForUpdate, reportAttachment } as unknown as Backend);
  await act(async () => { await Promise.resolve(); root.render(report ? <ReportBug onClose={() => {}} /> : <AboutPane />); });
}
async function click(text: string) {
  const button = Array.from(host.querySelectorAll("button")).find(b => b.textContent === text);
  expect(button).toBeDefined();
  await act(async () => { await Promise.resolve(); button?.click(); });
}
afterEach(() => { act(() => root.render(null)); vi.clearAllMocks(); __setBackend(null); });
it("opens the fork releases instead of checking or installing an update", async () => {
  await mount();
  await click("Check for updates");
  expect(openUrl).toHaveBeenCalledWith("https://github.com/computergabe/rbxport/releases");
  expect(checkForUpdate).not.toHaveBeenCalled();
  const toggle = host.querySelector<HTMLInputElement>('input[role="switch"]');
  expect(toggle?.checked).toBe(false);
  expect(toggle?.disabled).toBe(true);
});
it("routes GitHub to the fork while retaining upstream attribution", async () => {
  await mount();
  await act(async () => { await Promise.resolve(); host.querySelector<HTMLButtonElement>('button[aria-label="GitHub"]')?.click(); });
  expect(openUrl).toHaveBeenCalledWith("https://github.com/computergabe/rbxport");
  expect(host.textContent).toContain("Made by TRIODE");
});
it("opens a fork issue without collecting diagnostics or contacting the old reporter", async () => {
  await mount(true);
  expect(host.querySelector("iframe")).toBeNull();
  expect(reportAttachment).not.toHaveBeenCalled();
  await click("Open GitHub issue");
  expect(openUrl).toHaveBeenCalledWith("https://github.com/computergabe/rbxport/issues/new/choose");
  expect(host.textContent).toContain("GitHub issues are public");
});
it("shows a useful error when the browser cannot open", async () => {
  openUrl.mockRejectedValueOnce(new Error("offline"));
  await mount(true);
  await click("Open GitHub issue");
  expect(host.querySelector('[role="alert"]')?.textContent).toContain("github.com/computergabe/rbxport/issues");
});
